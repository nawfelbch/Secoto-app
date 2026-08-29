-- ============================================================================
-- SECOTO — migration 021 : PILOTAGE MANUEL DES MISSIONS
-- ----------------------------------------------------------------------------
-- Objet (aucun changement de comportement par défaut) :
--
--  1. L'administrateur peut imposer LUI-MÊME les deux montants d'une mission :
--       · la rémunération du transporteur / convoyeur ;
--       · la marge SECOTO (qui n'est donc plus forcément 20 %).
--     Tant que `manual_pricing` vaut false, TOUS les calculs restent
--     rigoureusement identiques à aujourd'hui (barème convoyage, commission
--     plateau de 20 %).
--
--  2. L'administrateur peut attribuer une mission à un transporteur SANS
--     candidature (mission reçue par téléphone), fixer l'étape de la mission,
--     déposer le devis déjà signé, et enregistrer une commission encaissée
--     hors application (ce qui débloque le bon de mission plateau).
--
-- Choix techniques et raisons :
--
--  · Les six colonnes de montants étaient GÉNÉRÉES. On les convertit en
--    colonnes ordinaires (ALTER COLUMN ... DROP EXPRESSION, PostgreSQL 13+)
--    alimentées par un trigger BEFORE. Cette opération est purement
--    catalogue : elle NE réécrit PAS la table, NE supprime PAS les quatre vues
--    cloisonnées, et ne demande AUCUNE version 17. Les valeurs déjà stockées
--    sont conservées, puis recalculées par le backfill final.
--  · Le trigger reste la source unique de vérité : le front ne peut pas
--    écrire dans `missions` (droits révoqués), et tout passe par des RPC
--    SECURITY DEFINER. Un montant ne peut donc pas être falsifié.
--  · Aucune vue existante n'est supprimée ni recréée : la migration ne peut
--    pas faire disparaître une colonne posée par un correctif non versionné.
--    Les champs nouveaux sont exposés par une vue compagnon réservée admin.
--
-- Idempotente : rejouable sans effet de bord.
-- ============================================================================

begin;

-- ----------------------------------------------------------------------------
-- 0. GARDE-FOU : le socle de la migration 009 doit être là.
-- ----------------------------------------------------------------------------
do $guard$
begin
  if to_regprocedure(
       'public.secoto_compute_client_price(text,numeric,numeric,boolean,boolean,numeric)'
     ) is null then
    raise exception
      'Migration 009 absente : appliquez 202608170009_paiement_bareme_notifications.sql avant celle-ci.';
  end if;
  if to_regclass('public.missions') is null then
    raise exception 'Table public.missions introuvable.';
  end if;
end
$guard$;

-- ----------------------------------------------------------------------------
-- 1. COLONNES DE PILOTAGE MANUEL
-- ----------------------------------------------------------------------------
alter table public.missions
  add column if not exists manual_pricing boolean not null default false,
  add column if not exists manual_carrier_pay numeric(12,2),
  add column if not exists manual_margin numeric(12,2),
  add column if not exists offline_signed boolean not null default false,
  add column if not exists offline_origin text,
  add column if not exists commission_settled_offline boolean not null default false,
  add column if not exists commission_settled_at timestamptz,
  add column if not exists commission_settlement_note text;

comment on column public.missions.manual_pricing is
  'true = les montants sont imposés par l''administrateur (manual_carrier_pay / manual_margin) '
  'et non calculés par le barème. false = comportement historique inchangé.';
comment on column public.missions.manual_carrier_pay is
  'Rémunération du transporteur / convoyeur fixée à la main par SECOTO.';
comment on column public.missions.manual_margin is
  'Marge SECOTO fixée à la main (peut être différente de 20 %).';
comment on column public.missions.offline_signed is
  'Mission signée hors application (téléphone, e-mail) : le devis a été déposé par l''administrateur.';

alter table public.missions
  drop constraint if exists missions_manual_pricing_amounts_check;
alter table public.missions
  add constraint missions_manual_pricing_amounts_check
  check (
    manual_pricing = false
    or (coalesce(manual_carrier_pay, 0) >= 0 and coalesce(manual_margin, 0) >= 0)
  );

-- ----------------------------------------------------------------------------
-- 2. LES SIX MONTANTS DEVIENNENT DES COLONNES ORDINAIRES
-- ----------------------------------------------------------------------------
-- DROP EXPRESSION conserve la colonne, son type, ses droits, et toutes les
-- vues qui en dépendent. Aucune réécriture de table.
do $degen$
declare
  v_col record;
begin
  for v_col in
    select a.attname
    from pg_attribute a
    join pg_class c on c.oid = a.attrelid
    join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public'
      and c.relname = 'missions'
      and a.attgenerated = 's'
      and a.attname in (
        'client_price', 'carrier_pay', 'margin',
        'commission_amount', 'transport_amount', 'client_total_due'
      )
  loop
    execute format(
      'alter table public.missions alter column %I drop expression',
      v_col.attname
    );
    raise notice 'Colonne % : expression générée retirée.', v_col.attname;
  end loop;
end
$degen$;

-- Filet : si l'une des six colonnes manquait (correctif non appliqué), on la
-- crée en colonne ordinaire pour que le trigger ait où écrire.
alter table public.missions
  add column if not exists client_price numeric(12,2),
  add column if not exists carrier_pay numeric(12,2),
  add column if not exists margin numeric(12,2),
  add column if not exists commission_amount numeric(12,2),
  add column if not exists transport_amount numeric(12,2),
  add column if not exists client_total_due numeric(12,2);

-- ----------------------------------------------------------------------------
-- 3. LE CALCUL DES MONTANTS — SOURCE UNIQUE DE VÉRITÉ
-- ----------------------------------------------------------------------------
create or replace function public.secoto_trg_mission_amounts()
returns trigger
language plpgsql
set search_path = ''
as $function$
declare
  v_type      text    := coalesce(new.type::text, 'convoyage');
  v_manual    boolean := coalesce(new.manual_pricing, false);
  v_carrier   numeric;   -- rémunération du transporteur
  v_margin    numeric;   -- marge nette SECOTO
  v_client    numeric;   -- montant réellement ENCAISSÉ par SECOTO
  v_transport numeric;   -- transport réglé en direct au transporteur (plateau)
begin
  if v_manual then
    -- Montants imposés par l'administrateur.
    v_carrier := round(greatest(coalesce(new.manual_carrier_pay, 0), 0), 2);
    v_margin  := round(greatest(coalesce(new.manual_margin, 0), 0), 2);

    if v_type = 'plateau' then
      -- Intermédiation : SECOTO n'encaisse que sa marge ; le transport est
      -- réglé en direct au transporteur.
      v_client    := v_margin;
      v_transport := v_carrier;
    else
      -- Sous-traitance convoyage : SECOTO encaisse la totalité.
      v_client    := round(v_carrier + v_margin, 2);
      v_transport := 0;
    end if;

    -- carrier_cost reste le miroir de ce que touche le transporteur : le bon
    -- de mission et la vue transporteur s'appuient dessus.
    new.carrier_cost := v_carrier;
  else
    -- Comportement historique, strictement inchangé.
    v_carrier := public.secoto_compute_carrier_pay(
      v_type, new.distance_km, new.carrier_cost);
    v_client := public.secoto_compute_client_price(
      v_type, new.distance_km, new.carrier_cost,
      new.surcharge_urgent, new.surcharge_weekend, new.surcharge_oversize_pct);
    v_margin := public.secoto_compute_margin(
      v_type, new.distance_km, new.carrier_cost,
      new.surcharge_urgent, new.surcharge_weekend, new.surcharge_oversize_pct);
    v_transport := public.secoto_compute_transport_amount(v_type, new.carrier_cost);
  end if;

  new.carrier_pay       := v_carrier;
  new.client_price      := v_client;
  new.margin            := v_margin;
  new.commission_amount := case when v_type = 'plateau' then round(v_client, 2) else 0 end;
  new.transport_amount  := round(coalesce(v_transport, 0), 2);
  new.client_total_due  := round(v_client + coalesce(v_transport, 0), 2);

  return new;
end;
$function$;

comment on function public.secoto_trg_mission_amounts() is
  'Recalcule les six montants d''une mission avant chaque écriture. '
  'manual_pricing = false : barème historique. true : montants imposés par SECOTO.';

-- Nom volontairement en « zzz_ » : les triggers BEFORE sont déclenchés par
-- ordre alphabétique, celui-ci doit passer en dernier et avoir le dernier mot.
drop trigger if exists zzz_secoto_mission_amounts on public.missions;
create trigger zzz_secoto_mission_amounts
  before insert or update on public.missions
  for each row execute function public.secoto_trg_mission_amounts();

-- Recalcul de l'existant. Les triggers AFTER en place ne se déclenchent pas :
-- `trg_secoto_mission_assigned_docs` exige un changement de statut ou de
-- transporteur, aucun des deux ne bouge ici.
update public.missions set manual_pricing = manual_pricing;

-- ----------------------------------------------------------------------------
-- 4. COMPATIBILITÉ : signatures à 3 arguments restaurées
-- ----------------------------------------------------------------------------
-- La migration 009 a supprimé `secoto_compute_client_price(text,numeric,numeric)`
-- et `secoto_compute_margin(text,numeric,numeric)`, alors que
-- `secoto_render_document()` les appelle encore. C'est la cause directe des
-- devis jamais générés sur les missions plateau. On restaure des passe-plats.
create or replace function public.secoto_compute_client_price(
  p_type text, p_distance_km numeric, p_carrier_cost numeric)
returns numeric
language sql
immutable
set search_path = ''
as $function$
  select public.secoto_compute_client_price(
    p_type, p_distance_km, p_carrier_cost, false, false, 0);
$function$;

create or replace function public.secoto_compute_margin(
  p_type text, p_distance_km numeric, p_carrier_cost numeric)
returns numeric
language sql
immutable
set search_path = ''
as $function$
  select public.secoto_compute_margin(
    p_type, p_distance_km, p_carrier_cost, false, false, 0);
$function$;

-- ----------------------------------------------------------------------------
-- 4 bis. LES DOCUMENTS UTILISENT LES MONTANTS RÉELLEMENT ENREGISTRÉS
-- ----------------------------------------------------------------------------
-- `secoto_render_document()` recalculait les montants au lieu de lire ceux de
-- la mission : un tarif imposé à la main n'apparaîtrait pas sur le devis. On
-- réécrit UNIQUEMENT les deux lignes de calcul, à partir de la définition
-- réellement présente en base (et non d'une copie du dépôt). Si la définition
-- ne correspond pas, rien n'est modifié et la migration continue.
do $patch_render$
declare
  v_def text;
  v_new text;
begin
  select pg_get_functiondef(p.oid) into v_def
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname = 'secoto_render_document'
  limit 1;

  if v_def is null then
    raise notice 'secoto_render_document absente : rien a patcher.';
    return;
  end if;

  v_new := regexp_replace(
    v_def,
    'v_client\s*:=\s*public\.secoto_compute_client_price\([^;]*;',
    'v_client := coalesce(m.client_price, public.secoto_compute_client_price('
    || 'm.type::text, m.distance_km, m.carrier_cost, m.surcharge_urgent, '
    || 'm.surcharge_weekend, m.surcharge_oversize_pct));'
  );
  v_new := regexp_replace(
    v_new,
    'v_carrier\s*:=\s*public\.secoto_compute_carrier_pay\([^;]*;',
    'v_carrier := coalesce(m.carrier_pay, public.secoto_compute_carrier_pay('
    || 'm.type::text, m.distance_km, m.carrier_cost));'
  );

  if v_new = v_def then
    raise notice 'secoto_render_document : lignes de montant non reconnues, fonction laissee en l etat.';
  else
    execute v_new;
    raise notice 'secoto_render_document : montants alignes sur la mission.';
  end if;
exception when others then
  raise notice 'secoto_render_document non modifiee (%). Le passe-plat de la section 4 suffit.', sqlerrm;
end
$patch_render$;

-- ----------------------------------------------------------------------------
-- 5. VUE COMPAGNON — réservée à l'administrateur
-- ----------------------------------------------------------------------------
-- Aucune vue existante n'est touchée : celle-ci ne fait qu'ajouter, à côté,
-- les champs de pilotage manuel dont l'écran admin a besoin.
create or replace view public.secoto_mission_manual_v1
with (security_barrier = true, security_invoker = false)
as
select
  m.id as mission_id,
  m.manual_pricing,
  m.manual_carrier_pay,
  m.manual_margin,
  m.offline_signed,
  m.offline_origin,
  m.commission_settled_offline,
  m.commission_settled_at,
  m.commission_settlement_note
from public.missions m
where public.secoto_is_admin();

revoke all on table public.secoto_mission_manual_v1 from anon;
grant select on table public.secoto_mission_manual_v1 to authenticated;

-- ----------------------------------------------------------------------------
-- 6. RPC — fixer les montants à la main
-- ----------------------------------------------------------------------------
create or replace function public.secoto_admin_set_mission_pricing(
  p_mission_id uuid,
  p_manual_pricing boolean,
  p_carrier_pay numeric,
  p_margin numeric,
  p_idempotency_key uuid
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $function$
declare
  v_admin_id uuid := secoto_private.assert_admin();
  v_existing jsonb;
  v_mission  public.missions%rowtype;
begin
  v_existing := secoto_private.lock_operation('admin_set_mission_pricing', p_idempotency_key);
  if v_existing is not null then return v_existing; end if;

  select * into v_mission from public.missions m where m.id = p_mission_id for update;
  if not found then raise exception 'Mission introuvable.'; end if;
  if v_mission.status::text = 'cancelled' then
    raise exception 'Mission annulee : les montants ne sont plus modifiables.';
  end if;

  if coalesce(p_manual_pricing, false) then
    if coalesce(p_carrier_pay, -1) < 0 or coalesce(p_margin, -1) < 0 then
      raise exception 'Renseignez la remuneration du transporteur ET la marge SECOTO (0 accepte).';
    end if;
    update public.missions
       set manual_pricing     = true,
           manual_carrier_pay = round(p_carrier_pay, 2),
           manual_margin      = round(p_margin, 2)
     where id = p_mission_id
    returning * into v_mission;
  else
    update public.missions
       set manual_pricing     = false,
           manual_carrier_pay = null,
           manual_margin      = null
     where id = p_mission_id
    returning * into v_mission;
  end if;

  return secoto_private.finish_operation(
    'admin_set_mission_pricing', p_idempotency_key, to_jsonb(v_mission));
end;
$function$;

-- ----------------------------------------------------------------------------
-- 7. RPC — attribuer une mission SANS candidature (mission par téléphone)
-- ----------------------------------------------------------------------------
create or replace function public.secoto_admin_assign_mission_direct(
  p_mission_id uuid,
  p_transporter_id uuid,
  p_manual_pricing boolean,
  p_carrier_pay numeric,
  p_margin numeric,
  p_idempotency_key uuid
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $function$
declare
  v_admin_id    uuid := secoto_private.assert_admin();
  v_existing    jsonb;
  v_mission     public.missions%rowtype;
  v_transporter public.accounts%rowtype;
begin
  v_existing := secoto_private.lock_operation('admin_assign_direct', p_idempotency_key);
  if v_existing is not null then return v_existing; end if;

  select * into v_mission from public.missions m where m.id = p_mission_id for update;
  if not found then raise exception 'Mission introuvable.'; end if;
  if v_mission.status::text not in ('published', 'assigned') then
    raise exception 'Mission % : statut « % » incompatible avec une attribution.',
      coalesce(v_mission.public_ref, ''), v_mission.status;
  end if;

  select * into v_transporter from public.accounts a where a.id = p_transporter_id;
  if not found or v_transporter.role::text <> 'transporter' then
    raise exception 'Transporteur introuvable.';
  end if;

  if coalesce(p_manual_pricing, false) then
    if coalesce(p_carrier_pay, -1) < 0 or coalesce(p_margin, -1) < 0 then
      raise exception 'Renseignez la remuneration du transporteur ET la marge SECOTO (0 accepte).';
    end if;
  end if;

  update public.missions
     set status                  = 'assigned',
         progress_status         = coalesce(nullif(v_mission.progress_status, ''), 'assigned_pending'),
         assigned_transporter_id = p_transporter_id,
         assigned_transporter_name = coalesce(v_transporter.full_name, v_transporter.company_name),
         manual_pricing     = coalesce(p_manual_pricing, v_mission.manual_pricing, false),
         manual_carrier_pay = case when coalesce(p_manual_pricing, false)
                                   then round(p_carrier_pay, 2)
                                   else v_mission.manual_carrier_pay end,
         manual_margin      = case when coalesce(p_manual_pricing, false)
                                   then round(p_margin, 2)
                                   else v_mission.manual_margin end
   where id = p_mission_id
  returning * into v_mission;

  -- Les candidatures encore en attente sur cette mission sont closes.
  update public.mission_applications
     set status     = 'rejected',
         decided_at = now(),
         decided_by = v_admin_id
   where mission_id = p_mission_id
     and status::text = 'pending'
     and transporter_id <> p_transporter_id;

  update public.mission_applications
     set status     = 'accepted',
         decided_at = now(),
         decided_by = v_admin_id
   where mission_id = p_mission_id
     and transporter_id = p_transporter_id
     and status::text = 'pending';

  perform secoto_private.notify_one(
    p_transporter_id, 'course_assigned', p_mission_id, 'assigned',
    'mission-assigned:transporter:' || p_mission_id::text);

  if v_mission.client_account_id is not null then
    perform secoto_private.notify_one(
      v_mission.client_account_id, 'course_assigned', p_mission_id, 'courses',
      'mission-assigned:client:' || p_mission_id::text);
  end if;

  return secoto_private.finish_operation(
    'admin_assign_direct', p_idempotency_key, to_jsonb(v_mission));
end;
$function$;

-- ----------------------------------------------------------------------------
-- 8. RPC — fixer l'étape d'une mission à la main
-- ----------------------------------------------------------------------------
create or replace function public.secoto_admin_set_mission_stage(
  p_mission_id uuid,
  p_status text,
  p_progress_status text,
  p_idempotency_key uuid
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $function$
declare
  v_admin_id uuid := secoto_private.assert_admin();
  v_existing jsonb;
  v_mission  public.missions%rowtype;
  v_status   text;
  v_progress text;
begin
  v_existing := secoto_private.lock_operation('admin_set_stage', p_idempotency_key);
  if v_existing is not null then return v_existing; end if;

  select * into v_mission from public.missions m where m.id = p_mission_id for update;
  if not found then raise exception 'Mission introuvable.'; end if;

  v_status   := coalesce(nullif(p_status, ''), v_mission.status::text);
  v_progress := coalesce(nullif(p_progress_status, ''), v_mission.progress_status);

  if v_status not in ('published', 'assigned', 'completed', 'cancelled') then
    raise exception 'Statut de mission inconnu : %.', v_status;
  end if;
  if v_progress not in (
    'assigned_pending', 'pickup_started', 'pickup_completed', 'in_transit',
    'incident_reported', 'delivery_started', 'delivery_completed', 'completed'
  ) then
    raise exception 'Etape de mission inconnue : %.', v_progress;
  end if;
  if v_status in ('assigned', 'completed') and v_mission.assigned_transporter_id is null then
    raise exception 'Attribuez d''abord un transporteur a cette mission.';
  end if;

  update public.missions
     set status          = v_status,
         progress_status = v_progress
   where id = p_mission_id
  returning * into v_mission;

  return secoto_private.finish_operation(
    'admin_set_stage', p_idempotency_key, to_jsonb(v_mission));
end;
$function$;

-- ----------------------------------------------------------------------------
-- 9. RPC — commission encaissée HORS application
-- ----------------------------------------------------------------------------
-- Débloque le piège documenté : en plateau, le bon de mission reste en
-- brouillon jusqu'à l'encaissement de la commission DANS l'application, et
-- `secoto_release_mission_order` est réservée au service_role. Tant que la
-- facturation est manuelle, aucun bon ne pouvait plus partir.
create or replace function public.secoto_admin_settle_commission_offline(
  p_mission_id uuid,
  p_note text,
  p_idempotency_key uuid
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $function$
declare
  v_admin_id uuid := secoto_private.assert_admin();
  v_existing jsonb;
  v_mission  public.missions%rowtype;
  v_released text := '';
begin
  v_existing := secoto_private.lock_operation('admin_settle_offline', p_idempotency_key);
  if v_existing is not null then return v_existing; end if;

  select * into v_mission from public.missions m where m.id = p_mission_id for update;
  if not found then raise exception 'Mission introuvable.'; end if;

  update public.missions
     set payment_status             = 'paid',
         commission_paid_at         = coalesce(commission_paid_at, now()),
         commission_settled_offline = true,
         commission_settled_at      = now(),
         commission_settlement_note = left(coalesce(p_note, ''), 500)
   where id = p_mission_id
  returning * into v_mission;

  begin
    v_released := public.secoto_release_mission_order(p_mission_id);
  exception when others then
    v_released := 'Bon de mission non libere : ' || sqlerrm;
  end;

  if v_mission.assigned_transporter_id is not null then
    perform secoto_private.notify_one(
      v_mission.assigned_transporter_id, 'document', p_mission_id, 'documents',
      'commission-offline:' || p_mission_id::text);
  end if;

  return secoto_private.finish_operation(
    'admin_settle_offline', p_idempotency_key,
    jsonb_build_object('mission', to_jsonb(v_mission), 'released', v_released));
end;
$function$;

-- ----------------------------------------------------------------------------
-- 10. RPC — déposer un devis DÉJÀ SIGNÉ (mission prise par téléphone)
-- ----------------------------------------------------------------------------
create or replace function public.secoto_admin_register_signed_devis(
  p_mission_id uuid,
  p_file_name text,
  p_file_path text,
  p_mime_type text,
  p_size_bytes bigint,
  p_idempotency_key uuid
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $function$
declare
  v_admin_id uuid := secoto_private.assert_admin();
  v_existing jsonb;
  v_mission  public.missions%rowtype;
  v_document public.documents%rowtype;
  v_numero   text;
begin
  v_existing := secoto_private.lock_operation('admin_signed_devis', p_idempotency_key);
  if v_existing is not null then return v_existing; end if;

  select * into v_mission from public.missions m where m.id = p_mission_id;
  if not found then raise exception 'Mission introuvable.'; end if;

  if p_mime_type not in ('image/jpeg', 'image/png', 'image/webp', 'application/pdf') then
    raise exception 'Type de fichier interdit.';
  end if;
  if p_size_bytes is null or p_size_bytes < 1 or p_size_bytes > 12582912 then
    raise exception 'Taille de fichier interdite (12 Mo maximum).';
  end if;
  if p_file_path is null
     or p_file_path like '/%'
     or p_file_path like '%..%'
     or split_part(p_file_path, '/', 1) <> v_admin_id::text
     or split_part(p_file_path, '/', 2) <> 'mission'
     or split_part(p_file_path, '/', 3) <> p_mission_id::text
     or length(p_file_path) > 1024 then
    raise exception 'Chemin de fichier invalide.';
  end if;
  if not exists (
    select 1 from storage.objects o
    where o.bucket_id = 'documents-pdf' and o.name = p_file_path
  ) then
    raise exception 'Fichier absent du stockage : reessayez l''envoi.';
  end if;

  begin
    v_numero := public.secoto_next_doc_number('devis');
  exception when others then
    v_numero := 'DEV-' || to_char(now(), 'YYYYMM') || '-EXT';
  end;

  insert into public.documents (
    account_id, recipient_id, mission_id, doc_type, numero, statut,
    needs_signature, emitted_at, signed_at, file_name, file_path, status,
    immutable, type
  ) values (
    coalesce(v_mission.client_account_id, v_admin_id),
    v_mission.client_account_id,
    p_mission_id,
    'devis'::public.secoto_doc_type,
    v_numero,
    'signe'::public.secoto_doc_statut,
    false, now(), now(),
    left(coalesce(p_file_name, 'devis-signe'), 200),
    p_file_path,
    'validated',
    true,
    'devis_signe_hors_application'
  )
  returning * into v_document;

  update public.missions
     set offline_signed = true,
         offline_origin = coalesce(offline_origin, 'telephone')
   where id = p_mission_id;

  return secoto_private.finish_operation(
    'admin_signed_devis', p_idempotency_key, to_jsonb(v_document));
end;
$function$;

-- ----------------------------------------------------------------------------
-- 11. DÉPÔT DE FICHIER ADMIN DANS `documents-pdf`
-- ----------------------------------------------------------------------------
-- La politique existante autorise déjà l'administrateur à écrire dans ce
-- bucket ; on la recrée seulement si elle a disparu.
do $policy$
begin
  if to_regclass('storage.objects') is not null
     and not exists (
       select 1 from pg_policies
       where schemaname = 'storage' and tablename = 'objects'
         and policyname = 'secoto_generated_documents_admin_insert'
     ) then
    execute $ddl$
      create policy secoto_generated_documents_admin_insert
      on storage.objects for insert to authenticated
      with check (
        bucket_id = 'documents-pdf'
        and secoto_private.current_is_admin()
      )
    $ddl$;
  end if;
end
$policy$;

-- ----------------------------------------------------------------------------
-- 12. DROITS D'EXÉCUTION
-- ----------------------------------------------------------------------------
do $grants$
declare
  v_signature text;
begin
  foreach v_signature in array array[
    'public.secoto_admin_set_mission_pricing(uuid,boolean,numeric,numeric,uuid)',
    'public.secoto_admin_assign_mission_direct(uuid,uuid,boolean,numeric,numeric,uuid)',
    'public.secoto_admin_set_mission_stage(uuid,text,text,uuid)',
    'public.secoto_admin_settle_commission_offline(uuid,text,uuid)',
    'public.secoto_admin_register_signed_devis(uuid,text,text,text,bigint,uuid)'
  ] loop
    execute format('revoke all on function %s from public, anon', v_signature);
    execute format('grant execute on function %s to authenticated', v_signature);
  end loop;
end
$grants$;

commit;

notify pgrst, 'reload schema';
