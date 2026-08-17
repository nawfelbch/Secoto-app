-- ============================================================================
-- SECOTO — MIGRATION 009
-- Paiement Stripe · Barème convoyage en paliers · Commission plateau 20 %
-- Verrou du bon de mission · Notifications complètes · Fondations groupage
-- ----------------------------------------------------------------------------
-- À coller EN UNE SEULE FOIS dans le SQL Editor Supabase (projet
-- znnigxmzacukpfueqfrh). Idempotent et rejouable.
--
-- ⚠️  AVERTISSEMENT — OPÉRATIONS NON DESTRUCTRICES MAIS LOURDES
--   • §3 réécrit l'expression des colonnes générées missions.client_price,
--     missions.carrier_pay et missions.margin (ALTER COLUMN ... SET EXPRESSION,
--     PostgreSQL 17). La table missions est RÉÉCRITE et VERROUILLÉE le temps de
--     l'opération. Aucune donnée saisie n'est perdue : ces trois colonnes sont
--     entièrement dérivées. En revanche, conformément à la décision prise,
--     TOUTES les missions existantes sont RECALCULÉES au nouveau barème.
--     Les documents déjà émis restent figés (html_snapshot) : la facturation
--     passée n'est pas altérée, seuls les montants affichés dans l'espace
--     admin changent.
--   • §3 supprime ensuite les anciennes signatures à 3 arguments de
--     secoto_compute_client_price / _margin. Plus aucun appelant ne les utilise
--     après cette migration.
--   • Faire une sauvegarde PITR avant exécution.
-- ============================================================================

begin;

-- ============================================================================
-- 1. COLONNES MÉTIER SUR missions
-- ============================================================================

-- Suppléments convoyage — 100 % manuels (cases cochées par l'admin).
alter table public.missions
  add column if not exists surcharge_urgent boolean not null default false;
alter table public.missions
  add column if not exists surcharge_weekend boolean not null default false;
alter table public.missions
  add column if not exists surcharge_oversize_pct numeric(5,2) not null default 0;

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'missions_surcharge_oversize_pct_check'
  ) then
    alter table public.missions
      add constraint missions_surcharge_oversize_pct_check
      check (surcharge_oversize_pct >= 0 and surcharge_oversize_pct <= 40);
  end if;
end $$;

-- État de paiement de la mission (miroir dénormalisé de public.payments).
alter table public.missions
  add column if not exists payment_status text not null default 'not_required';
alter table public.missions
  add column if not exists commission_paid_at timestamptz;
alter table public.missions
  add column if not exists cancelled_at timestamptz;
alter table public.missions
  add column if not exists cancelled_by uuid;
alter table public.missions
  add column if not exists cancellation_reason text;
alter table public.missions
  add column if not exists cancellation_fee numeric(12,2) not null default 0;

do $$
begin
  if not exists (
    select 1 from pg_constraint where conname = 'missions_payment_status_check'
  ) then
    alter table public.missions
      add constraint missions_payment_status_check
      check (payment_status in (
        'not_required', 'awaiting_payment', 'paid', 'failed', 'refunded'
      ));
  end if;
end $$;

-- Fondations groupage (chantier suivant : aucune UI livrée ici).
alter table public.missions
  add column if not exists capacity_units numeric(5,2) not null default 1;
alter table public.missions
  add column if not exists window_start date;
alter table public.missions
  add column if not exists window_end date;

comment on column public.missions.capacity_units is
  'Unités de capacité consommées. 1 plateau = 3 voitures = 6 motos, donc une '
  'voiture vaut 1 unité et une moto 0,5 unité sur une capacité totale de 3.';

-- ============================================================================
-- 2. MOTEUR TARIFAIRE — SOURCE UNIQUE DE VÉRITÉ
-- ============================================================================
-- CONVOYAGE (sous-traitance) : SECOTO encaisse la totalité du prix client.
--   Paliers CUMULATIFS, chaque tarif ne s'applique qu'aux km de sa tranche :
--     0-300 km     1,00 €/km
--     301-600 km   0,90 €/km
--     > 600 km     0,88 €/km
--   Plancher : forfait minimum 115 €.
--   Suppléments multiplicateurs cumulables, cochés manuellement par l'admin :
--     urgence < 24 h  +30 %   week-end  +20 %   gabarit/premium  0 à +40 %
--   Rémunération convoyeur : 0,55 €/km. Frais réels remboursés à l'euro près.
--
-- PLATEAU / MOTO (intermédiation) : le transporteur fixe LIBREMENT son tarif.
--   SECOTO n'encaisse QUE la commission de 20 %, ajoutée au tarif transporteur.
--   Le prix du transport ne transite JAMAIS par SECOTO.
--     transport_amount   = tarif du transporteur, payé directement par le client
--     commission_amount  = 20 % de ce tarif, seul montant encaissé par SECOTO
--     client_total_due   = transport_amount + commission_amount
-- ============================================================================

create or replace function public.secoto_convoyage_base(p_distance_km numeric)
returns numeric
language sql
immutable
set search_path = ''
as $function$
  select greatest(
    115.00,
    round(
        least(greatest(coalesce(p_distance_km, 0), 0), 300) * 1.00
      + least(greatest(greatest(coalesce(p_distance_km, 0), 0) - 300, 0), 300) * 0.90
      + greatest(greatest(coalesce(p_distance_km, 0), 0) - 600, 0) * 0.88
      , 2)
  );
$function$;

comment on function public.secoto_convoyage_base(numeric) is
  'Barème convoyage à paliers cumulatifs, plancher 115 €. '
  '80 km -> 115,00 · 400 km -> 390,00 · 935 km -> 864,80.';

create or replace function public.secoto_surcharge_coefficient(
  p_urgent boolean,
  p_weekend boolean,
  p_oversize_pct numeric
)
returns numeric
language sql
immutable
set search_path = ''
as $function$
  select (case when coalesce(p_urgent, false)  then 1.30 else 1 end)
       * (case when coalesce(p_weekend, false) then 1.20 else 1 end)
       * (1 + least(greatest(coalesce(p_oversize_pct, 0), 0), 40) / 100.0);
$function$;

-- Montant réellement ENCAISSÉ PAR SECOTO auprès du client.
create or replace function public.secoto_compute_client_price(
  p_type text,
  p_distance_km numeric,
  p_carrier_cost numeric,
  p_urgent boolean,
  p_weekend boolean,
  p_oversize_pct numeric
)
returns numeric
language sql
immutable
set search_path = ''
as $function$
  select round(
    case p_type
      when 'convoyage' then
        public.secoto_convoyage_base(p_distance_km)
        * public.secoto_surcharge_coefficient(p_urgent, p_weekend, p_oversize_pct)
      when 'plateau' then
        greatest(coalesce(p_carrier_cost, 0), 0) * 0.20
      else 0
    end, 2);
$function$;

-- Tarif du transporteur plateau : payé DIRECTEMENT par le client, hors SECOTO.
create or replace function public.secoto_compute_transport_amount(
  p_type text,
  p_carrier_cost numeric
)
returns numeric
language sql
immutable
set search_path = ''
as $function$
  select round(
    case when p_type = 'plateau'
      then greatest(coalesce(p_carrier_cost, 0), 0)
      else 0
    end, 2);
$function$;

-- Rémunération de la prestation versée au prestataire.
-- Convoyage : 0,55 €/km versés par SECOTO. Plateau : tarif transporteur,
-- que SECOTO ne verse PAS (il est réglé en direct par le client).
create or replace function public.secoto_compute_carrier_pay(
  p_type text,
  p_distance_km numeric,
  p_carrier_cost numeric
)
returns numeric
language sql
immutable
set search_path = ''
as $function$
  select round(
    case p_type
      when 'plateau' then greatest(coalesce(p_carrier_cost, 0), 0)
      when 'convoyage' then greatest(coalesce(p_distance_km, 0), 0) * 0.55
      else 0
    end, 2);
$function$;

-- Marge nette SECOTO. Plateau : la commission entière (SECOTO ne verse rien).
create or replace function public.secoto_compute_margin(
  p_type text,
  p_distance_km numeric,
  p_carrier_cost numeric,
  p_urgent boolean,
  p_weekend boolean,
  p_oversize_pct numeric
)
returns numeric
language sql
immutable
set search_path = ''
as $function$
  select case
    when p_type = 'plateau' then
      public.secoto_compute_client_price(
        p_type, p_distance_km, p_carrier_cost, p_urgent, p_weekend, p_oversize_pct)
    else round(
      public.secoto_compute_client_price(
        p_type, p_distance_km, p_carrier_cost, p_urgent, p_weekend, p_oversize_pct)
      - public.secoto_compute_carrier_pay(p_type, p_distance_km, p_carrier_cost)
      , 2)
  end;
$function$;

-- ============================================================================
-- 3. RECÂBLAGE DES COLONNES GÉNÉRÉES  ⚠️  RÉÉCRITURE DE LA TABLE missions
-- ============================================================================
-- SET EXPRESSION (PostgreSQL 17) conserve la colonne, ses droits et les vues
-- qui en dépendent : aucun DROP COLUMN, donc aucun CASCADE sur les 4 vues.

-- Les quatre vues cloisonnées dépendent des colonnes recâblées ci-dessous.
-- On les supprime ici et la section 14 les recrée intégralement, droits
-- compris. Tout est dans une seule transaction : en cas d'échec, rien n'est
-- perdu et les vues sont restaurées par le ROLLBACK.
drop view if exists public.secoto_missions_admin_v2;
drop view if exists public.secoto_missions_client_v2;
drop view if exists public.secoto_missions_transporter_v2;
drop view if exists public.secoto_public_missions_v2;

do $rewire$
begin
  if exists (
    select 1 from pg_attribute a
    join pg_class c on c.oid = a.attrelid
    join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relname = 'missions'
      and a.attname = 'client_price' and a.attgenerated = 's'
  ) then
    alter table public.missions
      alter column client_price
      set expression as (
        public.secoto_compute_client_price(
          type::text, distance_km, carrier_cost,
          surcharge_urgent, surcharge_weekend, surcharge_oversize_pct)
      );
    alter table public.missions
      alter column margin
      set expression as (
        public.secoto_compute_margin(
          type::text, distance_km, carrier_cost,
          surcharge_urgent, surcharge_weekend, surcharge_oversize_pct)
      );
  end if;
end
$rewire$;

alter table public.missions
  add column if not exists commission_amount numeric(12,2)
  generated always as (
    round(case when type::text = 'plateau'
      then greatest(coalesce(carrier_cost, 0), 0) * 0.20
      else 0 end, 2)
  ) stored;

alter table public.missions
  add column if not exists transport_amount numeric(12,2)
  generated always as (
    public.secoto_compute_transport_amount(type::text, carrier_cost)
  ) stored;

-- Total réellement déboursé par le client, toutes lignes confondues.
alter table public.missions
  add column if not exists client_total_due numeric(12,2)
  generated always as (
    round(
      public.secoto_compute_client_price(
        type::text, distance_km, carrier_cost,
        surcharge_urgent, surcharge_weekend, surcharge_oversize_pct)
      + public.secoto_compute_transport_amount(type::text, carrier_cost)
    , 2)
  ) stored;

-- Anciennes signatures à 3 arguments : plus aucun appelant.
drop function if exists public.secoto_compute_client_price(text, numeric, numeric);
drop function if exists public.secoto_compute_margin(text, numeric, numeric);

-- ============================================================================
-- 4. PAIEMENTS
-- ============================================================================

-- Identifiant client Stripe, réutilisé d'un paiement à l'autre : c'est ce qui
-- permet au client de retrouver ses cartes enregistrées. Aucune donnée
-- bancaire n'est stockée par SECOTO.
alter table public.accounts
  add column if not exists stripe_customer_id text;

create unique index if not exists accounts_stripe_customer_key
  on public.accounts (stripe_customer_id)
  where stripe_customer_id is not null;

create table if not exists public.payments (
  id                    uuid primary key default gen_random_uuid(),
  mission_id            uuid not null references public.missions(id) on delete cascade,
  account_id            uuid not null references public.accounts(id),
  purpose               text not null,
  amount_cents          integer not null,
  currency              text not null default 'eur',
  status                text not null default 'pending',
  provider              text not null default 'stripe',
  provider_intent_id    text,
  -- Renonciation au droit de rétractation : trace horodatée et versionnée,
  -- exigée pour être opposable. Jamais pré-cochée côté application.
  waiver_required       boolean not null default false,
  waiver_accepted       boolean not null default false,
  waiver_accepted_at    timestamptz,
  waiver_text_version   text,
  refund_requested_at   timestamptz,
  refund_reason         text,
  refunded_amount_cents integer not null default 0,
  paid_at               timestamptz,
  failed_at             timestamptz,
  last_error            text,
  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now()
);

do $payment_constraints$
begin
  if not exists (select 1 from pg_constraint where conname = 'payments_purpose_check') then
    alter table public.payments add constraint payments_purpose_check
      check (purpose in ('commission_plateau', 'convoyage_livraison'));
  end if;
  if not exists (select 1 from pg_constraint where conname = 'payments_status_check') then
    alter table public.payments add constraint payments_status_check
      check (status in (
        'pending', 'processing', 'paid', 'failed',
        'refund_pending', 'refunded', 'cancelled'
      ));
  end if;
  if not exists (select 1 from pg_constraint where conname = 'payments_amount_check') then
    alter table public.payments add constraint payments_amount_check
      check (amount_cents > 0 and refunded_amount_cents >= 0);
  end if;
end
$payment_constraints$;

create unique index if not exists payments_provider_intent_key
  on public.payments (provider_intent_id)
  where provider_intent_id is not null;

-- Un seul paiement vivant par mission et par objet.
create unique index if not exists payments_mission_purpose_live_key
  on public.payments (mission_id, purpose)
  where status in ('pending', 'processing', 'paid', 'refund_pending');

create index if not exists payments_account_idx on public.payments (account_id, created_at desc);
create index if not exists payments_status_idx  on public.payments (status, created_at);

create table if not exists public.payment_events (
  id             uuid primary key default gen_random_uuid(),
  payment_id     uuid not null references public.payments(id) on delete cascade,
  event_type     text not null,
  provider_event_id text,
  payload        jsonb,
  created_at     timestamptz not null default now()
);

create unique index if not exists payment_events_provider_key
  on public.payment_events (provider_event_id)
  where provider_event_id is not null;

alter table public.payments       enable row level security;
alter table public.payment_events enable row level security;

drop policy if exists payments_read_authorized on public.payments;
create policy payments_read_authorized on public.payments
  for select to authenticated
  using (
    account_id = auth.uid()
    or public.secoto_is_admin()
  );

-- Aucune écriture directe : tout passe par les RPC et le webhook Stripe.
drop policy if exists payment_events_read_admin on public.payment_events;
create policy payment_events_read_admin on public.payment_events
  for select to authenticated
  using (public.secoto_is_admin());

-- ============================================================================
-- 5. NOTIFICATIONS — ÉLARGISSEMENT DES TYPES ET DES ÉCRANS
-- ============================================================================

create or replace function secoto_private.notify_one(
  p_account_id uuid,
  p_type text,
  p_mission_id uuid,
  p_screen text,
  p_event_key text
)
returns uuid
language plpgsql
volatile
security definer
set search_path = ''
as $function$
declare
  v_notification_id uuid;
  v_title text;
  v_body text;
  v_audience text;
  v_mission public.missions%rowtype;
begin
  if p_account_id is null then
    return null;
  end if;
  if p_type not in (
    'new_course', 'course_assigned', 'tracking', 'delivered',
    'new_request', 'new_application', 'frais', 'frais_status',
    'document', 'transporter_status', 'system',
    -- Types ajoutés par la migration 009.
    'payment', 'payment_failed', 'cancellation', 'new_account'
  ) then
    raise exception 'Type de notification serveur non autorise.';
  end if;
  if p_screen not in (
    'courses', 'documents', 'frais', 'available', 'assigned',
    'applications', 'requests',
    -- Écrans ajoutés par la migration 009.
    'paiement', 'transporters'
  ) then
    raise exception 'Ecran de notification non autorise.';
  end if;

  if p_mission_id is not null then
    select * into v_mission from public.missions m where m.id = p_mission_id;
  end if;

  v_title := case p_type
    when 'new_course' then 'Nouvelle course disponible'
    when 'course_assigned' then 'Mission attribuee'
    when 'tracking' then 'Mise a jour de la mission'
    when 'delivered' then 'Mission livree'
    when 'new_request' then 'Nouvelle demande'
    when 'new_application' then 'Nouvelle candidature'
    when 'frais' then 'Nouveau frais'
    when 'frais_status' then 'Statut d''un frais'
    when 'document' then 'Document disponible'
    when 'transporter_status' then 'Statut du compte mis a jour'
    when 'payment' then 'Paiement encaisse'
    when 'payment_failed' then 'Echec de paiement'
    when 'cancellation' then 'Mission annulee'
    when 'new_account' then 'Nouvelle inscription'
    else 'Information SECOTO'
  end;

  v_body := case p_type
    when 'new_course' then
      coalesce(v_mission.from_city, 'Depart') || ' vers ' || coalesce(v_mission.to_city, 'Arrivee')
    when 'course_assigned' then 'Consultez les informations autorisees de cette mission dans SECOTO.'
    when 'tracking' then 'Une nouvelle etape terrain est disponible dans SECOTO.'
    when 'delivered' then 'La livraison et son etat des lieux sont disponibles dans SECOTO.'
    when 'new_request' then 'Une demande attend une decision dans SECOTO.'
    when 'new_application' then 'Une candidature attend une decision dans SECOTO.'
    when 'frais' then 'Un justificatif de frais attend une verification dans SECOTO.'
    when 'frais_status' then 'La decision concernant un frais est disponible dans SECOTO.'
    when 'document' then 'Un document est disponible dans votre espace SECOTO.'
    when 'transporter_status' then 'Consultez votre profil SECOTO pour connaitre la decision.'
    when 'payment' then 'Un paiement vient d''etre encaisse dans SECOTO.'
    when 'payment_failed' then 'Un paiement n''a pas abouti. Consultez SECOTO pour reessayer.'
    when 'cancellation' then 'Une mission a ete annulee. Le detail est disponible dans SECOTO.'
    when 'new_account' then 'Un nouveau compte vient d''etre cree et attend une verification.'
    else 'Une information est disponible dans SECOTO.'
  end;

  select a.role::text into v_audience from public.accounts a where a.id = p_account_id;

  -- Préférences par rôle : un canal coupé n'empêche jamais la trace en base,
  -- il empêche uniquement la mise en file d'attente du push (cf. §6).
  insert into public.notifications(
    account_id, type, title, body, mission_id, audience, is_read, push_screen, event_key
  )
  values (
    p_account_id, p_type, v_title, v_body, p_mission_id, v_audience, false, p_screen, p_event_key
  )
  on conflict (event_key) where event_key is not null
  do nothing
  returning id into v_notification_id;

  if v_notification_id is null and p_event_key is not null then
    select n.id into v_notification_id
    from public.notifications n where n.event_key = p_event_key;
  end if;
  return v_notification_id;
end;
$function$;

create or replace function secoto_private.prepare_notification()
returns trigger
language plpgsql
volatile
security definer
set search_path = ''
as $function$
begin
  new.push_screen := case
    when new.push_screen in (
      'courses','documents','frais','available','assigned',
      'applications','requests','paiement','transporters'
    ) then new.push_screen
    when new.type = 'document' then 'documents'
    when new.type in ('frais','frais_status') then 'frais'
    when new.type = 'new_application' then 'applications'
    when new.type = 'new_request' then 'requests'
    when new.type = 'new_course' then 'available'
    when new.type in ('payment','payment_failed') then 'paiement'
    when new.type = 'new_account' then 'transporters'
    when new.type in ('tracking','delivered','course_assigned','cancellation') then 'courses'
    else 'courses'
  end;
  new.event_key := coalesce(new.event_key, 'notification:' || new.id::text);
  return new;
end;
$function$;

-- ============================================================================
-- 6. PRÉFÉRENCES DE NOTIFICATION PAR RÔLE
-- ============================================================================

create table if not exists public.notification_preferences (
  account_id     uuid primary key references public.accounts(id) on delete cascade,
  push_enabled   boolean not null default true,
  email_enabled  boolean not null default true,
  -- Catégories désactivables. Les événements de paiement et d'annulation ne
  -- sont volontairement PAS désactivables : ce sont des obligations
  -- d'information contractuelle.
  mute_missions  boolean not null default false,
  mute_documents boolean not null default false,
  mute_frais     boolean not null default false,
  updated_at     timestamptz not null default now()
);

alter table public.notification_preferences enable row level security;

drop policy if exists notification_preferences_own on public.notification_preferences;
create policy notification_preferences_own on public.notification_preferences
  for select to authenticated
  using (account_id = auth.uid() or public.secoto_is_admin());

create or replace function public.secoto_update_notification_preferences(
  p_push_enabled boolean,
  p_email_enabled boolean,
  p_mute_missions boolean,
  p_mute_documents boolean,
  p_mute_frais boolean
)
returns public.notification_preferences
language plpgsql
volatile
security definer
set search_path = ''
as $function$
declare
  v_user_id uuid := secoto_private.assert_authenticated();
  v_row public.notification_preferences%rowtype;
begin
  insert into public.notification_preferences as np (
    account_id, push_enabled, email_enabled,
    mute_missions, mute_documents, mute_frais, updated_at
  )
  values (
    v_user_id, coalesce(p_push_enabled, true), coalesce(p_email_enabled, true),
    coalesce(p_mute_missions, false), coalesce(p_mute_documents, false),
    coalesce(p_mute_frais, false), now()
  )
  on conflict (account_id) do update set
    push_enabled   = excluded.push_enabled,
    email_enabled  = excluded.email_enabled,
    mute_missions  = excluded.mute_missions,
    mute_documents = excluded.mute_documents,
    mute_frais     = excluded.mute_frais,
    updated_at     = now()
  returning * into v_row;
  return v_row;
end;
$function$;

revoke all on function public.secoto_update_notification_preferences(
  boolean, boolean, boolean, boolean, boolean) from public, anon;
grant execute on function public.secoto_update_notification_preferences(
  boolean, boolean, boolean, boolean, boolean) to authenticated;

-- Le push n'est mis en file que si le destinataire l'accepte pour ce type.
create or replace function secoto_private.enqueue_push_outbox()
returns trigger
language plpgsql
volatile
security definer
set search_path = ''
as $function$
declare
  v_prefs public.notification_preferences%rowtype;
begin
  select * into v_prefs
  from public.notification_preferences p
  where p.account_id = new.account_id;

  if found then
    if not v_prefs.push_enabled then return new; end if;
    if v_prefs.mute_missions
       and new.type in ('new_course', 'course_assigned', 'tracking', 'delivered') then
      return new;
    end if;
    if v_prefs.mute_documents and new.type = 'document' then return new; end if;
    if v_prefs.mute_frais and new.type in ('frais', 'frais_status') then return new; end if;
  end if;

  insert into public.push_outbox(notification_id, event_key, status, available_at)
  values (new.id, 'push:' || new.event_key, 'pending', now())
  on conflict (event_key) do nothing;
  return new;
end;
$function$;

-- ============================================================================
-- 7. FILE D'ATTENTE E-MAIL (doublon des événements critiques)
-- ============================================================================

create table if not exists public.email_outbox (
  id            uuid primary key default gen_random_uuid(),
  account_id    uuid references public.accounts(id) on delete set null,
  to_email      text not null,
  subject       text not null,
  body_text     text not null,
  mission_id    uuid references public.missions(id) on delete set null,
  event_key     text unique,
  status        text not null default 'pending',
  attempts      integer not null default 0,
  max_attempts  integer not null default 6,
  available_at  timestamptz not null default now(),
  sent_at       timestamptz,
  last_error    text,
  created_at    timestamptz not null default now()
);

do $email_constraints$
begin
  if not exists (select 1 from pg_constraint where conname = 'email_outbox_status_check') then
    alter table public.email_outbox add constraint email_outbox_status_check
      check (status in ('pending', 'processing', 'sent', 'failed'));
  end if;
end
$email_constraints$;

create index if not exists email_outbox_pending_idx
  on public.email_outbox (status, available_at);

alter table public.email_outbox enable row level security;
-- Aucune policy : table réservée au service_role (fonction Netlify planifiée).

create or replace function secoto_private.queue_email(
  p_account_id uuid,
  p_subject text,
  p_body text,
  p_mission_id uuid,
  p_event_key text
)
returns void
language plpgsql
volatile
security definer
set search_path = ''
as $function$
declare
  v_email text;
  v_prefs public.notification_preferences%rowtype;
begin
  if p_account_id is null then return; end if;
  select a.email into v_email from public.accounts a
   where a.id = p_account_id and a.deleted_at is null;
  if v_email is null or position('@' in v_email) = 0 then return; end if;

  select * into v_prefs from public.notification_preferences p
   where p.account_id = p_account_id;
  if found and not v_prefs.email_enabled then return; end if;

  insert into public.email_outbox(account_id, to_email, subject, body_text, mission_id, event_key)
  values (p_account_id, v_email, p_subject, p_body, p_mission_id, p_event_key)
  on conflict (event_key) do nothing;
end;
$function$;

-- ============================================================================
-- 8. PAIEMENT — API TRANSACTIONNELLE
-- ============================================================================

-- Mentions légales versionnées, modifiables sans redéployer l'application.
insert into public.app_settings (key, value)
values ('legal_texts', jsonb_build_object(
  'version', '2026-08-17',
  'commission_label', 'Reservation de votre creneau',
  'commission_notice',
    'Ce montant regle la mise en relation et bloque votre creneau aupres du '
    'transporteur. Il remunere SECOTO et n''est pas deduit du prix du transport.',
  'transport_notice',
    'Prix du transport, regle directement au transporteur. Ce montant n''est '
    'pas encaisse par SECOTO.',
  'waiver_execution',
    'Je demande expressement l''execution immediate de la prestation de mise '
    'en relation, avant la fin du delai de retractation.',
  'waiver_withdrawal',
    'Je reconnais renoncer a mon droit de retractation de 14 jours pour cette '
    'prestation, qui sera integralement executee des sa demande.',
  'refund_policy',
    'La commission de mise en relation n''est pas remboursable en cas '
    'd''annulation par le client. Elle est integralement remboursee si le '
    'transporteur se desiste.',
  'carrier_pricing_notice',
    'Vous fixez librement votre tarif. SECOTO preleve une commission de 20 % '
    'sur le montant de la mission.'
))
on conflict (key) do update set value = excluded.value;

-- Barème d'annulation CONVOYAGE, paramétrable. Le préjudice est propre à
-- SECOTO (prestataire), la pénalité y est donc légitime.
insert into public.app_settings (key, value)
values ('cancellation_policy', jsonb_build_object(
  'convoyage', jsonb_build_array(
    jsonb_build_object('hours_before', 72, 'fee_pct', 0),
    jsonb_build_object('hours_before', 24, 'fee_pct', 30),
    jsonb_build_object('hours_before', 0,  'fee_pct', 50)
  ),
  'plateau_commission_refundable_on_client_cancel', false,
  'plateau_commission_refundable_on_carrier_cancel', true
))
on conflict (key) do nothing;

-- Prépare (ou retrouve) le paiement de commission d'une mission plateau.
-- Appelée par le client depuis l'application, juste après la signature du
-- devis. Ne crée AUCUN intent Stripe : c'est la fonction Netlify, seule
-- détentrice de la clé secrète, qui le fait à partir de cette ligne.
create or replace function public.secoto_prepare_commission_payment(
  p_mission_id uuid,
  p_idempotency_key uuid
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $function$
declare
  v_user_id uuid := secoto_private.assert_authenticated();
  v_existing jsonb;
  v_mission public.missions%rowtype;
  v_payment public.payments%rowtype;
  v_devis_signed boolean;
  v_client_type text;
begin
  v_existing := secoto_private.lock_operation('prepare_commission_payment', p_idempotency_key);
  if v_existing is not null then return v_existing; end if;

  select * into v_mission from public.missions m where m.id = p_mission_id;
  if not found then raise exception 'Mission introuvable.'; end if;
  if v_mission.client_account_id is distinct from v_user_id then
    raise exception 'Cette mission ne vous appartient pas.';
  end if;
  if v_mission.type::text <> 'plateau' then
    raise exception 'Le convoyage ne donne lieu a aucun paiement a la reservation.';
  end if;
  if coalesce(v_mission.carrier_cost, 0) <= 0 then
    raise exception 'Le transporteur n''a pas encore fixe son tarif.';
  end if;

  select exists (
    select 1 from public.documents d
    where d.mission_id = p_mission_id
      and d.doc_type::text = 'devis'
      and d.statut::text = 'signe'
  ) into v_devis_signed;
  if not v_devis_signed then
    raise exception 'Le devis doit etre signe avant le paiement.';
  end if;

  select case when a.client_type = 'particulier' then 'particulier' else 'pro' end
    into v_client_type
  from public.accounts a where a.id = v_user_id;

  select * into v_payment from public.payments p
   where p.mission_id = p_mission_id
     and p.purpose = 'commission_plateau'
     and p.status in ('pending', 'processing', 'paid', 'refund_pending');

  if not found then
    insert into public.payments(
      mission_id, account_id, purpose, amount_cents, status, waiver_required
    )
    values (
      p_mission_id, v_user_id, 'commission_plateau',
      (round(v_mission.commission_amount * 100))::integer,
      'pending',
      coalesce(v_client_type, 'pro') = 'particulier'
    )
    returning * into v_payment;

    update public.missions
       set payment_status = 'awaiting_payment'
     where id = p_mission_id;
  end if;

  return secoto_private.finish_operation(
    'prepare_commission_payment',
    p_idempotency_key,
    jsonb_build_object(
      'payment_id',        v_payment.id,
      'status',            v_payment.status,
      'amount_cents',      v_payment.amount_cents,
      'commission_amount', v_mission.commission_amount,
      'transport_amount',  v_mission.transport_amount,
      'client_total_due',  v_mission.client_total_due,
      'waiver_required',   v_payment.waiver_required,
      'client_type',       coalesce(v_client_type, 'pro')
    )
  );
end;
$function$;

-- Enregistre la double mention cochée par le client, AVANT toute confirmation
-- de paiement. Une case pré-cochée annulerait juridiquement la renonciation :
-- l'application ne coche jamais rien à la place du client.
create or replace function public.secoto_accept_payment_waiver(p_payment_id uuid)
returns public.payments
language plpgsql
volatile
security definer
set search_path = ''
as $function$
declare
  v_user_id uuid := secoto_private.assert_authenticated();
  v_payment public.payments%rowtype;
  v_version text;
begin
  select value ->> 'version' into v_version
  from public.app_settings where key = 'legal_texts';

  update public.payments
     set waiver_accepted    = true,
         waiver_accepted_at = now(),
         waiver_text_version = coalesce(v_version, 'inconnue'),
         updated_at         = now()
   where id = p_payment_id
     and account_id = v_user_id
     and status in ('pending', 'processing')
  returning * into v_payment;

  if not found then raise exception 'Paiement introuvable ou deja finalise.'; end if;
  return v_payment;
end;
$function$;

revoke all on function public.secoto_prepare_commission_payment(uuid, uuid) from public, anon;
revoke all on function public.secoto_accept_payment_waiver(uuid) from public, anon;
grant execute on function public.secoto_prepare_commission_payment(uuid, uuid) to authenticated;
grant execute on function public.secoto_accept_payment_waiver(uuid) to authenticated;

-- ----------------------------------------------------------------------------
-- 8.1 VERROU CENTRAL : le bon de mission ne part qu'après encaissement
-- ----------------------------------------------------------------------------

create or replace function public.secoto_release_mission_order(p_mission uuid)
returns text
language plpgsql
volatile
security definer
set search_path = public
as $function$
declare
  v_bon uuid;
begin
  select d.id into v_bon
    from public.documents d
   where d.mission_id = p_mission
     and d.doc_type = 'bon_de_mission'
     and d.statut::text = 'brouillon'
   limit 1;

  if v_bon is null then
    return 'Aucun bon de mission en attente.';
  end if;

  perform public.secoto_release_document(v_bon);
  return 'Bon de mission transmis au transporteur.';
end;
$function$;

-- Réservée au serveur : le webhook Stripe est le seul déclencheur légitime.
create or replace function public.secoto_settle_payment(
  p_payment_id uuid,
  p_provider_intent_id text,
  p_status text,
  p_provider_event_id text,
  p_error text
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $function$
declare
  v_payment public.payments%rowtype;
  v_mission public.missions%rowtype;
  v_released text := '';
begin
  if p_status not in ('processing', 'paid', 'failed', 'refunded', 'cancelled') then
    raise exception 'Statut de paiement non autorise.';
  end if;

  select * into v_payment from public.payments p where p.id = p_payment_id for update;
  if not found then raise exception 'Paiement introuvable.'; end if;

  -- Idempotence stricte : un événement Stripe rejoué ne rejoue rien.
  if p_provider_event_id is not null
     and exists (
       select 1 from public.payment_events e
       where e.provider_event_id = p_provider_event_id
     ) then
    return jsonb_build_object('skipped', true, 'reason', 'event_already_processed');
  end if;

  if v_payment.status = 'paid' and p_status = 'paid' then
    return jsonb_build_object('skipped', true, 'reason', 'already_paid');
  end if;

  update public.payments
     set status             = p_status,
         provider_intent_id = coalesce(p_provider_intent_id, provider_intent_id),
         paid_at            = case when p_status = 'paid' then now() else paid_at end,
         failed_at          = case when p_status = 'failed' then now() else failed_at end,
         last_error         = case when p_status = 'failed' then left(coalesce(p_error, ''), 500) else last_error end,
         refunded_amount_cents = case when p_status = 'refunded' then amount_cents else refunded_amount_cents end,
         updated_at         = now()
   where id = p_payment_id
  returning * into v_payment;

  insert into public.payment_events(payment_id, event_type, provider_event_id, payload)
  values (
    p_payment_id, p_status, p_provider_event_id,
    jsonb_build_object('intent', p_provider_intent_id, 'error', p_error)
  )
  on conflict (provider_event_id) where provider_event_id is not null do nothing;

  select * into v_mission from public.missions m where m.id = v_payment.mission_id;

  if p_status = 'paid' then
    update public.missions
       set payment_status = 'paid',
           commission_paid_at = case
             when v_payment.purpose = 'commission_plateau' then now()
             else commission_paid_at end
     where id = v_payment.mission_id;

    -- ⚑ LE VERROU. Jusqu'ici le bon partait dès la signature du devis.
    if v_payment.purpose = 'commission_plateau' then
      v_released := public.secoto_release_mission_order(v_payment.mission_id);
    end if;

    perform secoto_private.notify_admins(
      'payment', v_payment.mission_id, 'paiement',
      'payment:' || p_payment_id::text || ':paid'
    );
    perform secoto_private.notify_one(
      v_payment.account_id, 'payment', v_payment.mission_id, 'paiement',
      'payment:' || p_payment_id::text || ':paid:client'
    );
    perform secoto_private.queue_email(
      v_payment.account_id,
      'SECOTO — confirmation de votre reservation',
      'Votre reservation de creneau est confirmee.' || chr(10) || chr(10)
      || 'Frais de reservation SECOTO (20 %) : '
      || public.secoto_fmt_amount(v_payment.amount_cents / 100.0) || chr(10)
      || 'Prix du transport, regle directement au transporteur : '
      || public.secoto_fmt_amount(coalesce(v_mission.transport_amount, 0)) || chr(10) || chr(10)
      || (select value ->> 'commission_notice' from public.app_settings where key = 'legal_texts')
      || chr(10) || chr(10)
      || 'Vous avez demande expressement l''execution immediate de la prestation '
      || 'de mise en relation et renonce a votre droit de retractation de 14 jours.'
      || chr(10) || chr(10)
      || (select value ->> 'refund_policy' from public.app_settings where key = 'legal_texts'),
      v_payment.mission_id,
      'email:payment:' || p_payment_id::text || ':paid'
    );

  elsif p_status = 'failed' then
    update public.missions set payment_status = 'failed' where id = v_payment.mission_id;
    perform secoto_private.notify_admins(
      'payment_failed', v_payment.mission_id, 'paiement',
      'payment:' || p_payment_id::text || ':failed'
    );
    perform secoto_private.notify_one(
      v_payment.account_id, 'payment_failed', v_payment.mission_id, 'paiement',
      'payment:' || p_payment_id::text || ':failed:client'
    );
    perform secoto_private.queue_email(
      v_payment.account_id,
      'SECOTO — votre paiement n''a pas abouti',
      'Votre paiement n''a pas pu etre encaisse. Votre creneau n''est pas '
      || 'reserve tant que la commission n''est pas reglee. Vous pouvez '
      || 'reessayer depuis l''application SECOTO.',
      v_payment.mission_id,
      'email:payment:' || p_payment_id::text || ':failed'
    );

  elsif p_status = 'refunded' then
    update public.missions set payment_status = 'refunded' where id = v_payment.mission_id;
    perform secoto_private.notify_one(
      v_payment.account_id, 'payment', v_payment.mission_id, 'paiement',
      'payment:' || p_payment_id::text || ':refunded:client'
    );
  end if;

  return jsonb_build_object(
    'payment_id', p_payment_id,
    'status', p_status,
    'released', v_released
  );
end;
$function$;

revoke all on function public.secoto_settle_payment(uuid, text, text, text, text)
  from public, anon, authenticated;
grant execute on function public.secoto_settle_payment(uuid, text, text, text, text)
  to service_role;
revoke all on function public.secoto_release_mission_order(uuid) from public, anon, authenticated;
grant execute on function public.secoto_release_mission_order(uuid) to service_role;

-- ----------------------------------------------------------------------------
-- 8.2 Le trigger de signature n'ouvre plus la mission de lui-même (plateau)
-- ----------------------------------------------------------------------------

create or replace function public.secoto_trg_document_signed()
returns trigger
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_bon    uuid;
  v_signer text;
  v_type   text;
begin
  if new.statut::text <> 'signe' or old.statut::text = 'signe' then
    return new;
  end if;

  select a.full_name into v_signer from public.accounts a where a.id = new.recipient_id;
  select m.type::text into v_type from public.missions m where m.id = new.mission_id;

  if new.doc_type::text = 'devis' then
    if v_type = 'plateau' then
      -- INTERMEDIATION : le bon reste en brouillon. Il ne partira au
      -- transporteur qu'apres encaissement effectif de la commission
      -- (public.secoto_settle_payment). C'est le verrou central.
      update public.missions
         set payment_status = 'awaiting_payment'
       where id = new.mission_id
         and payment_status = 'not_required';

      perform public.secoto_notify_admins(
        'document',
        'Devis signe — paiement attendu',
        coalesce(v_signer, 'Le client') || ' a signe le devis ' || coalesce(new.numero, '')
          || '. Le bon de mission partira au transporteur des l''encaissement '
          || 'de la commission.',
        new.mission_id
      );
    else
      -- SOUS-TRAITANCE convoyage : aucun paiement a la reservation, le
      -- circuit documentaire continue immediatement.
      select d.id into v_bon
        from public.documents d
       where d.mission_id = new.mission_id
         and d.doc_type = 'bon_de_mission'
         and d.statut::text = 'brouillon'
       limit 1;

      if v_bon is not null then
        perform public.secoto_release_document(v_bon);
      end if;

      perform public.secoto_notify_admins(
        'document',
        'Devis signe',
        coalesce(v_signer, 'Le client') || ' a signe le devis ' || coalesce(new.numero, '')
          || '. Le bon de mission est parti au convoyeur.',
        new.mission_id
      );
    end if;

  elsif new.doc_type::text = 'bon_de_mission' then
    perform public.secoto_notify_admins(
      'document',
      'Bon de mission signe',
      coalesce(v_signer, 'Le transporteur') || ' a signe le bon de mission '
        || coalesce(new.numero, '') || '.',
      new.mission_id
    );

  elsif new.doc_type::text = 'facture' then
    perform public.secoto_notify_admins(
      'document',
      'Facture acceptee',
      coalesce(v_signer, 'Le client') || ' a valide la facture ' || coalesce(new.numero, '') || '.',
      new.mission_id
    );
  end if;

  return new;
end;
$function$;

drop trigger if exists trg_secoto_document_signed on public.documents;
create trigger trg_secoto_document_signed
  after update of statut on public.documents
  for each row execute function public.secoto_trg_document_signed();

-- ----------------------------------------------------------------------------
-- 8.3 Paiement du convoyage à la livraison (lien de paiement)
-- ----------------------------------------------------------------------------

create or replace function public.secoto_prepare_delivery_payment(
  p_mission_id uuid,
  p_idempotency_key uuid
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $function$
declare
  v_user_id uuid := secoto_private.assert_authenticated();
  v_existing jsonb;
  v_mission public.missions%rowtype;
  v_payment public.payments%rowtype;
begin
  v_existing := secoto_private.lock_operation('prepare_delivery_payment', p_idempotency_key);
  if v_existing is not null then return v_existing; end if;

  select * into v_mission from public.missions m where m.id = p_mission_id;
  if not found then raise exception 'Mission introuvable.'; end if;
  if v_mission.type::text <> 'convoyage' then
    raise exception 'Paiement a la livraison reserve au convoyage.';
  end if;

  -- Le convoyeur n'encaisse JAMAIS en direct : il ne fait que declencher le
  -- lien de paiement, dont le produit arrive integralement chez SECOTO.
  if not (
    secoto_private.is_admin(v_user_id)
    or v_mission.assigned_transporter_id = v_user_id
    or v_mission.client_account_id = v_user_id
  ) then
    raise exception 'Action non autorisee sur cette mission.';
  end if;
  if coalesce(v_mission.client_price, 0) <= 0 then
    raise exception 'Montant de la mission indisponible.';
  end if;
  if v_mission.client_account_id is null then
    raise exception 'Cette mission n''est reliee a aucun compte client.';
  end if;

  select * into v_payment from public.payments p
   where p.mission_id = p_mission_id
     and p.purpose = 'convoyage_livraison'
     and p.status in ('pending', 'processing', 'paid', 'refund_pending');

  if not found then
    insert into public.payments(
      mission_id, account_id, purpose, amount_cents, status, waiver_required
    )
    values (
      p_mission_id, v_mission.client_account_id, 'convoyage_livraison',
      (round(
        (v_mission.client_price + coalesce((
          select sum(f.montant) from public.frais f
          where f.mission_id = p_mission_id and f.statut::text = 'valide'
        ), 0)) * 100))::integer,
      'pending', false
    )
    returning * into v_payment;

    update public.missions set payment_status = 'awaiting_payment' where id = p_mission_id;
  end if;

  return secoto_private.finish_operation(
    'prepare_delivery_payment',
    p_idempotency_key,
    jsonb_build_object(
      'payment_id',   v_payment.id,
      'status',       v_payment.status,
      'amount_cents', v_payment.amount_cents
    )
  );
end;
$function$;

revoke all on function public.secoto_prepare_delivery_payment(uuid, uuid) from public, anon;
grant execute on function public.secoto_prepare_delivery_payment(uuid, uuid) to authenticated;

-- ============================================================================
-- 9. ANNULATION ET REMBOURSEMENT
-- ============================================================================

create or replace function public.secoto_cancel_mission(
  p_mission_id uuid,
  p_reason text,
  p_idempotency_key uuid
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $function$
declare
  v_user_id uuid := secoto_private.assert_authenticated();
  v_existing jsonb;
  v_mission public.missions%rowtype;
  v_payment public.payments%rowtype;
  v_is_client boolean;
  v_is_carrier boolean;
  v_policy jsonb;
  v_hours numeric;
  v_fee_pct numeric := 0;
  v_fee numeric := 0;
  v_refund boolean := false;
  -- secoto_private.safe_text attend un jsonb et une cle : ici le motif arrive
  -- en texte simple, on le borne donc directement.
  v_reason text := left(nullif(btrim(coalesce(p_reason, '')), ''), 500);
begin
  v_existing := secoto_private.lock_operation('cancel_mission', p_idempotency_key);
  if v_existing is not null then return v_existing; end if;

  select * into v_mission from public.missions m where m.id = p_mission_id for update;
  if not found then raise exception 'Mission introuvable.'; end if;
  if v_mission.cancelled_at is not null then
    raise exception 'Mission deja annulee.';
  end if;

  v_is_client  := v_mission.client_account_id = v_user_id;
  v_is_carrier := v_mission.assigned_transporter_id = v_user_id;
  if not (v_is_client or v_is_carrier or secoto_private.is_admin(v_user_id)) then
    raise exception 'Annulation non autorisee sur cette mission.';
  end if;

  select value into v_policy from public.app_settings where key = 'cancellation_policy';

  if v_mission.type::text = 'plateau' then
    -- Intermediation : commission non remboursable si le CLIENT annule,
    -- remboursement INTEGRAL si le TRANSPORTEUR se desiste. Aucun bareme,
    -- aucune penalite, aucune detention de fonds pour compte de tiers.
    v_refund := v_is_carrier;
    v_fee := 0;
  else
    -- Convoyage : SECOTO est prestataire, le prejudice lui est propre.
    if v_is_client then
      v_hours := extract(epoch from (coalesce(v_mission.mission_date::timestamptz, now()) - now())) / 3600.0;
      select max((entry ->> 'fee_pct')::numeric)
        into v_fee_pct
      from jsonb_array_elements(coalesce(v_policy -> 'convoyage', '[]'::jsonb)) as entry
      where v_hours <= (entry ->> 'hours_before')::numeric;
      v_fee_pct := coalesce(v_fee_pct, 0);
      v_fee := round(coalesce(v_mission.client_price, 0) * v_fee_pct / 100.0, 2);
    end if;
  end if;

  update public.missions
     set status = 'cancelled',
         cancelled_at = now(),
         cancelled_by = v_user_id,
         cancellation_reason = v_reason,
         cancellation_fee = v_fee
   where id = p_mission_id
  returning * into v_mission;

  if v_refund then
    update public.payments
       set status = 'refund_pending',
           refund_requested_at = now(),
           refund_reason = 'Desistement du transporteur',
           updated_at = now()
     where mission_id = p_mission_id
       and purpose = 'commission_plateau'
       and status = 'paid'
    returning * into v_payment;
  end if;

  perform secoto_private.notify_admins(
    'cancellation', p_mission_id, 'courses',
    'cancel:' || p_idempotency_key::text
  );
  if v_mission.client_account_id is not null and not v_is_client then
    perform secoto_private.notify_one(
      v_mission.client_account_id, 'cancellation', p_mission_id, 'courses',
      'cancel:' || p_idempotency_key::text || ':client'
    );
    perform secoto_private.queue_email(
      v_mission.client_account_id,
      'SECOTO — annulation de votre mission',
      'Votre mission ' || coalesce(v_mission.public_ref, '') || ' a ete annulee.'
      || case when v_refund
              then chr(10) || 'Le transporteur s''etant desiste, votre commission '
                   || 'de mise en relation vous est integralement remboursee.'
              else '' end,
      p_mission_id,
      'email:cancel:' || p_idempotency_key::text || ':client'
    );
  end if;
  if v_mission.assigned_transporter_id is not null and not v_is_carrier then
    perform secoto_private.notify_one(
      v_mission.assigned_transporter_id, 'cancellation', p_mission_id, 'assigned',
      'cancel:' || p_idempotency_key::text || ':carrier'
    );
  end if;

  return secoto_private.finish_operation(
    'cancel_mission',
    p_idempotency_key,
    jsonb_build_object(
      'mission_id', p_mission_id,
      'cancellation_fee', v_fee,
      'refund_requested', v_refund
    )
  );
end;
$function$;

revoke all on function public.secoto_cancel_mission(uuid, text, uuid) from public, anon;
grant execute on function public.secoto_cancel_mission(uuid, text, uuid) to authenticated;

-- ============================================================================
-- 10. NOTIFICATIONS MANQUANTES
-- ============================================================================

-- 10.1 Toute étape terrain remonte aussi à l'admin (départ, arrivée, livraison).
create or replace function public.secoto_emit_business_event(
  p_event_type text,
  p_mission_id uuid,
  p_idempotency_key uuid
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $function$
declare
  v_user_id uuid := secoto_private.assert_authenticated();
  v_existing jsonb;
  v_mission public.missions%rowtype;
begin
  v_existing := secoto_private.lock_operation('emit_business_event', p_idempotency_key);
  if v_existing is not null then return v_existing; end if;
  if p_event_type not in ('tracking', 'document', 'frais_status', 'delivered') then
    raise exception 'Evenement client non autorise.';
  end if;

  select * into v_mission from public.missions m where m.id = p_mission_id;
  if not found or not (
    secoto_private.is_admin(v_user_id)
    or v_mission.client_account_id = v_user_id
    or v_mission.assigned_transporter_id = v_user_id
  ) then
    raise exception 'Evenement non autorise pour cette mission.';
  end if;

  if v_mission.client_account_id is not null
     and v_mission.client_account_id <> v_user_id then
    perform secoto_private.notify_one(
      v_mission.client_account_id, p_event_type, p_mission_id,
      case when p_event_type = 'document' then 'documents'
           when p_event_type = 'frais_status' then 'frais'
           else 'courses' end,
      'business:' || p_idempotency_key::text || ':client'
    );
  end if;
  if v_mission.assigned_transporter_id is not null
     and v_mission.assigned_transporter_id <> v_user_id then
    perform secoto_private.notify_one(
      v_mission.assigned_transporter_id, p_event_type, p_mission_id,
      case when p_event_type = 'document' then 'documents'
           when p_event_type = 'frais_status' then 'frais'
           else 'assigned' end,
      'business:' || p_idempotency_key::text || ':transporter'
    );
  end if;

  -- AJOUT 009 : l'admin etait le grand absent de cette fonction.
  if not secoto_private.is_admin(v_user_id) then
    perform secoto_private.notify_admins(
      p_event_type, p_mission_id,
      case when p_event_type = 'document' then 'documents'
           when p_event_type = 'frais_status' then 'frais'
           else 'courses' end,
      'business:' || p_idempotency_key::text || ':admin'
    );
  end if;

  return secoto_private.finish_operation(
    'emit_business_event',
    p_idempotency_key,
    jsonb_build_object('accepted', true, 'mission_id', p_mission_id)
  );
end;
$function$;

-- 10.2 Nouvelle inscription -> alerte admin.
-- Trigger posé sur public.accounts (et non sur auth.users) : rejouable, sans
-- toucher au schéma auth ni à handle_new_user.
create or replace function secoto_private.trg_account_created_notify()
returns trigger
language plpgsql
volatile
security definer
set search_path = ''
as $function$
begin
  if new.role::text in ('transporter', 'client') then
    perform secoto_private.notify_admins(
      'new_account', null, 'transporters',
      'account:' || new.id::text || ':created'
    );
  end if;
  return new;
end;
$function$;

drop trigger if exists trg_secoto_account_created on public.accounts;
create trigger trg_secoto_account_created
  after insert on public.accounts
  for each row execute function secoto_private.trg_account_created_notify();

-- 10.3 Livraison effectuée -> admin + client (trigger fin de course existant).
create or replace function secoto_private.trg_mission_delivered_notify()
returns trigger
language plpgsql
volatile
security definer
set search_path = ''
as $function$
begin
  if coalesce(new.progress_status, '') in ('delivery_completed', 'completed')
     and coalesce(old.progress_status, '') is distinct from coalesce(new.progress_status, '') then
    perform secoto_private.notify_admins(
      'delivered', new.id, 'courses', 'delivered:' || new.id::text || ':admin'
    );
    if new.client_account_id is not null then
      perform secoto_private.notify_one(
        new.client_account_id, 'delivered', new.id, 'courses',
        'delivered:' || new.id::text || ':client'
      );
    end if;
  end if;
  return new;
end;
$function$;

drop trigger if exists trg_secoto_mission_delivered on public.missions;
create trigger trg_secoto_mission_delivered
  after update of progress_status on public.missions
  for each row execute function secoto_private.trg_mission_delivered_notify();

-- ============================================================================
-- 11. DOCUMENTS — SÉPARATION JURIDIQUE DES DEUX ACTIVITÉS
-- ============================================================================
-- Le devis affichait « Prestation de mise en relation » pour les DEUX types.
-- C'est faux pour le convoyage, où SECOTO est prestataire et non intermédiaire.

create or replace function public.secoto_render_document(
  p_mission uuid,
  p_kind    text,
  p_numero  text,
  p_ref_devis text default ''
)
returns text
language plpgsql
security definer
set search_path = public
as $function$
declare
  m            public.missions%rowtype;
  v_html       text;
  v_tpl        text;
  v_client     numeric;
  v_carrier    numeric;
  v_especes    boolean;
  v_reglement  text;
  v_client_type text := 'Professionnel';
  v_bank       jsonb;
  v_legal      jsonb;
  v_tr         record;
  v_distance   text;
  v_date_doc   text := to_char(now(), 'DD/MM/YYYY');
  v_livraison  text;
  v_detail     text;
  v_total      numeric;
  v_plateau    boolean;
begin
  select * into m from public.missions where id = p_mission;
  if m.id is null then raise exception 'Mission introuvable.'; end if;

  select html into v_tpl from public.doc_templates where kind = p_kind;
  if v_tpl is null then
    raise exception 'Maquette « % » absente : ouvrez l''espace administrateur de '
      'l''application une fois pour la synchroniser, puis reessayez.', p_kind;
  end if;

  select value into v_legal from public.app_settings where key = 'legal_texts';

  v_plateau  := m.type::text = 'plateau';
  v_client   := coalesce(m.client_price, 0);
  v_carrier  := coalesce(m.carrier_pay, 0);
  v_total    := case when v_plateau then coalesce(m.client_total_due, v_client) else v_client end;
  v_especes  := coalesce(m.payment_method, 'virement') = 'especes';
  v_reglement := case
    when v_plateau then 'Frais de reservation regles dans l''application SECOTO'
    when v_especes then 'Reglement a la livraison'
    else 'Reglement par virement bancaire'
  end;
  v_distance := public.secoto_fmt_distance(m.distance_km);
  v_livraison := public.secoto_fmt_date(coalesce(m.mission_date::timestamptz, now()));

  if m.client_account_id is not null then
    select case when a.client_type = 'particulier' then 'Particulier' else 'Professionnel' end
      into v_client_type
    from public.accounts a where a.id = m.client_account_id;
  end if;

  v_html := v_tpl;

  v_html := replace(v_html, '{{NUMERO_DOC}}',      public.secoto_esc(p_numero));
  v_html := replace(v_html, '{{DATE_DOC}}',        v_date_doc);
  v_html := replace(v_html, '{{VEHICULE}}',        public.secoto_esc(coalesce(nullif(m.vehicle, ''), 'Non renseigne')));
  v_html := replace(v_html, '{{ADRESSE_DEPART}}',  public.secoto_esc(coalesce(nullif(m.pickup_address, ''), m.from_city, '')));
  v_html := replace(v_html, '{{ADRESSE_ARRIVEE}}', public.secoto_esc(coalesce(nullif(m.delivery_address, ''), m.to_city, '')));
  v_html := replace(v_html, '{{DATE_ENLEVEMENT}}', public.secoto_fmt_date(m.mission_date::timestamptz));
  v_html := replace(v_html, '{{DATE_LIVRAISON}}',  v_livraison);
  v_html := replace(v_html, '{{DISTANCE}}',        v_distance);
  v_html := replace(v_html, '{{LIGNE_DISTANCE}}',  v_distance);

  if p_kind = 'bon_de_mission' then
    select a.full_name, a.city, a.phone into v_tr
    from public.accounts a where a.id = m.assigned_transporter_id;

    v_html := replace(v_html, '{{TRANSPORTEUR_NOM}}',     public.secoto_esc(coalesce(v_tr.full_name, m.assigned_transporter_name, 'Transporteur')));
    v_html := replace(v_html, '{{TRANSPORTEUR_ADRESSE}}', public.secoto_esc(coalesce(v_tr.city, '')));
    v_html := replace(v_html, '{{TRANSPORTEUR_SIRET}}',   '');
    v_html := replace(v_html, '{{TRANSPORTEUR_TEL}}',     public.secoto_esc(coalesce(v_tr.phone, '')));
    v_html := replace(v_html, '{{CONTACT_DEPART}}',       public.secoto_esc(coalesce(m.client_contact, '')));
    v_html := replace(v_html, '{{CONTACT_ARRIVEE}}',      public.secoto_esc(coalesce(m.client_phone, '')));
    v_html := replace(v_html, '{{LIGNE_TRAJET}}',         public.secoto_esc(coalesce(m.from_city, '') || ' > ' || coalesce(m.to_city, '')));
    v_html := replace(v_html, '{{LIGNE_VEHICULE}}',       public.secoto_esc(coalesce(nullif(m.vehicle, ''), 'Non renseigne')));
    v_html := replace(v_html, '{{LIGNE_MONTANT}}',        public.secoto_fmt_amount(v_carrier));
    v_html := replace(v_html, '{{TOTAL_TRANSPORTEUR}}',   public.secoto_fmt_amount(v_carrier));

    -- Garde-fou : ni la commission ni le total client ne doivent figurer ici.
    if v_client > 0 and v_client <> v_carrier
       and position(public.secoto_fmt_amount(v_client) in v_html) > 0 then
      raise exception 'Bon de mission : fuite du montant client detectee, generation annulee.';
    end if;

  else
    v_html := replace(v_html, '{{CLIENT_NOM}}',     public.secoto_esc(coalesce(nullif(m.client_name, ''), 'Client')));
    v_html := replace(v_html, '{{CLIENT_TYPE}}',    v_client_type);
    v_html := replace(v_html, '{{CLIENT_CONTACT}}', public.secoto_esc(coalesce(nullif(m.client_contact, ''), m.client_phone, '')));

    -- ⚑ Deux activites juridiquement distinctes, deux libelles distincts.
    v_detail := case
      when v_plateau then
        'Frais de reservation SECOTO (20 %) — mise en relation. '
        || 'Prix du transport regle directement au transporteur : '
        || public.secoto_fmt_amount(coalesce(m.transport_amount, 0)) || '.'
      else
        'Prestation de convoyage par conducteur (sous-traitance de transport '
        || 'routier de vehicule par la route).'
    end;

    v_html := replace(v_html, '{{LIGNE_DETAIL}}',  public.secoto_esc(v_detail));
    v_html := replace(v_html, '{{LIGNE_MONTANT}}', public.secoto_fmt_amount(v_client));
    v_html := replace(v_html, '{{TOTAL}}',         public.secoto_fmt_amount(v_total));

    if p_kind = 'devis' then
      v_html := replace(v_html, '{{CONTACT_SUR_PLACE}}', public.secoto_esc(coalesce(m.client_contact, '')));
      v_html := replace(v_html, '{{CONDITION_DATES}}',
        public.secoto_esc(
          v_reglement || '. '
          || case when v_plateau
                  then coalesce(v_legal ->> 'commission_notice', '') || ' '
                       || coalesce(v_legal ->> 'refund_policy', '')
                  else 'Droit de retractation de 14 jours applicable aux '
                       || 'particuliers jusqu''a l''execution de la mission. ' end
          || 'Dates indicatives, a confirmer selon disponibilite. '
          || 'TVA non applicable, article 293 B du CGI.'
        ));
    else
      select value into v_bank from public.app_settings where key = 'bank_details';
      v_html := replace(v_html, '{{DATE_ECHEANCE}}', v_date_doc);
      v_html := replace(v_html, '{{REF_DEVIS}}',     public.secoto_esc(coalesce(p_ref_devis, '')));
      v_html := replace(v_html, '{{TITULAIRE_COMPTE}}',
        case when v_plateau then 'Regle dans l''application SECOTO'
             when v_especes then 'Reglement a la livraison'
             else public.secoto_esc(coalesce(v_bank ->> 'titulaire', 'Nawfal Benchiha')) end);
      v_html := replace(v_html, '{{IBAN}}',
        case when v_plateau or v_especes then 'Non applicable'
             else public.secoto_esc(coalesce(v_bank ->> 'iban', '')) end);
      v_html := replace(v_html, '{{BIC}}',
        case when v_plateau or v_especes then 'Non applicable'
             else public.secoto_esc(coalesce(v_bank ->> 'bic', '')) end);
    end if;
  end if;

  if v_html ~ '\{\{[A-Z0-9_]+\}\}' then
    raise exception 'Document incomplet : jeton non resolu (%).',
      substring(v_html from '\{\{[A-Z0-9_]+\}\}');
  end if;

  return v_html;
end;
$function$;

-- ============================================================================
-- 12. COMPTEUR MICRO-BIC (plafond 77 700 €)
-- ============================================================================
-- Base retenue : les ENCAISSEMENTS reels (payments.status = 'paid'), car c'est
-- l'encaissement qui compte en micro-entreprise. En convoyage c'est le prix
-- client complet, en plateau uniquement la commission — jamais le prix du
-- transport, qui ne transite pas par SECOTO.

create or replace view public.secoto_revenue_ytd_v1
with (security_barrier = true, security_invoker = false)
as
select
  extract(year from p.paid_at)::integer            as annee,
  sum(p.amount_cents - p.refunded_amount_cents) / 100.0 as ca_encaisse,
  77700.00                                          as plafond_micro_bic,
  round(
    (sum(p.amount_cents - p.refunded_amount_cents) / 100.0) / 77700.00 * 100
  , 1)                                              as pct_plafond,
  ((sum(p.amount_cents - p.refunded_amount_cents) / 100.0) >= 77700.00 * 0.80)
                                                    as alerte_80_pct
from public.payments p
where p.status in ('paid', 'refunded')
  and p.paid_at is not null
  and public.secoto_is_admin()
group by 1;

grant select on table public.secoto_revenue_ytd_v1 to authenticated;

-- ============================================================================
-- 13. FONDATIONS DU MOTEUR DE GROUPAGE
-- ============================================================================
-- Aucune attribution automatique : grouper d'office ferait basculer SECOTO en
-- commissionnaire de transport. Le transporteur COCHE ce qu'il accepte.

create table if not exists public.groupages_suggeres (
  id               uuid primary key default gen_random_uuid(),
  mission_a_id     uuid not null references public.missions(id) on delete cascade,
  mission_b_id     uuid not null references public.missions(id) on delete cascade,
  detour_pct       numeric(6,2),
  capacity_total   numeric(5,2),
  window_start     date,
  window_end       date,
  kind             text not null default 'groupage',
  score            numeric(6,2) not null default 0,
  created_at       timestamptz not null default now(),
  constraint groupages_suggeres_pair_check check (mission_a_id < mission_b_id)
);

create unique index if not exists groupages_suggeres_pair_key
  on public.groupages_suggeres (mission_a_id, mission_b_id);
create index if not exists groupages_suggeres_window_idx
  on public.groupages_suggeres (window_start, window_end);

alter table public.groupages_suggeres enable row level security;

drop policy if exists groupages_read_authorized on public.groupages_suggeres;
create policy groupages_read_authorized on public.groupages_suggeres
  for select to authenticated
  using (
    public.secoto_is_admin()
    or public.secoto_current_transporter_matches_mission(mission_a_id)
    or public.secoto_current_transporter_matches_mission(mission_b_id)
  );

-- Scan des missions ouvertes sur 14 jours à chaque création de mission.
create or replace function secoto_private.scan_groupages(p_mission_id uuid)
returns integer
language plpgsql
volatile
security definer
set search_path = ''
as $function$
declare
  v_new public.missions%rowtype;
  v_other public.missions%rowtype;
  v_count integer := 0;
  v_a uuid;
  v_b uuid;
  v_kind text;
begin
  select * into v_new from public.missions m where m.id = p_mission_id;
  if not found or v_new.status::text not in ('published', 'pending') then
    return 0;
  end if;

  for v_other in
    select * from public.missions m
    where m.id <> p_mission_id
      and m.status::text in ('published', 'pending')
      and m.assigned_transporter_id is null
      and m.created_at > now() - interval '14 days'
      -- Fenetres de dates qui se recoupent.
      and coalesce(m.window_start, m.mission_date::date) <=
          coalesce(v_new.window_end, v_new.mission_date::date, current_date + 14)
      and coalesce(m.window_end, m.mission_date::date, current_date + 14) >=
          coalesce(v_new.window_start, v_new.mission_date::date, current_date)
    limit 200
  loop
    -- Chainage prioritaire : convoyage en sens inverse (suppression du retour
    -- a vide). Passe avant tout groupage plateau.
    if v_new.type::text = 'convoyage' and v_other.type::text = 'convoyage'
       and lower(coalesce(v_new.to_city, '')) = lower(coalesce(v_other.from_city, ''))
       and lower(coalesce(v_new.from_city, '')) = lower(coalesce(v_other.to_city, '')) then
      v_kind := 'chainage_retour';
    elsif v_new.type::text = 'plateau' and v_other.type::text = 'plateau'
       and (coalesce(v_new.capacity_units, 1) + coalesce(v_other.capacity_units, 1)) <= 3
       and lower(coalesce(v_new.from_city, '')) = lower(coalesce(v_other.from_city, ''))
       and lower(coalesce(v_new.to_city, '')) = lower(coalesce(v_other.to_city, '')) then
      v_kind := 'groupage';
    else
      continue;
    end if;

    v_a := least(p_mission_id, v_other.id);
    v_b := greatest(p_mission_id, v_other.id);

    insert into public.groupages_suggeres(
      mission_a_id, mission_b_id, detour_pct, capacity_total,
      window_start, window_end, kind, score
    )
    values (
      v_a, v_b, 0,
      coalesce(v_new.capacity_units, 1) + coalesce(v_other.capacity_units, 1),
      greatest(
        coalesce(v_new.window_start, v_new.mission_date::date, current_date),
        coalesce(v_other.window_start, v_other.mission_date::date, current_date)),
      least(
        coalesce(v_new.window_end, v_new.mission_date::date, current_date + 14),
        coalesce(v_other.window_end, v_other.mission_date::date, current_date + 14)),
      v_kind,
      case when v_kind = 'chainage_retour' then 100 else 50 end
    )
    on conflict (mission_a_id, mission_b_id) do nothing;

    v_count := v_count + 1;
  end loop;

  return v_count;
end;
$function$;

create or replace function secoto_private.trg_mission_scan_groupages()
returns trigger
language plpgsql
volatile
security definer
set search_path = ''
as $function$
begin
  perform secoto_private.scan_groupages(new.id);
  return new;
end;
$function$;

drop trigger if exists trg_secoto_mission_scan_groupages on public.missions;
create trigger trg_secoto_mission_scan_groupages
  after insert on public.missions
  for each row execute function secoto_private.trg_mission_scan_groupages();

-- ============================================================================
-- 14. VUES CLOISONNÉES — AJOUT DES NOUVELLES COLONNES
-- ============================================================================
-- Colonnes ajoutées en FIN de vue pour préserver l'ordre historique.

create or replace view public.secoto_missions_admin_v2
with (security_barrier = true, security_invoker = false)
as
select
  m.id, m.public_ref, m.type, m.status, m.progress_status,
  m.from_city, m.to_city, m.pickup_address, m.delivery_address,
  m.mission_date, m.vehicle, m.plate, m.distance_km, m.carrier_cost,
  m.client_price, m.carrier_pay, m.margin,
  m.client_name, m.client_contact, m.client_phone,
  m.price_mode, m.proposed_price, m.payment_method, m.notes,
  m.created_by_role, m.client_account_id, m.assigned_transporter_id,
  m.assigned_transporter_name, m.source_request_id, m.created_at,
  m.vehicle_category,
  m.surcharge_urgent, m.surcharge_weekend, m.surcharge_oversize_pct,
  m.commission_amount, m.transport_amount, m.client_total_due,
  m.payment_status, m.commission_paid_at,
  m.cancelled_at, m.cancellation_reason, m.cancellation_fee,
  m.capacity_units, m.window_start, m.window_end
from public.missions m
where public.secoto_is_admin();

create or replace view public.secoto_missions_client_v2
with (security_barrier = true, security_invoker = false)
as
select
  m.id, m.public_ref, m.type, m.status, m.progress_status,
  m.from_city, m.to_city, m.pickup_address, m.delivery_address,
  m.mission_date, m.vehicle, m.plate, m.distance_km,
  m.client_price,
  m.client_name, m.client_contact, m.client_phone,
  m.price_mode, m.proposed_price, m.payment_method, m.notes,
  m.created_by_role, m.client_account_id, m.assigned_transporter_id,
  m.assigned_transporter_name, m.source_request_id, m.created_at,
  m.vehicle_category,
  -- Le client voit ce qu'il doit : commission, prix du transport, total.
  m.commission_amount, m.transport_amount, m.client_total_due,
  m.payment_status, m.commission_paid_at,
  m.cancelled_at, m.cancellation_reason, m.cancellation_fee
from public.missions m
where m.client_account_id = auth.uid();

create or replace view public.secoto_missions_transporter_v2
with (security_barrier = true, security_invoker = false)
as
select
  m.id, m.public_ref, m.type, m.status, m.progress_status,
  m.from_city, m.to_city, m.pickup_address, m.delivery_address,
  m.mission_date, m.vehicle, m.plate, m.distance_km,
  m.carrier_cost, m.carrier_pay,
  m.client_name, m.client_contact, m.client_phone,
  m.payment_method, m.notes,
  m.assigned_transporter_id, m.assigned_transporter_name, m.created_at,
  m.vehicle_category,
  -- JAMAIS client_price, margin, commission_amount ni client_total_due ici.
  m.payment_status,
  m.cancelled_at, m.cancellation_reason,
  m.capacity_units, m.window_start, m.window_end
from public.missions m
where m.assigned_transporter_id = auth.uid();

create or replace view public.secoto_public_missions_v2
with (security_barrier = true, security_invoker = false)
as
select
  m.id, m.public_ref, m.type, m.status, m.progress_status,
  m.from_city, m.to_city, m.vehicle, m.distance_km, m.created_at,
  m.vehicle_category,
  m.capacity_units, m.window_start, m.window_end
from public.missions m
where public.secoto_current_transporter_matches_mission(m.id);

grant select on table public.secoto_missions_admin_v2       to authenticated;
grant select on table public.secoto_missions_client_v2      to authenticated;
grant select on table public.secoto_missions_transporter_v2 to authenticated;
grant select on table public.secoto_public_missions_v2      to authenticated;

-- ============================================================================
-- 15. CONTRÔLES DE NON-RÉGRESSION DU BARÈME
-- ============================================================================

do $bareme_checks$
declare
  v numeric;
begin
  -- 80 km -> plancher 115,00
  v := public.secoto_compute_client_price('convoyage', 80, null, false, false, 0);
  if v <> 115.00 then raise exception 'Bareme KO : 80 km -> % (attendu 115.00)', v; end if;

  -- 400 km -> 300x1,00 + 100x0,90 = 390,00
  v := public.secoto_compute_client_price('convoyage', 400, null, false, false, 0);
  if v <> 390.00 then raise exception 'Bareme KO : 400 km -> % (attendu 390.00)', v; end if;

  -- 935 km -> 300x1,00 + 300x0,90 + 335x0,88 = 864,80
  v := public.secoto_compute_client_price('convoyage', 935, null, false, false, 0);
  if v <> 864.80 then raise exception 'Bareme KO : 935 km -> % (attendu 864.80)', v; end if;

  -- Suppléments cumulables : 400 km, urgence + week-end = 390 x 1,30 x 1,20
  v := public.secoto_compute_client_price('convoyage', 400, null, true, true, 0);
  if v <> 608.40 then raise exception 'Suppléments KO : % (attendu 608.40)', v; end if;

  -- Plateau : SECOTO n'encaisse que la commission.
  v := public.secoto_compute_client_price('plateau', null, 500, false, false, 0);
  if v <> 100.00 then raise exception 'Commission KO : % (attendu 100.00)', v; end if;

  -- Rémunération convoyeur inchangée : 0,55 EUR/km.
  v := public.secoto_compute_carrier_pay('convoyage', 400, null);
  if v <> 220.00 then raise exception 'Remuneration convoyeur KO : % (attendu 220.00)', v; end if;

  raise notice 'Bareme SECOTO 009 : tous les controles passent.';
end
$bareme_checks$;

notify pgrst, 'reload schema';

commit;

-- ============================================================================
-- FIN DE LA MIGRATION 009
-- ============================================================================
