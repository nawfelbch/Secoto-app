-- ============================================================================
-- SECOTO — MIGRATION 038 : DEVIS PAYABLE EN UN CLIC
-- ----------------------------------------------------------------------------
-- Jusqu'ici, un client sans compte SECOTO ne pouvait pas payer : le devis
-- partait par e-mail avec une signature, et l'encaissement supposait l'appli.
--
-- Decision de Nawfal du 23/09/2026 :
--   · le devis porte un bouton « Payer la course » au montant du Prix client ;
--   · le paiement VAUT acceptation du devis (plus d'etape de signature) ;
--   · le meme lien peut partir par SMS depuis la fiche mission de l'admin.
--
-- Le lien est une adresse-capacite : celui qui la detient peut payer, et rien
-- d'autre. Il ne porte aucun identifiant de mission, expire, et refuse de
-- servir deux fois. Le montant n'est JAMAIS lu dans l'URL : il est relu en
-- base au moment du clic.
-- ============================================================================

-- 1. Un nouveau motif de paiement -------------------------------------------
alter table public.payments drop constraint if exists payments_purpose_check;
alter table public.payments add constraint payments_purpose_check
  check (purpose in ('commission_plateau', 'convoyage_livraison', 'od_convoyage',
                     'od_plateau_commission', 'od_plateau', 'subscription_extension',
                     'devis_course'));

comment on constraint payments_purpose_check on public.payments is
  'devis_course : la course entiere reglee par le client depuis le lien du devis.';

-- 2. Les liens de paiement ----------------------------------------------------
create table if not exists public.devis_payment_links (
  id           uuid primary key default gen_random_uuid(),
  mission_id   uuid not null references public.missions(id) on delete cascade,
  token        text not null unique,
  amount_cents integer not null check (amount_cents > 0),
  currency     text not null default 'eur',
  expires_at   timestamptz not null,
  revoked_at   timestamptz,
  paid_at      timestamptz,
  payment_id   uuid references public.payments(id),
  created_by   uuid references public.accounts(id),
  created_at   timestamptz not null default now()
);

create index if not exists devis_payment_links_mission_idx
  on public.devis_payment_links (mission_id, created_at desc);

-- Un seul lien vivant par mission : on ne veut pas deux adresses valides qui
-- encaisseraient deux fois la meme course.
create unique index if not exists devis_payment_links_actif_idx
  on public.devis_payment_links (mission_id)
  where revoked_at is null and paid_at is null;

alter table public.devis_payment_links enable row level security;
revoke all on table public.devis_payment_links from anon, authenticated;
comment on table public.devis_payment_links is
  'Liens de paiement des devis. Aucune politique RLS : seules les fonctions '
  'SECURITY DEFINER et le service_role y accedent.';

-- 3. Fabrication du lien -------------------------------------------------------
create or replace function secoto_private.devis_link(
  p_mission uuid,
  p_amount_cents integer default null,
  p_validity_days integer default 30,
  p_created_by uuid default null
)
returns public.devis_payment_links
language plpgsql
volatile
security definer
set search_path = public, secoto_private
as $function$
declare
  v_mission public.missions%rowtype;
  v_amount  integer;
  v_link    public.devis_payment_links%rowtype;
begin
  select * into v_mission from public.missions m where m.id = p_mission;
  if not found then raise exception 'Mission introuvable.'; end if;
  if v_mission.cancelled_at is not null then
    raise exception 'Mission annulee : aucun lien de paiement.';
  end if;

  -- Le montant par defaut est ce que le client doit reellement : le total
  -- calcule si la base le tient, sinon le Prix client saisi par l'admin.
  v_amount := coalesce(
    p_amount_cents,
    round(coalesce(nullif(v_mission.client_total_due, 0), v_mission.client_price, 0) * 100)::integer
  );
  if v_amount is null or v_amount <= 0 then
    raise exception 'Renseignez le Prix client avant de creer le lien de paiement.';
  end if;

  -- Un lien vivant au bon montant est reutilise : le client qui a recu le
  -- devis puis le SMS doit tomber sur la meme page.
  select * into v_link
    from public.devis_payment_links l
   where l.mission_id = p_mission
     and l.revoked_at is null
     and l.paid_at is null
     and l.expires_at > now()
     and l.amount_cents = v_amount
   limit 1;
  if found then return v_link; end if;

  -- Sinon les anciens liens sont revoques : une seule adresse valide.
  update public.devis_payment_links
     set revoked_at = now()
   where mission_id = p_mission and revoked_at is null and paid_at is null;

  insert into public.devis_payment_links (mission_id, token, amount_cents, expires_at, created_by)
  values (
    p_mission,
    encode(gen_random_bytes(18), 'hex'),
    v_amount,
    now() + make_interval(days => greatest(1, least(coalesce(p_validity_days, 30), 90))),
    p_created_by
  )
  returning * into v_link;

  return v_link;
end;
$function$;

revoke all on function secoto_private.devis_link(uuid, integer, integer, uuid) from public, anon, authenticated;

-- 4. Cote administrateur : creer et relire le lien -----------------------------
create or replace function public.secoto_admin_devis_link(
  p_mission uuid,
  p_amount_cents integer default null,
  p_validity_days integer default 30
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, secoto_private
as $function$
declare
  v_link public.devis_payment_links%rowtype;
  v_base text;
begin
  if not exists (
    select 1 from public.accounts a
     where a.id = auth.uid() and a.role::text = 'admin' and a.deleted_at is null
  ) then
    raise exception 'Reserve a l''administrateur SECOTO.';
  end if;

  v_link := secoto_private.devis_link(p_mission, p_amount_cents, p_validity_days, auth.uid());

  select coalesce(value ->> 'app_url', 'https://app.secoto-transport.fr')
    into v_base from public.app_settings where key = 'branding';
  v_base := coalesce(v_base, 'https://app.secoto-transport.fr');

  return jsonb_build_object(
    'url',          v_base || '/.netlify/functions/devis-pay?t=' || v_link.token,
    'amount_cents', v_link.amount_cents,
    'expires_at',   v_link.expires_at
  );
end;
$function$;

grant execute on function public.secoto_admin_devis_link(uuid, integer, integer) to authenticated;

-- 5. Cote serveur : ouvrir le lien et preparer le paiement ----------------------
-- Appelee uniquement par la fonction Netlify devis-pay (service_role). Elle ne
-- renvoie jamais d'identifiant de mission au client.
create or replace function public.secoto_devis_link_open(p_token text)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, secoto_private
as $function$
declare
  v_link    public.devis_payment_links%rowtype;
  v_mission public.missions%rowtype;
  v_account uuid;
  v_payment public.payments%rowtype;
begin
  select * into v_link
    from public.devis_payment_links l
   where l.token = p_token
   for update;
  if not found then return jsonb_build_object('error', 'lien_inconnu'); end if;
  if v_link.paid_at is not null then return jsonb_build_object('error', 'deja_paye'); end if;
  if v_link.revoked_at is not null then return jsonb_build_object('error', 'lien_revoque'); end if;
  if v_link.expires_at <= now() then return jsonb_build_object('error', 'lien_expire'); end if;

  select * into v_mission from public.missions m where m.id = v_link.mission_id;
  if not found then return jsonb_build_object('error', 'lien_inconnu'); end if;
  if v_mission.cancelled_at is not null then return jsonb_build_object('error', 'course_annulee'); end if;
  if coalesce(v_mission.payment_status, '') = 'paid' then
    return jsonb_build_object('error', 'deja_paye');
  end if;

  -- payments.account_id est obligatoire : faute de compte client, la ligne est
  -- rattachee au compte SECOTO, qui reste le beneficiaire de l'encaissement.
  v_account := v_mission.client_account_id;
  if v_account is null then
    select a.id into v_account from public.accounts a
     where a.role::text = 'admin' and a.deleted_at is null
     order by a.created_at limit 1;
  end if;
  if v_account is null then return jsonb_build_object('error', 'compte_introuvable'); end if;

  -- Une seule ligne de paiement par lien : un client qui recharge la page ne
  -- doit pas semer des paiements en attente.
  select * into v_payment
    from public.payments p
   where p.mission_id = v_link.mission_id
     and p.purpose = 'devis_course'
     and p.status in ('pending', 'processing')
     and p.amount_cents = v_link.amount_cents
   order by p.created_at desc
   limit 1;

  if not found then
    insert into public.payments (mission_id, account_id, purpose, amount_cents, currency, status)
    values (v_link.mission_id, v_account, 'devis_course', v_link.amount_cents, v_link.currency, 'pending')
    returning * into v_payment;
  end if;

  update public.devis_payment_links
     set payment_id = v_payment.id
   where id = v_link.id;

  return jsonb_build_object(
    'payment_id',   v_payment.id,
    'amount_cents', v_payment.amount_cents,
    'currency',     v_payment.currency,
    'reference',    coalesce(v_mission.public_ref, ''),
    'trajet',       coalesce(v_mission.from_city, '') || ' - ' || coalesce(v_mission.to_city, ''),
    'vehicule',     coalesce(nullif(v_mission.vehicle, ''), '')
  );
end;
$function$;

revoke all on function public.secoto_devis_link_open(text) from public, anon, authenticated;

-- 6. Le paiement vaut acceptation ----------------------------------------------
-- secoto_settle_payment marque deja la mission payee. Il reste a considerer le
-- devis comme accepte : on le passe en « signe », ce qui declenche la chaine
-- documentaire existante, puis on libere le bon de mission.
create or replace function secoto_private.devis_course_paid()
returns trigger
language plpgsql
security definer
set search_path = public, secoto_private
as $function$
declare
  v_devis public.documents%rowtype;
begin
  if new.purpose <> 'devis_course' or new.status <> 'paid' or coalesce(old.status, '') = 'paid' then
    return new;
  end if;

  update public.devis_payment_links
     set paid_at = now(), payment_id = new.id
   where mission_id = new.mission_id and paid_at is null;

  select * into v_devis
    from public.documents d
   where d.mission_id = new.mission_id
     and d.doc_type::text = 'devis'
   order by d.created_at desc
   limit 1;

  if found and v_devis.statut::text <> 'signe' then
    update public.documents
       set statut = 'signe'::public.secoto_doc_statut,
           signed_at = now()
     where id = v_devis.id;
  end if;

  perform public.secoto_release_mission_order(new.mission_id);
  return new;
end;
$function$;

drop trigger if exists trg_devis_course_paid on public.payments;
create trigger trg_devis_course_paid
after update of status on public.payments
for each row execute function secoto_private.devis_course_paid();

-- 7. Le bouton dans le devis ----------------------------------------------------
-- La maquette porte desormais {{BOUTON_PAIEMENT}} : on l'alimente au moment du
-- rendu, sans toucher au reste de secoto_render_document.
do $patch$
declare
  v_src  text;
  v_new  text;
  v_anchor text := '      v_html := replace(v_html, ''{{CONTACT_SUR_PLACE}}''';
  v_insert text;
begin
  select pg_get_functiondef(p.oid) into v_src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'secoto_render_document'
   limit 1;
  if v_src is null then
    raise notice 'secoto_render_document absente : bouton de paiement non pose.';
    return;
  end if;
  if position('{{BOUTON_PAIEMENT}}' in v_src) > 0 then
    raise notice 'Bouton de paiement deja pose.';
    return;
  end if;
  if position(v_anchor in v_src) = 0 then
    raise notice 'Point d''insertion introuvable : bouton de paiement non pose.';
    return;
  end if;

  v_insert :=
    '      declare' || chr(10) ||
    '        v_lien public.devis_payment_links%rowtype;' || chr(10) ||
    '        v_url  text;' || chr(10) ||
    '      begin' || chr(10) ||
    '        v_lien := secoto_private.devis_link(p_mission, null, 30, null);' || chr(10) ||
    '        select coalesce(value ->> ''app_url'', ''https://app.secoto-transport.fr'')' || chr(10) ||
    '          into v_url from public.app_settings where key = ''branding'';' || chr(10) ||
    '        v_url := coalesce(v_url, ''https://app.secoto-transport.fr'')' || chr(10) ||
    '                 || ''/.netlify/functions/devis-pay?t='' || v_lien.token;' || chr(10) ||
    '        v_html := replace(v_html, ''{{BOUTON_PAIEMENT}}'',' || chr(10) ||
    '          ''<a href="'' || v_url || ''" style="display:inline-block;padding:14px 26px;'' ||' || chr(10) ||
    '          ''background:#e8622a;color:#ffffff;border-radius:10px;font-weight:700;'' ||' || chr(10) ||
    '          ''text-decoration:none">Payer la course — '' ||' || chr(10) ||
    '          public.secoto_fmt_amount(v_lien.amount_cents / 100.0) || ''</a>'');' || chr(10) ||
    '      exception when others then' || chr(10) ||
    '        -- Un devis doit sortir meme si le lien ne peut pas etre fabrique.' || chr(10) ||
    '        v_html := replace(v_html, ''{{BOUTON_PAIEMENT}}'', '''');' || chr(10) ||
    '      end;' || chr(10);

  v_new := replace(v_src, v_anchor, v_insert || v_anchor);
  execute v_new;
end;
$patch$;

-- 8. Rechargement du schema pour PostgREST --------------------------------------
notify pgrst, 'reload schema';
-- ============================================================================
-- SECOTO — MIGRATION 039 : DEUX VOIES DE REGLEMENT POUR LA MISE EN RELATION
-- ----------------------------------------------------------------------------
-- Decision de Nawfal du 23/09/2026. Sur une mission plateau, le client choisit :
--
--   · ESPECES — il regle le transporteur de la main a la main. SECOTO n'encaisse
--     rien : c'est le TRANSPORTEUR qui doit virer la commission de mise en
--     relation. L'app envoie une relance unique, deux jours apres la livraison,
--     au transporteur et a l'administrateur. Elle s'arrete des que la commission
--     est marquee encaissee.
--
--   · CARTE — il regle tout en une fois depuis le lien du devis. Stripe garde la
--     commission sur le compte SECOTO et verse sa part au transporteur sur SON
--     compte bancaire : rien ne transite par la banque de SECOTO.
--
-- Le versement du transporteur suit la mecanique de la migration 036 : il attend
-- que le transporteur ait active ses versements, sans bloquer l'encaissement.
-- ============================================================================

-- 1. Depuis quand la commission est-elle due ? ---------------------------------
alter table public.missions add column if not exists commission_due_since timestamptz;
alter table public.missions add column if not exists commission_reminder_sent_at timestamptz;

comment on column public.missions.commission_due_since is
  'Livraison d''une mission plateau reglee en especes : point de depart de la relance.';
comment on column public.missions.commission_reminder_sent_at is
  'Date de la relance envoyee au transporteur. NULL = jamais relance.';

create index if not exists missions_commission_relance_idx
  on public.missions (commission_due_since)
  where commission_due_since is not null and commission_reminder_sent_at is null;

-- 2. Marquer la dette a la livraison -------------------------------------------
create or replace function secoto_private.trg_commission_especes_due()
returns trigger language plpgsql volatile security definer set search_path = ''
as $f$
declare v_done_new boolean; v_done_old boolean;
begin
  v_done_new := coalesce(new.progress_status, '') in ('delivery_completed', 'completed') or new.status::text = 'completed';
  v_done_old := coalesce(old.progress_status, '') in ('delivery_completed', 'completed') or old.status::text = 'completed';
  if not v_done_new or v_done_old then return new; end if;
  if new.type::text <> 'plateau' then return new; end if;
  if lower(coalesce(new.payment_method, '')) not in ('especes', 'espèces', 'cash') then return new; end if;
  if coalesce(new.commission_amount, 0) <= 0 then return new; end if;
  if coalesce(new.commission_settled_offline, false) or new.commission_paid_at is not null then return new; end if;

  update public.missions
     set commission_due_since = coalesce(commission_due_since, now())
   where id = new.id;
  return new;
end;
$f$;

drop trigger if exists trg_secoto_commission_especes_due on public.missions;
create trigger trg_secoto_commission_especes_due
  after update of status, progress_status on public.missions
  for each row execute function secoto_private.trg_commission_especes_due();

-- 3. La relance, une seule fois, deux jours apres ------------------------------
-- Appelee a chaque passage de la maintenance. Elle est sans effet tant que
-- l'echeance n'est pas atteinte, et ne relance jamais deux fois la meme course.
create or replace function public.secoto_commission_relances()
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, secoto_private
as $function$
declare
  v_delai   numeric;
  v_mission record;
  v_envoyees integer := 0;
  v_total_du numeric := 0;
  v_montant text;
begin
  v_delai := coalesce(secoto_private.policy_num('commission_relance_hours', 48), 48);

  for v_mission in
    select m.id, m.public_ref, m.commission_amount, m.assigned_transporter_id,
           m.from_city, m.to_city
      from public.missions m
     where m.commission_due_since is not null
       and m.commission_reminder_sent_at is null
       and m.cancelled_at is null
       and coalesce(m.commission_settled_offline, false) = false
       and m.commission_paid_at is null
       and m.assigned_transporter_id is not null
       and m.commission_due_since + make_interval(hours => v_delai::int) <= now()
     order by m.commission_due_since
     limit 50
  loop
    v_montant := replace(to_char(v_mission.commission_amount, 'FM999990D00'), '.', ',');

    perform secoto_private.notify_event(
      v_mission.assigned_transporter_id, 'payment',
      'Commission SECOTO a regler',
      format('Mission %s (%s - %s) : il reste %s € de frais de mise en relation a virer a SECOTO. '
             || 'Le RIB figure sur votre facture.',
             coalesce(v_mission.public_ref, ''), coalesce(v_mission.from_city, ''),
             coalesce(v_mission.to_city, ''), v_montant),
      v_mission.id, 'paiement', 'commission-relance:' || v_mission.id::text, v_mission.id);

    update public.missions
       set commission_reminder_sent_at = now()
     where id = v_mission.id;

    v_envoyees := v_envoyees + 1;
    v_total_du := v_total_du + coalesce(v_mission.commission_amount, 0);
  end loop;

  -- Un seul recapitulatif pour l'administrateur, pas une notification par course.
  if v_envoyees > 0 then
    perform secoto_private.notify_admins_event(
      'payment', 'Commissions en attente',
      format('%s transporteur(s) relance(s) : %s € de commissions restent a encaisser.',
             v_envoyees, replace(to_char(v_total_du, 'FM999990D00'), '.', ',')),
      'paiement', 'commission-relance-admin:' || to_char(now(), 'YYYYMMDDHH24'), null);
  end if;

  return jsonb_build_object('relances', v_envoyees, 'montant_du', v_total_du);
end;
$function$;

revoke all on function public.secoto_commission_relances() from public, anon, authenticated;

-- 4. Carte bancaire : le transporteur est paye par Stripe ----------------------
-- Le garde-fou « plateau » de la migration 036 protegeait d'un double paiement :
-- le client payait le transporteur en direct. Quand la course a ete reglee par
-- carte via le lien du devis, ce n'est plus vrai, et le versement doit partir.
create or replace function secoto_private.trg_manual_mission_payout()
returns trigger language plpgsql volatile security definer set search_path = ''
as $f$
declare v_done_new boolean; v_done_old boolean; v_cutover timestamptz; v_regle_par_carte boolean;
begin
  v_done_new := coalesce(new.progress_status, '') in ('delivery_completed', 'completed') or new.status::text = 'completed';
  v_done_old := coalesce(old.progress_status, '') in ('delivery_completed', 'completed') or old.status::text = 'completed';
  if not v_done_new or v_done_old then return new; end if;
  if new.assigned_transporter_id is null or coalesce(new.carrier_pay, 0) <= 0 then return new; end if;
  if lower(coalesce(new.payment_method, '')) in ('especes', 'espèces', 'cash') then return new; end if;
  -- Commandes en ligne : versement créé par trg_od_sync_from_mission.
  if exists (select 1 from public.transport_orders o where o.mission_id = new.id) then return new; end if;

  -- La course a-t-elle ete reglee entierement a SECOTO par le lien du devis ?
  select exists (
    select 1 from public.payments p
     where p.mission_id = new.id and p.purpose = 'devis_course' and p.status = 'paid'
  ) into v_regle_par_carte;

  -- Plateau antérieur à la sous-traitance totale : le client payait le
  -- transport en direct au transporteur. Verser en plus serait payer deux fois.
  select (s.value ->> 'sous_traitance_totale_since')::timestamptz into v_cutover
    from public.app_settings s where s.key = 'dispatch_policy';
  if new.type::text = 'plateau'
     and not v_regle_par_carte
     and (v_cutover is null or coalesce(new.created_at, now()) < v_cutover) then
    return new;
  end if;

  insert into public.partner_payouts(mission_id, order_id, partner_id, amount_cents, due_at, mode, kind)
  values (new.id, null, new.assigned_transporter_id, round(new.carrier_pay * 100)::int,
          now() + make_interval(hours => secoto_private.policy_num('payout_delay_hours', 48)::int),
          new.type::text, 'mission')
  on conflict (mission_id) do nothing;
  if found then
    perform secoto_private.notify_event(new.assigned_transporter_id, 'payment', 'Paiement programmé',
      format('Mission %s livrée : paiement de %s € déclenché sous 48 heures.', new.public_ref,
        replace(to_char(new.carrier_pay, 'FM999990D00'), '.', ',')),
      new.id, 'paiement', 'manual-payout:' || new.id::text, new.id);
  end if;
  return new;
end;
$f$;

drop trigger if exists trg_secoto_manual_mission_payout on public.missions;
create trigger trg_secoto_manual_mission_payout
  after update of status, progress_status on public.missions
  for each row execute function secoto_private.trg_manual_mission_payout();

-- 5. Le lien du devis refuse les missions reglees en especes -------------------
-- Sinon le client paierait SECOTO alors qu'il a deja paye le transporteur.
do $patch$
declare v_src text;
begin
  select pg_get_functiondef(p.oid) into v_src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'secoto_devis_link_open';
  if v_src is null or position('reglement_especes' in v_src) > 0 then return; end if;
  v_src := replace(v_src,
    '  if coalesce(v_mission.payment_status, '''') = ''paid'' then',
    '  if lower(coalesce(v_mission.payment_method, '''')) in (''especes'', ''espèces'', ''cash'') then'
    || chr(10) || '    return jsonb_build_object(''error'', ''reglement_especes'');'
    || chr(10) || '  end if;'
    || chr(10) || '  if coalesce(v_mission.payment_status, '''') = ''paid'' then');
  execute v_src;
end;
$patch$;

-- 6. Delai de relance reglable -------------------------------------------------
update public.app_settings
   set value = jsonb_set(coalesce(value, '{}'::jsonb), '{commission_relance_hours}', '48'::jsonb, true)
 where key = 'dispatch_policy'
   and not (coalesce(value, '{}'::jsonb) ? 'commission_relance_hours');

notify pgrst, 'reload schema';
