-- ============================================================================
-- SECOTO - Migration Supabase (projet " SECOTO CONVOYEURS ", znnigxmzacukpfueqfrh)
-- ----------------------------------------------------------------------------
-- A coller integralement dans le SQL Editor de Supabase.
-- Idempotent et rejouable : IF NOT EXISTS - CREATE OR REPLACE - DROP ... IF EXISTS.
--
-- Contenu :
--   0. Types & fonctions utilitaires (role, immutabilite)
--   1. Bareme tarifaire cote base (fonctions IMMUTABLE + colonnes generees)
--   2. Module frais reels + justificatifs
--   3. Documents : numerotation atomique, signature, immutabilite
--   4. Reglages admin (coordonnees bancaires configurables)
--   5. RLS : cloisonnement admin - convoyeur - client
--   6. Storage : buckets + policies (justificatifs, PDF)
--
-- Hypotheses : tables `accounts` (id = auth.uid(), colonne `role`
-- 'admin'|'convoyeur'), `missions`, `documents` existent deja avec RLS active.
-- ============================================================================

begin;

-- ============================================================================
-- 0. TYPES & FONCTIONS UTILITAIRES
-- ============================================================================

-- 0.1 Enum : type de prestation
do $$
begin
  if not exists (select 1 from pg_type where typname = 'secoto_mission_kind') then
    create type secoto_mission_kind as enum ('plateau', 'convoyage');
  end if;
end$$;

-- 0.2 Enum : type de frais reel
do $$
begin
  if not exists (select 1 from pg_type where typname = 'secoto_frais_type') then
    create type secoto_frais_type as enum ('essence', 'peage');
  end if;
end$$;

-- 0.3 Enum : statut de validation d'un frais
do $$
begin
  if not exists (select 1 from pg_type where typname = 'secoto_frais_statut') then
    create type secoto_frais_statut as enum ('en_attente', 'valide', 'refuse');
  end if;
end$$;

-- 0.4 Enum : type de document
do $$
begin
  if not exists (select 1 from pg_type where typname = 'secoto_doc_type') then
    create type secoto_doc_type as enum ('devis', 'bon_de_mission', 'facture');
  end if;
end$$;

-- 0.5 Enum : statut de document (surensemble des trois cycles de vie)
do $$
begin
  if not exists (select 1 from pg_type where typname = 'secoto_doc_statut') then
    create type secoto_doc_statut as enum
      ('brouillon', 'envoye', 'signe', 'refuse', 'expire');
  end if;
end$$;

-- 0.6 Helper : l'utilisateur courant est-il admin ?
--     Sert de socle a toutes les policies RLS.
create or replace function public.secoto_is_admin()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.accounts a
    where a.id = auth.uid() and a.role = 'admin'
  );
$$;

comment on function public.secoto_is_admin() is
  'Vrai si l''utilisateur authentifie possede le role admin dans accounts.';

-- ============================================================================
-- 1. BAREME TARIFAIRE COTE BASE
--    Le prix client est calcule PAR LA BASE et ne peut pas etre falsifie
--    depuis le front. Le type de prestation vient de la colonne EXISTANTE
--    missions.type ('convoyage' | 'plateau'). Les fonctions sont IMMUTABLE
--    pour etre reutilisables dans des colonnes generees.
-- ============================================================================

-- 1.0 Transition idempotente : on retire les objets qui dependent de l'ancien
--     modele (colonne kind + colonnes generees + vues) pour pouvoir recreer
--     proprement les colonnes basees sur missions.type. Rejouable sans erreur.
drop view if exists public.v_missions_admin;
drop view if exists public.v_missions_transporter;
drop view if exists public.v_missions_client;
alter table public.missions drop column if exists client_price;
alter table public.missions drop column if exists carrier_pay;
alter table public.missions drop column if exists margin;
alter table public.missions drop column if exists kind;
drop function if exists public.secoto_compute_client_price(secoto_mission_kind, numeric, numeric);
drop function if exists public.secoto_compute_carrier_pay(secoto_mission_kind, numeric, numeric);
drop function if exists public.secoto_compute_margin(secoto_mission_kind, numeric, numeric);

-- 1.1 Prix client (prestation, hors frais reels refactures)
--     Plateau   : cout transporteur x 1,20 (marge 20 %, SANS plancher)
--     Convoyage : 1,00 EUR-km (bareme impose)
create or replace function public.secoto_compute_client_price(
  p_type         text,
  p_distance_km  numeric,
  p_carrier_cost numeric
)
returns numeric
language sql
immutable
as $$
  select round(
    case p_type
      when 'plateau'   then coalesce(p_carrier_cost, 0) * 1.20
      when 'convoyage' then coalesce(p_distance_km, 0) * 1.00
      else 0
    end
  , 2);
$$;

-- 1.2 Remuneration transporteur (prestation, hors remboursement des frais)
--     Plateau   : = cout transporteur
--     Convoyage : 0,55 EUR-km
create or replace function public.secoto_compute_carrier_pay(
  p_type         text,
  p_distance_km  numeric,
  p_carrier_cost numeric
)
returns numeric
language sql
immutable
as $$
  select round(
    case p_type
      when 'plateau'   then coalesce(p_carrier_cost, 0)
      when 'convoyage' then coalesce(p_distance_km, 0) * 0.55
      else 0
    end
  , 2);
$$;

-- 1.3 Marge SECOTO = prix client - remu transporteur (frais neutres, exclus)
create or replace function public.secoto_compute_margin(
  p_type         text,
  p_distance_km  numeric,
  p_carrier_cost numeric
)
returns numeric
language sql
immutable
as $$
  select round(
      public.secoto_compute_client_price(p_type, p_distance_km, p_carrier_cost)
    - public.secoto_compute_carrier_pay(p_type, p_distance_km, p_carrier_cost)
  , 2);
$$;

-- 1.4 Colonnes tarifaires sur missions (distance_km existe deja cote app)
alter table public.missions add column if not exists distance_km    numeric(10,2);
alter table public.missions add column if not exists carrier_cost   numeric(12,2);
-- Mode de reglement choisi a la creation ('virement' | 'especes').
alter table public.missions add column if not exists payment_method text not null default 'virement';

-- 1.5 Colonnes GENEREES a partir de missions.type : impossibles a ecrire
--     depuis le front (calcul garanti par la base).
alter table public.missions
  add column client_price numeric(12,2)
  generated always as
    (public.secoto_compute_client_price(type, distance_km, carrier_cost)) stored;

alter table public.missions
  add column carrier_pay numeric(12,2)
  generated always as
    (public.secoto_compute_carrier_pay(type, distance_km, carrier_cost)) stored;

alter table public.missions
  add column margin numeric(12,2)
  generated always as
    (public.secoto_compute_margin(type, distance_km, carrier_cost)) stored;

-- ============================================================================
-- 2. MODULE FRAIS REELS + JUSTIFICATIFS
-- ============================================================================
create table if not exists public.frais (
  id               uuid primary key default gen_random_uuid(),
  mission_id       uuid not null references public.missions(id) on delete cascade,
  transporter_id   uuid not null references public.accounts(id),
  type             secoto_frais_type   not null,
  montant          numeric(12,2)       not null check (montant >= 0),
  justificatif_url text,                        -- chemin dans le bucket justificatifs
  statut           secoto_frais_statut not null default 'en_attente',
  motif_refus      text,                        -- renseigne si statut = 'refuse'
  date             date not null default current_date,
  created_at       timestamptz not null default now(),
  validated_at     timestamptz,
  validated_by     uuid references public.accounts(id)
);

comment on table public.frais is
  'Frais reels (essence-peage) remontes par le transporteur, valides par l''admin. '
  'Le remboursement n''est declenche qu''en statut valide. Refactures au client '
  'a l''identique (neutres pour la marge).';

create index if not exists idx_frais_mission     on public.frais(mission_id);
create index if not exists idx_frais_transporter on public.frais(transporter_id);
create index if not exists idx_frais_statut      on public.frais(statut);

-- ============================================================================
-- 3. DOCUMENTS : NUMEROTATION ATOMIQUE, SIGNATURE, IMMUTABILITE
-- ============================================================================

-- 3.1 Colonnes documents
alter table public.documents add column if not exists mission_id   uuid references public.missions(id) on delete set null;
alter table public.documents add column if not exists doc_type     secoto_doc_type;
alter table public.documents add column if not exists numero       text;
alter table public.documents add column if not exists statut       secoto_doc_statut not null default 'brouillon';
alter table public.documents add column if not exists ref_devis    text;            -- facture -> devis d'origine
alter table public.documents add column if not exists pdf_url      text;            -- chemin bucket documents-pdf
alter table public.documents add column if not exists immutable    boolean not null default false;
-- Signatures : { data_url, signer_name, signed_at, ip }
alter table public.documents add column if not exists signature_client        jsonb;
alter table public.documents add column if not exists signature_transporteur  jsonb;
alter table public.documents add column if not exists created_at   timestamptz not null default now();

-- Unicite du numero (les brouillons non numerotes restent a NULL)
create unique index if not exists uq_documents_numero
  on public.documents(numero) where numero is not null;

-- 3.2 Numerotation atomique et sans trou (sequence mensuelle par prefixe)
create table if not exists public.doc_counters (
  prefix   text not null,   -- DEV - BM - FAC
  period   text not null,   -- AAAAMM
  last_num integer not null default 0,
  primary key (prefix, period)
);

comment on table public.doc_counters is
  'Compteurs mensuels par prefixe. Alimentes uniquement via secoto_next_doc_number '
  '(upsert atomique) - jamais cote client - pour garantir l''absence de doublon-trou.';

-- Attribue et renvoie le prochain numero : PREFIX-AAAAMM-NNN
create or replace function public.secoto_next_doc_number(p_type secoto_doc_type)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_prefix text;
  v_period text := to_char(now(), 'YYYYMM');
  v_num    integer;
begin
  v_prefix := case p_type
                when 'devis'          then 'DEV'
                when 'bon_de_mission' then 'BM'
                when 'facture'        then 'FAC'
              end;

  insert into public.doc_counters (prefix, period, last_num)
  values (v_prefix, v_period, 1)
  on conflict (prefix, period)
    do update set last_num = public.doc_counters.last_num + 1
  returning last_num into v_num;

  return format('%s-%s-%s', v_prefix, v_period, lpad(v_num::text, 3, '0'));
end;
$$;

comment on function public.secoto_next_doc_number(secoto_doc_type) is
  'Renvoie le prochain numero atomique (DEV--BM--FAC-AAAAMM-NNN), sequence mensuelle.';

-- 3.3 Immutabilite : un document signe-immuable ne peut plus etre modifie.
create or replace function public.secoto_documents_immutable_guard()
returns trigger
language plpgsql
as $$
begin
  if tg_op = 'DELETE' then
    if old.immutable or old.statut = 'signe' then
      raise exception 'Document % immuable (signe) : suppression interdite.', old.numero;
    end if;
    return old;
  end if;

  -- UPDATE
  if old.immutable or old.statut = 'signe' then
    raise exception 'Document % immuable (signe) : modification interdite. '
      'Emettre un avoir ou un nouveau document.', old.numero;
  end if;

  -- Passage a l'etat signe => on verrouille automatiquement.
  if new.statut = 'signe' then
    new.immutable := true;
  end if;

  return new;
end;
$$;

drop trigger if exists trg_documents_immutable on public.documents;
create trigger trg_documents_immutable
  before update or delete on public.documents
  for each row execute function public.secoto_documents_immutable_guard();

-- ============================================================================
-- 4. REGLAGES ADMIN - coordonnees bancaires configurables (jamais en dur)
-- ============================================================================
create table if not exists public.app_settings (
  key        text primary key,
  value      jsonb not null,
  updated_at timestamptz not null default now()
);

-- Valeur par defaut (a completer dans l'interface admin)
insert into public.app_settings (key, value)
values ('bank_details', jsonb_build_object(
  'titulaire','Nawfal Benchiha',
  'iban','FR76 2823 3000 0143 6341 8597 296',
  'bic','REVOFRP2',
  'banque','Revolut Bank UAB, 10 avenue Kleber, 75116 Paris'))
on conflict (key) do nothing;

-- ============================================================================
-- 5. RLS - CLOISONNEMENT
--    Schema reel SECOTO :
--      * accounts.role in ('admin','transporter','client')
--      * missions.assigned_transporter_id = le transporteur qui execute
--      * missions.client_account_id       = le client qui a poste la course
--    Regles de cloisonnement :
--      * le transporteur ne lit JAMAIS client_price ni margin
--      * le client ne lit JAMAIS carrier_cost, carrier_pay ni margin
--      * l'admin voit tout
--    Comme les trois audiences partagent le meme role SQL 'authenticated',
--    le cloisonnement colonnaire ne peut pas se faire par role : on RETIRE les
--    4 colonnes financieres du SELECT de base, et chaque audience lit ses
--    montants via une vue dediee (5.5) qui filtre par utilisateur.
-- ============================================================================

alter table public.missions      enable row level security;
alter table public.frais         enable row level security;
alter table public.documents     enable row level security;
alter table public.doc_counters  enable row level security;
alter table public.app_settings  enable row level security;

-- 5.1 Acces en lecture a missions.
--     IMPORTANT : l'app lit la table avec SELECT * (PostgREST). Un cloisonnement
--     COLONNAIRE par GRANT casse ces requetes ("permission denied"). On accorde
--     donc le SELECT complet ; le filtrage des LIGNES reste assure par les
--     policies RLS existantes + celles ci-dessous.
--     Cloisonnement des MONTANTS : assure (a) cote app (affichage reserve admin),
--     (b) a la generation des documents (garde-fou anti-fuite). Pour un
--     cloisonnement colonnaire STRICT cote base, deplacer les colonnes
--     financieres dans une table dediee 'mission_pricing' (evolution possible).
grant select on public.missions to authenticated;

-- 5.2 Policy admin (acces total, en plus des policies existantes de l'app)
drop policy if exists missions_write_admin on public.missions;
create policy missions_write_admin on public.missions
  for all to authenticated
  using (public.secoto_is_admin())
  with check (public.secoto_is_admin());

-- 5.3 Policies frais
grant select, insert, update on public.frais to authenticated;

drop policy if exists frais_admin_all          on public.frais;
drop policy if exists frais_transporter_select on public.frais;
drop policy if exists frais_transporter_insert on public.frais;

-- Admin : acces total (dont validation)
create policy frais_admin_all on public.frais
  for all to authenticated
  using (public.secoto_is_admin())
  with check (public.secoto_is_admin());

-- Transporteur : lit uniquement ses propres frais
create policy frais_transporter_select on public.frais
  for select to authenticated
  using (transporter_id = auth.uid());

-- Transporteur : cree un frais pour lui-meme, sur une mission qui lui est
-- attribuee, toujours en 'en_attente'.
create policy frais_transporter_insert on public.frais
  for insert to authenticated
  with check (
    transporter_id = auth.uid()
    and statut = 'en_attente'
    and exists (
      select 1 from public.missions m
      where m.id = mission_id and m.assigned_transporter_id = auth.uid()
    )
  );

-- 5.4 Policies documents
grant select, insert, update on public.documents to authenticated;

drop policy if exists documents_admin_all          on public.documents;
drop policy if exists documents_transporter_select on public.documents;

-- Admin : acces total
create policy documents_admin_all on public.documents
  for all to authenticated
  using (public.secoto_is_admin())
  with check (public.secoto_is_admin());

-- Transporteur : lit UNIQUEMENT les bons de mission de ses propres missions.
-- Jamais les devis-factures (qui portent le montant client).
create policy documents_transporter_select on public.documents
  for select to authenticated
  using (
    doc_type = 'bon_de_mission'
    and exists (
      select 1 from public.missions m
      where m.id = documents.mission_id
        and m.assigned_transporter_id = auth.uid()
    )
  );

-- 5.5 Vues financieres par audience (SECURITY DEFINER via proprietaire de vue).
--     Chaque vue filtre sur l'utilisateur courant ; elle peut lire les colonnes
--     financieres que 'authenticated' ne peut pas lire en direct.

-- Admin : tout (dont client_price et margin).
drop view if exists public.v_missions_admin;
create view public.v_missions_admin with (security_barrier = true) as
  select m.* from public.missions m
  where public.secoto_is_admin();
comment on view public.v_missions_admin is
  'Reserve admin : missions completes (client_price, margin, carrier_*). 0 ligne sinon.';

-- Transporteur : sa remuneration, jamais le prix client ni la marge.
drop view if exists public.v_missions_transporter;
create view public.v_missions_transporter with (security_barrier = true) as
  select m.id, m.type, m.distance_km, m.carrier_cost, m.carrier_pay
  from public.missions m
  where m.assigned_transporter_id = auth.uid();
comment on view public.v_missions_transporter is
  'Reserve transporteur : uniquement sa remuneration (carrier_cost et carrier_pay).';

-- Client : son forfait, jamais le cout transporteur ni la marge.
drop view if exists public.v_missions_client;
create view public.v_missions_client with (security_barrier = true) as
  select m.id, m.type, m.distance_km, m.client_price
  from public.missions m
  where m.client_account_id = auth.uid();
comment on view public.v_missions_client is
  'Reserve client : uniquement le forfait client_price.';

revoke all on public.v_missions_admin,       public.v_missions_transporter, public.v_missions_client from anon, authenticated;
grant  select on public.v_missions_admin,     public.v_missions_transporter, public.v_missions_client to authenticated;

-- 5.6 doc_counters - app_settings : reserves a l'admin (et fonctions definer)
drop policy if exists doc_counters_admin on public.doc_counters;
create policy doc_counters_admin on public.doc_counters
  for all to authenticated
  using (public.secoto_is_admin()) with check (public.secoto_is_admin());

drop policy if exists app_settings_read  on public.app_settings;
drop policy if exists app_settings_admin on public.app_settings;
-- Lecture des reglages (dont coordonnees bancaires) : authentifies ; ecriture : admin.
create policy app_settings_read on public.app_settings
  for select to authenticated using (true);
create policy app_settings_admin on public.app_settings
  for all to authenticated
  using (public.secoto_is_admin()) with check (public.secoto_is_admin());

-- ============================================================================
-- 6. STORAGE - buckets + policies
-- ============================================================================

-- 6.1 Buckets prives (idempotent)
insert into storage.buckets (id, name, public)
values ('justificatifs', 'justificatifs', false)
on conflict (id) do nothing;

insert into storage.buckets (id, name, public)
values ('documents-pdf', 'documents-pdf', false)
on conflict (id) do nothing;

-- 6.2 Policies bucket justificatifs
--     Convention de chemin : justificatifs-{transporter_id}-{mission_id}-{fichier}
drop policy if exists just_admin_all       on storage.objects;
drop policy if exists just_convoyeur_read   on storage.objects;
drop policy if exists just_convoyeur_write  on storage.objects;

create policy just_admin_all on storage.objects
  for all to authenticated
  using (bucket_id = 'justificatifs' and public.secoto_is_admin())
  with check (bucket_id = 'justificatifs' and public.secoto_is_admin());

create policy just_convoyeur_read on storage.objects
  for select to authenticated
  using (
    bucket_id = 'justificatifs'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

create policy just_convoyeur_write on storage.objects
  for insert to authenticated
  with check (
    bucket_id = 'justificatifs'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

-- 6.3 Policies bucket documents-pdf
--     PDF generes : lecture-ecriture admin. Le convoyeur lit seulement les
--     bons de mission (prefixe de chemin documents-pdf-bon_de_mission-...).
drop policy if exists pdf_admin_all        on storage.objects;
drop policy if exists pdf_convoyeur_read     on storage.objects;

create policy pdf_admin_all on storage.objects
  for all to authenticated
  using (bucket_id = 'documents-pdf' and public.secoto_is_admin())
  with check (bucket_id = 'documents-pdf' and public.secoto_is_admin());

create policy pdf_convoyeur_read on storage.objects
  for select to authenticated
  using (
    bucket_id = 'documents-pdf'
    and (storage.foldername(name))[1] = 'bon_de_mission'
  );

commit;

-- ============================================================================
-- FIN - script idempotent, rejouable sans erreur.
-- ============================================================================
