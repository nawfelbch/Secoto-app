-- ============================================================================
-- SECOTO — MIGRATION 031 : ABONNEMENT PROFESSIONNEL PERSONNALISÉ
-- Éligibilité · Historique importé (privé) · Propositions simulées au pire cas
-- · Abonnements récurrents Stripe · Quotas réservés atomiquement · Extensions
-- ----------------------------------------------------------------------------
-- Additive et rejouable. Requiert la migration 030. Flag : subscriptions.
-- Aucun forfait illimité : quantités et plafond kilométrique obligatoires.
-- ============================================================================

begin;

do $guard$
begin
  if to_regclass('public.transport_orders') is null then
    raise exception 'Migration 030 requise avant la 031.';
  end if;
end
$guard$;

insert into public.app_settings(key, value) values ('subscription_policy', jsonb_build_object(
  'min_worst_case_margin_pct', 10,
  'past_due_grace_days', 7,
  'history_max_rows', 5000,
  'history_months', 3
)) on conflict (key) do nothing;

create or replace function secoto_private.sub_policy_num(p_key text, p_default numeric)
returns numeric language sql stable security definer set search_path = ''
as $f$ select coalesce((select (s.value ->> p_key)::numeric from public.app_settings s where s.key = 'subscription_policy'), p_default); $f$;

-- ============================================================================
-- 1. DOSSIERS D'ÉLIGIBILITÉ
-- ============================================================================
create table if not exists public.eligibility_applications (
  id            uuid primary key default gen_random_uuid(),
  business_id   uuid not null references public.business_accounts(id) on delete cascade,
  submitted_by  uuid not null references public.accounts(id),
  status        text not null default 'draft' check (status in ('draft', 'submitted', 'under_review', 'needs_correction', 'proposal_sent', 'accepted', 'rejected', 'withdrawn')),
  questionnaire jsonb not null default '{}'::jsonb,
  review_note   text,
  reviewed_by   uuid references public.accounts(id),
  submitted_at  timestamptz,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);
create index if not exists eligibility_applications_business_idx on public.eligibility_applications(business_id, created_at desc);

create table if not exists public.eligibility_history_rows (
  id                    bigint generated always as identity primary key,
  application_id        uuid not null references public.eligibility_applications(id) on delete cascade,
  row_number            integer not null,
  trip_date             date,
  from_label            text,
  from_postcode         text,
  to_label              text,
  to_postcode           text,
  distance_km           numeric(8,1),
  vehicle               text,
  mode                  text,
  requested_delay_hours integer,
  amount_cents          integer,
  fees_cents            integer,
  receipt_ref           text,
  status                text not null check (status in ('valid', 'warning', 'error')),
  issues                text[] not null default '{}',
  unique (application_id, row_number)
);

create table if not exists public.eligibility_files (
  id             uuid primary key default gen_random_uuid(),
  application_id uuid not null references public.eligibility_applications(id) on delete cascade,
  kind           text not null check (kind in ('history', 'receipt')),
  storage_path   text not null unique,
  file_name      text not null,
  mime_type      text,
  size_bytes     bigint check (size_bytes between 1 and 15000000),
  uploaded_by    uuid not null references public.accounts(id),
  created_at     timestamptz not null default now()
);

alter table public.eligibility_applications enable row level security;
alter table public.eligibility_history_rows enable row level security;
alter table public.eligibility_files enable row level security;
revoke all on table public.eligibility_applications, public.eligibility_history_rows, public.eligibility_files from public, anon, authenticated;

-- Stockage privé : chemin <business_id>/<application_id>/<fichier>.
insert into storage.buckets(id, name, public, file_size_limit, allowed_mime_types)
values ('business-private', 'business-private', false, 15000000,
  array['text/csv', 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet', 'application/pdf', 'image/jpeg', 'image/png'])
on conflict (id) do nothing;

drop policy if exists secoto_business_private_read on storage.objects;
create policy secoto_business_private_read on storage.objects for select to authenticated
using (bucket_id = 'business-private' and (
  secoto_private.current_is_admin()
  or secoto_private.is_business_member(nullif((storage.foldername(name))[1], '')::uuid, auth.uid())));

drop policy if exists secoto_business_private_insert on storage.objects;
create policy secoto_business_private_insert on storage.objects for insert to authenticated
with check (bucket_id = 'business-private'
  and secoto_private.is_business_member(nullif((storage.foldername(name))[1], '')::uuid, auth.uid())
  and exists (select 1 from public.eligibility_applications ea
              where ea.id::text = (storage.foldername(name))[2]
                and ea.business_id::text = (storage.foldername(name))[1]
                and ea.status in ('draft', 'needs_correction')));

create or replace function secoto_private.assert_application_editable(p_application_id uuid)
returns public.eligibility_applications language plpgsql stable security definer set search_path = ''
as $f$
declare v public.eligibility_applications%rowtype;
begin
  select * into v from public.eligibility_applications a where a.id = p_application_id;
  if not found or not secoto_private.is_business_member(v.business_id, auth.uid()) then
    raise exception 'Dossier introuvable.' using errcode = 'P0002';
  end if;
  if v.status not in ('draft', 'needs_correction') then
    raise exception 'Dossier déjà transmis : il n''est plus modifiable.';
  end if;
  return v;
end;
$f$;

create or replace function public.secoto_eligibility_start(p_company_name text, p_siren text)
returns jsonb language plpgsql volatile security definer set search_path = ''
as $f$
declare
  v_user uuid := secoto_private.assert_authenticated();
  v_business jsonb;
  v_app public.eligibility_applications%rowtype;
begin
  if not secoto_private.flag('subscriptions') then raise exception 'L''étude d''éligibilité n''est pas encore ouverte.'; end if;
  if secoto_private.account_role(v_user) not in ('client', 'admin') then raise exception 'Réservé aux clients professionnels.'; end if;
  v_business := public.secoto_business_ensure(p_company_name, p_siren);
  select * into v_app from public.eligibility_applications a
   where a.business_id = (v_business ->> 'id')::uuid and a.status in ('draft', 'needs_correction', 'submitted', 'under_review')
   order by a.created_at desc limit 1;
  if not found then
    insert into public.eligibility_applications(business_id, submitted_by) values ((v_business ->> 'id')::uuid, v_user) returning * into v_app;
  end if;
  return jsonb_build_object('application', to_jsonb(v_app), 'business', v_business);
end;
$f$;

create or replace function public.secoto_eligibility_save_questionnaire(p_application_id uuid, p_answers jsonb)
returns jsonb language plpgsql volatile security definer set search_path = ''
as $f$
declare v public.eligibility_applications%rowtype; v_item text;
begin
  v := secoto_private.assert_application_editable(p_application_id);
  if coalesce((p_answers ->> 'trips_per_month')::int, -1) not between 1 and 2000 then raise exception 'Fréquence mensuelle invalide.'; end if;
  if jsonb_typeof(p_answers -> 'zones') <> 'array' or jsonb_array_length(p_answers -> 'zones') = 0 then raise exception 'Indiquez au moins une zone (département).'; end if;
  for v_item in select jsonb_array_elements_text(p_answers -> 'zones') loop
    if upper(v_item) !~ '^([0-9]{2}|2A|2B|97[1-6])$' then raise exception 'Zone invalide : %', v_item; end if;
  end loop;
  if coalesce((p_answers ->> 'typical_km')::numeric, -1) not between 1 and 3000 or coalesce((p_answers ->> 'max_km')::numeric, -1) not between 1 and 3000 then
    raise exception 'Distances invalides.';
  end if;
  if jsonb_typeof(p_answers -> 'vehicle_classes') <> 'array' or jsonb_array_length(p_answers -> 'vehicle_classes') = 0 then raise exception 'Indiquez les catégories de véhicules.'; end if;
  if jsonb_typeof(p_answers -> 'modes') <> 'array' or jsonb_array_length(p_answers -> 'modes') = 0 then raise exception 'Indiquez convoyage et/ou plateau.'; end if;
  if coalesce(p_answers ->> 'lead_time', '') not in ('24h', '48h', 'semaine', 'flexible') then raise exception 'Délai habituel invalide.'; end if;
  if length(coalesce(p_answers ->> 'constraints', '')) > 1000 or length(coalesce(p_answers ->> 'seasonality', '')) > 1000 then raise exception 'Réponse trop longue.'; end if;
  update public.eligibility_applications set questionnaire = p_answers, updated_at = now() where id = p_application_id returning * into v;
  return to_jsonb(v);
end;
$f$;

-- Remplace les lignes d'historique après contrôle SERVEUR. Le client a déjà lu
-- le fichier sans jamais évaluer formules ni macros : seules des valeurs
-- arrivent ici, et elles sont revalidées une par une.
create or replace function public.secoto_eligibility_replace_rows(p_application_id uuid, p_rows jsonb)
returns jsonb language plpgsql volatile security definer set search_path = ''
as $f$
declare
  v public.eligibility_applications%rowtype;
  r jsonb;
  v_i integer := 0;
  v_issues text[];
  v_date date; v_km numeric; v_amount integer; v_fees integer; v_delay integer;
  v_mode text; v_status text;
  v_max integer := secoto_private.sub_policy_num('history_max_rows', 5000)::int;
  v_months integer := secoto_private.sub_policy_num('history_months', 3)::int;
begin
  v := secoto_private.assert_application_editable(p_application_id);
  if jsonb_typeof(p_rows) <> 'array' then raise exception 'Format de lignes invalide.'; end if;
  if jsonb_array_length(p_rows) > v_max then raise exception 'Trop de lignes (% maximum).', v_max; end if;
  delete from public.eligibility_history_rows where application_id = p_application_id;

  for r in select value from jsonb_array_elements(p_rows) loop
    v_i := v_i + 1;
    v_issues := '{}';
    v_date := null; v_km := null; v_amount := null; v_fees := null; v_delay := null;
    begin v_date := (r ->> 'date')::date; exception when others then v_issues := array_append(v_issues, 'date_invalide'); end;
    if v_date is null and not ('date_invalide' = any(v_issues)) then v_issues := array_append(v_issues, 'date_manquante'); end if;
    if v_date > current_date then v_issues := array_append(v_issues, 'date_future'); end if;
    if v_date < current_date - make_interval(months => v_months + 1) then v_issues := array_append(v_issues, 'hors_periode'); end if;
    if length(btrim(coalesce(r ->> 'from', ''))) < 2 then v_issues := array_append(v_issues, 'depart_manquant'); end if;
    if length(btrim(coalesce(r ->> 'to', ''))) < 2 then v_issues := array_append(v_issues, 'destination_manquante'); end if;
    begin v_km := nullif(replace(r ->> 'distance_km', ',', '.'), '')::numeric; exception when others then v_issues := array_append(v_issues, 'distance_invalide'); end;
    if v_km is null and not ('distance_invalide' = any(v_issues)) then v_issues := array_append(v_issues, 'distance_manquante'); end if;
    if v_km is not null and (v_km <= 0 or v_km > 3000) then v_issues := array_append(v_issues, 'distance_hors_limites'); v_km := null; end if;
    if length(btrim(coalesce(r ->> 'vehicle', ''))) < 2 then v_issues := array_append(v_issues, 'vehicule_manquant'); end if;
    v_mode := lower(btrim(coalesce(r ->> 'mode', '')));
    if v_mode not in ('convoyage', 'plateau') then v_issues := array_append(v_issues, 'mode_invalide'); v_mode := null; end if;
    begin v_delay := nullif(r ->> 'requested_delay_hours', '')::numeric::int; exception when others then v_issues := array_append(v_issues, 'delai_invalide'); end;
    begin v_amount := round(nullif(replace(r ->> 'amount_eur', ',', '.'), '')::numeric * 100)::int; exception when others then v_issues := array_append(v_issues, 'montant_invalide'); end;
    if v_amount is null and not ('montant_invalide' = any(v_issues)) then v_issues := array_append(v_issues, 'montant_manquant'); end if;
    if v_amount is not null and (v_amount <= 0 or v_amount > 5000000) then v_issues := array_append(v_issues, 'montant_hors_limites'); v_amount := null; end if;
    begin v_fees := round(nullif(replace(r ->> 'fees_eur', ',', '.'), '')::numeric * 100)::int; exception when others then v_issues := array_append(v_issues, 'frais_invalides'); end;
    if v_fees is not null and v_fees < 0 then v_issues := array_append(v_issues, 'frais_invalides'); v_fees := null; end if;
    if v_km is not null and v_amount is not null and (v_amount / 100.0 / v_km < 0.2 or v_amount / 100.0 / v_km > 15) then
      v_issues := array_append(v_issues, 'prix_au_km_incoherent');
    end if;
    v_status := case
      when exists (select 1 from unnest(v_issues) i where i in ('date_invalide', 'date_manquante', 'date_future', 'depart_manquant', 'destination_manquante',
        'distance_invalide', 'distance_manquante', 'distance_hors_limites', 'vehicule_manquant', 'mode_invalide', 'montant_invalide', 'montant_manquant', 'montant_hors_limites')) then 'error'
      when cardinality(v_issues) > 0 then 'warning' else 'valid' end;
    insert into public.eligibility_history_rows(application_id, row_number, trip_date, from_label, from_postcode, to_label, to_postcode,
      distance_km, vehicle, mode, requested_delay_hours, amount_cents, fees_cents, receipt_ref, status, issues)
    values (p_application_id, v_i, v_date, left(btrim(r ->> 'from'), 200), substring(r ->> 'from' from '[0-9]{5}'),
      left(btrim(r ->> 'to'), 200), substring(r ->> 'to' from '[0-9]{5}'),
      v_km, left(btrim(r ->> 'vehicle'), 120), v_mode, v_delay, v_amount, v_fees, left(btrim(r ->> 'receipt_ref'), 120), v_status, v_issues);
  end loop;

  -- Doublons probables (même date, trajet, véhicule et montant).
  update public.eligibility_history_rows h set
    issues = h.issues || 'doublon_probable'::text,
    status = case when h.status = 'valid' then 'warning' else h.status end
  where h.application_id = p_application_id and exists (
    select 1 from public.eligibility_history_rows d
    where d.application_id = h.application_id and d.row_number < h.row_number
      and d.trip_date = h.trip_date and lower(d.from_label) = lower(h.from_label) and lower(d.to_label) = lower(h.to_label)
      and lower(d.vehicle) = lower(h.vehicle) and d.amount_cents is not distinct from h.amount_cents);

  update public.eligibility_applications set updated_at = now() where id = p_application_id;
  return public.secoto_eligibility_rows(p_application_id);
end;
$f$;

create or replace function public.secoto_eligibility_rows(p_application_id uuid)
returns jsonb language plpgsql stable security definer set search_path = ''
as $f$
declare v public.eligibility_applications%rowtype;
begin
  select * into v from public.eligibility_applications a where a.id = p_application_id;
  if not found or not (secoto_private.is_admin(auth.uid()) or secoto_private.is_business_member(v.business_id, auth.uid())) then
    raise exception 'Dossier introuvable.' using errcode = 'P0002';
  end if;
  return jsonb_build_object(
    'counts', (select jsonb_build_object('total', count(*), 'valid', count(*) filter (where status = 'valid'),
                 'warning', count(*) filter (where status = 'warning'), 'error', count(*) filter (where status = 'error'))
               from public.eligibility_history_rows h where h.application_id = p_application_id),
    'rows', coalesce((select jsonb_agg(to_jsonb(h) - 'application_id' order by h.row_number)
               from public.eligibility_history_rows h where h.application_id = p_application_id), '[]'::jsonb));
end;
$f$;

create or replace function public.secoto_eligibility_register_file(p_application_id uuid, p_kind text, p_path text, p_file_name text, p_mime text, p_size bigint)
returns jsonb language plpgsql volatile security definer set search_path = ''
as $f$
declare v public.eligibility_applications%rowtype; v_file public.eligibility_files%rowtype;
begin
  v := secoto_private.assert_application_editable(p_application_id);
  if p_path not like v.business_id::text || '/' || v.id::text || '/%' then raise exception 'Chemin de fichier invalide.'; end if;
  if not exists (select 1 from storage.objects o where o.bucket_id = 'business-private' and o.name = p_path) then
    raise exception 'Fichier non trouvé dans le stockage privé.';
  end if;
  insert into public.eligibility_files(application_id, kind, storage_path, file_name, mime_type, size_bytes, uploaded_by)
  values (p_application_id, p_kind, p_path, left(p_file_name, 200), p_mime, p_size, auth.uid())
  on conflict (storage_path) do update set file_name = excluded.file_name
  returning * into v_file;
  return to_jsonb(v_file);
end;
$f$;

create or replace function public.secoto_eligibility_submit(p_application_id uuid)
returns jsonb language plpgsql volatile security definer set search_path = ''
as $f$
declare v public.eligibility_applications%rowtype;
begin
  v := secoto_private.assert_application_editable(p_application_id);
  if v.questionnaire = '{}'::jsonb then raise exception 'Complétez le questionnaire.'; end if;
  if not exists (select 1 from public.eligibility_history_rows h where h.application_id = p_application_id) then
    raise exception 'Importez l''historique de vos transports des trois derniers mois.';
  end if;
  if exists (select 1 from public.eligibility_history_rows h where h.application_id = p_application_id and h.status = 'error') then
    raise exception 'Corrigez les lignes en erreur avant de transmettre le dossier.';
  end if;
  update public.eligibility_applications set status = 'submitted', submitted_at = now(), updated_at = now()
   where id = p_application_id returning * into v;
  perform secoto_private.notify_admins_event('subscription', 'Dossier d''éligibilité reçu',
    (select b.name from public.business_accounts b where b.id = v.business_id), 'abonnement', 'eligibility-submitted:' || v.id::text, v.id);
  return to_jsonb(v);
end;
$f$;

-- ============================================================================
-- 2. PROPOSITIONS, ABONNEMENTS, RÉSERVATIONS
-- ============================================================================
create table if not exists public.subscription_proposals (
  id                   uuid primary key default gen_random_uuid(),
  application_id       uuid references public.eligibility_applications(id),
  business_id          uuid not null references public.business_accounts(id),
  version              integer not null default 1,
  status               text not null default 'draft' check (status in ('draft', 'sent', 'accepted', 'declined', 'expired', 'superseded')),
  monthly_price_cents  integer not null check (monthly_price_cents > 0),
  allowances           jsonb not null,
  km_cap_total         integer not null check (km_cap_total > 0),
  max_km_per_trip      integer not null check (max_km_per_trip > 0),
  zones                text[] not null check (cardinality(zones) > 0),
  modes                text[] not null check (cardinality(modes) > 0),
  lead_time_hours      integer not null check (lead_time_hours >= 0),
  cancellation_notice_hours integer not null check (cancellation_notice_hours >= 0),
  included_fees        text not null,
  exclusions           text not null,
  carry_over_rule      text not null,
  cancellation_rule    text not null,
  termination_rule     text not null,
  effective_date       date not null,
  valid_until          date not null,
  worst_case           jsonb not null default '{}'::jsonb,
  created_by           uuid references public.accounts(id),
  sent_at              timestamptz,
  decided_at           timestamptz,
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now()
);

create table if not exists public.subscriptions (
  id                     uuid primary key default gen_random_uuid(),
  business_id            uuid not null references public.business_accounts(id),
  proposal_id            uuid not null references public.subscription_proposals(id),
  pending_proposal_id    uuid references public.subscription_proposals(id),
  status                 text not null default 'pending_payment' check (status in ('pending_payment', 'active', 'past_due', 'suspended', 'cancelled', 'expired')),
  stripe_subscription_id text unique,
  current_period_start   timestamptz,
  current_period_end     timestamptz,
  grace_until            timestamptz,
  cancel_at_period_end   boolean not null default false,
  created_at             timestamptz not null default now(),
  updated_at             timestamptz not null default now()
);
create unique index if not exists subscriptions_one_live_per_business on public.subscriptions(business_id)
  where status in ('pending_payment', 'active', 'past_due', 'suspended');

create table if not exists public.subscription_billing_events (
  provider_event_id text primary key,
  subscription_id   uuid references public.subscriptions(id),
  event_type        text not null,
  payload           jsonb,
  created_at        timestamptz not null default now()
);

create table if not exists public.subscription_reservations (
  id              uuid primary key default gen_random_uuid(),
  subscription_id uuid not null references public.subscriptions(id),
  order_id        uuid not null unique references public.transport_orders(id),
  mission_id      uuid references public.missions(id),
  proposal_id     uuid not null references public.subscription_proposals(id),
  category        text not null,
  distance_km     numeric(8,1) not null,
  period_start    timestamptz not null,
  period_end      timestamptz not null,
  status          text not null check (status in ('reserved', 'consumed', 'released')),
  release_reason  text,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);
create index if not exists subscription_reservations_period_idx on public.subscription_reservations(subscription_id, period_start, status);

create table if not exists public.subscription_extensions (
  id              uuid primary key default gen_random_uuid(),
  subscription_id uuid not null references public.subscriptions(id),
  category        text not null,
  quantity        integer check (quantity > 0),
  extra_km        integer not null default 0 check (extra_km >= 0),
  note            text,
  status          text not null default 'requested' check (status in ('requested', 'priced', 'accepted', 'active', 'declined', 'expired')),
  price_cents     integer check (price_cents > 0),
  offer_valid_until timestamptz,
  period_start    timestamptz,
  period_end      timestamptz,
  payment_id      uuid references public.payments(id),
  requested_by    uuid references public.accounts(id),
  priced_by       uuid references public.accounts(id),
  accepted_at     timestamptz,
  created_at      timestamptz not null default now()
);

alter table public.subscription_proposals enable row level security;
alter table public.subscriptions enable row level security;
alter table public.subscription_billing_events enable row level security;
alter table public.subscription_reservations enable row level security;
alter table public.subscription_extensions enable row level security;
revoke all on table public.subscription_proposals, public.subscriptions, public.subscription_billing_events,
  public.subscription_reservations, public.subscription_extensions from public, anon, authenticated;

alter table public.payments add column if not exists subscription_extension_id uuid references public.subscription_extensions(id);

-- Pire cas : quantités maximales, distance maximale par trajet, kilomètres
-- attribués d'abord aux catégories les plus chères, dans la limite du plafond.
-- La rentabilité ne suppose AUCUN crédit inutilisé.
create or replace function secoto_private.sub_worst_case(p_monthly_price_cents integer, p_allowances jsonb, p_km_cap integer, p_max_km integer)
returns jsonb language plpgsql immutable set search_path = ''
as $f$
declare
  a jsonb;
  v_fixed numeric := 0;
  v_km_left numeric := p_km_cap;
  v_cost numeric;
  v_km numeric;
  v_detail jsonb := '[]'::jsonb;
  v_monthly numeric := p_monthly_price_cents / 100.0;
  v_total_trips integer := 0;
begin
  if jsonb_typeof(p_allowances) <> 'array' or jsonb_array_length(p_allowances) = 0 then
    raise exception 'Au moins une catégorie avec une quantité est requise (aucun forfait illimité).';
  end if;
  for a in select value from jsonb_array_elements(p_allowances) loop
    if coalesce(a ->> 'category', '') !~ '^(convoyage|plateau):(voiture|utilitaire|moto|autre)$' then
      raise exception 'Catégorie invalide : %', a ->> 'category';
    end if;
    if coalesce((a ->> 'quantity')::int, 0) not between 1 and 500 then raise exception 'Quantité invalide pour %.', a ->> 'category'; end if;
    if (a ->> 'partner_cost_per_km_eur') is null or (a ->> 'partner_cost_per_km_eur')::numeric < 0 then
      raise exception 'Coût partenaire au km requis pour % (hypothèse de simulation).', a ->> 'category';
    end if;
    v_fixed := v_fixed + (a ->> 'quantity')::int * (coalesce((a ->> 'fixed_cost_per_trip_eur')::numeric, 0) + coalesce((a ->> 'fees_per_trip_eur')::numeric, 0));
    v_total_trips := v_total_trips + (a ->> 'quantity')::int;
  end loop;
  v_cost := v_fixed;
  for a in select value from jsonb_array_elements(p_allowances) order by (value ->> 'partner_cost_per_km_eur')::numeric desc loop
    v_km := least(v_km_left, (a ->> 'quantity')::int * p_max_km);
    v_cost := v_cost + v_km * (a ->> 'partner_cost_per_km_eur')::numeric;
    v_km_left := v_km_left - v_km;
    v_detail := v_detail || jsonb_build_object('category', a ->> 'category', 'trips', (a ->> 'quantity')::int, 'km', v_km,
      'cost_eur', round(v_km * (a ->> 'partner_cost_per_km_eur')::numeric
        + (a ->> 'quantity')::int * (coalesce((a ->> 'fixed_cost_per_trip_eur')::numeric, 0) + coalesce((a ->> 'fees_per_trip_eur')::numeric, 0)), 2));
  end loop;
  return jsonb_build_object(
    'monthly_price_eur', v_monthly,
    'worst_case_cost_eur', round(v_cost, 2),
    'worst_case_margin_eur', round(v_monthly - v_cost, 2),
    'worst_case_margin_pct', case when v_monthly > 0 then round((v_monthly - v_cost) / v_monthly * 100, 1) end,
    'km_used', p_km_cap - v_km_left, 'trips', v_total_trips, 'detail', v_detail);
end;
$f$;

create or replace function public.secoto_admin_eligibility_list()
returns jsonb language plpgsql stable security definer set search_path = ''
as $f$
begin
  perform secoto_private.assert_admin();
  return coalesce((select jsonb_agg(to_jsonb(a) || jsonb_build_object(
      'business_name', b.name, 'siren', b.siren,
      'rows', (select count(*) from public.eligibility_history_rows h where h.application_id = a.id),
      'files', (select count(*) from public.eligibility_files f where f.application_id = a.id))
    order by a.submitted_at desc nulls last)
    from public.eligibility_applications a join public.business_accounts b on b.id = a.business_id
    where a.status <> 'draft'), '[]'::jsonb);
end;
$f$;

-- Répartition des trajets et des coûts, pour l'étude. Trois mois d'historique
-- éclairent la décision mais ne garantissent pas les besoins futurs.
create or replace function public.secoto_admin_eligibility_summary(p_application_id uuid)
returns jsonb language plpgsql stable security definer set search_path = ''
as $f$
begin
  perform secoto_private.assert_admin();
  return jsonb_build_object(
    'application', (select to_jsonb(a) from public.eligibility_applications a where a.id = p_application_id),
    'business', (select to_jsonb(b) from public.business_accounts b join public.eligibility_applications a on a.business_id = b.id where a.id = p_application_id),
    'files', coalesce((select jsonb_agg(to_jsonb(f)) from public.eligibility_files f where f.application_id = p_application_id), '[]'::jsonb),
    'totals', (select jsonb_build_object('trips', count(*), 'km', round(coalesce(sum(distance_km), 0)),
        'amount_eur', round(coalesce(sum(amount_cents), 0) / 100.0, 2), 'fees_eur', round(coalesce(sum(fees_cents), 0) / 100.0, 2),
        'avg_km', round(avg(distance_km), 1), 'max_km', max(distance_km),
        'avg_eur_per_km', round(sum(amount_cents) / 100.0 / nullif(sum(distance_km), 0), 2),
        'first_date', min(trip_date), 'last_date', max(trip_date), 'warnings', count(*) filter (where status = 'warning'))
      from public.eligibility_history_rows where application_id = p_application_id and status <> 'error'),
    'by_month', coalesce((select jsonb_agg(x order by x ->> 'month') from (
        select jsonb_build_object('month', to_char(trip_date, 'YYYY-MM'), 'trips', count(*), 'km', round(sum(distance_km)), 'amount_eur', round(sum(amount_cents) / 100.0, 2)) x
        from public.eligibility_history_rows where application_id = p_application_id and status <> 'error' group by to_char(trip_date, 'YYYY-MM')) s), '[]'::jsonb),
    'by_mode_vehicle', coalesce((select jsonb_agg(x) from (
        select jsonb_build_object('mode', mode, 'vehicle', lower(vehicle), 'trips', count(*), 'km', round(sum(distance_km)), 'amount_eur', round(sum(amount_cents) / 100.0, 2)) x
        from public.eligibility_history_rows where application_id = p_application_id and status <> 'error' group by mode, lower(vehicle) order by count(*) desc limit 30) s), '[]'::jsonb),
    'by_distance', coalesce((select jsonb_agg(jsonb_build_object('bucket', b.bucket, 'trips', b.trips, 'amount_eur', b.amount_eur) order by b.bucket) from (
        select case when distance_km <= 50 then '0-50' when distance_km <= 150 then '051-150'
          when distance_km <= 300 then '151-300' when distance_km <= 600 then '301-600' else '601+' end as bucket,
          count(*) as trips, round(sum(amount_cents) / 100.0, 2) as amount_eur
        from public.eligibility_history_rows where application_id = p_application_id and status <> 'error'
        group by 1) b), '[]'::jsonb),
    'top_routes', coalesce((select jsonb_agg(jsonb_build_object('from', t.dep_from, 'to', t.dep_to, 'trips', t.trips) order by t.trips desc) from (
        select substr(coalesce(from_postcode, '??'), 1, 2) as dep_from, substr(coalesce(to_postcode, '??'), 1, 2) as dep_to, count(*) as trips
        from public.eligibility_history_rows where application_id = p_application_id and status <> 'error'
        group by 1, 2 order by count(*) desc limit 10) t), '[]'::jsonb),
    'proposals', coalesce((select jsonb_agg(to_jsonb(p) order by p.version desc) from public.subscription_proposals p where p.application_id = p_application_id), '[]'::jsonb),
    'disclaimer', 'Historique de trois mois : indicateur, pas une garantie des besoins futurs.');
end;
$f$;

create or replace function public.secoto_admin_set_application_status(p_application_id uuid, p_status text, p_note text)
returns jsonb language plpgsql volatile security definer set search_path = ''
as $f$
declare v public.eligibility_applications%rowtype;
begin
  perform secoto_private.assert_admin();
  if p_status not in ('under_review', 'needs_correction', 'rejected') then raise exception 'Statut non autorisé.'; end if;
  update public.eligibility_applications set status = p_status, review_note = left(p_note, 2000), reviewed_by = auth.uid(), updated_at = now()
   where id = p_application_id returning * into v;
  if not found then raise exception 'Dossier introuvable.'; end if;
  perform secoto_private.audit('eligibility_status', 'eligibility_application', p_application_id::text, jsonb_build_object('status', p_status, 'note', p_note));
  perform secoto_private.notify_event(v.submitted_by, 'subscription',
    case p_status when 'under_review' then 'Dossier en cours d''étude' when 'needs_correction' then 'Dossier à compléter' else 'Dossier non retenu' end,
    coalesce(left(p_note, 300), 'Consultez votre espace abonnement.'), null, 'abonnement',
    'eligibility-status:' || p_application_id::text || ':' || p_status || ':' || extract(epoch from now())::bigint, p_application_id);
  return to_jsonb(v);
end;
$f$;

create or replace function public.secoto_admin_save_proposal(p_payload jsonb)
returns jsonb language plpgsql volatile security definer set search_path = ''
as $f$
declare
  v_app public.eligibility_applications%rowtype;
  v_row public.subscription_proposals%rowtype;
  v_worst jsonb;
  v_zone text;
  v_id uuid := nullif(p_payload ->> 'id', '')::uuid;
begin
  perform secoto_private.assert_admin();
  select * into v_app from public.eligibility_applications a where a.id = (p_payload ->> 'application_id')::uuid;
  if not found then raise exception 'Dossier introuvable.'; end if;
  for v_zone in select jsonb_array_elements_text(p_payload -> 'zones') loop
    if upper(v_zone) !~ '^([0-9]{2}|2A|2B|97[1-6])$' then raise exception 'Zone invalide : %', v_zone; end if;
  end loop;
  if exists (select 1 from jsonb_array_elements_text(p_payload -> 'modes') m where m not in ('convoyage', 'plateau')) then raise exception 'Mode invalide.'; end if;
  if (p_payload ->> 'valid_until')::date < current_date or (p_payload ->> 'effective_date')::date < current_date then raise exception 'Dates invalides.'; end if;
  foreach v_zone in array array['included_fees', 'exclusions', 'carry_over_rule', 'cancellation_rule', 'termination_rule'] loop
    if length(btrim(coalesce(p_payload ->> v_zone, ''))) < 5 then raise exception 'Champ contractuel requis : %', v_zone; end if;
  end loop;
  v_worst := secoto_private.sub_worst_case((p_payload ->> 'monthly_price_cents')::int, p_payload -> 'allowances',
    (p_payload ->> 'km_cap_total')::int, (p_payload ->> 'max_km_per_trip')::int);

  if v_id is not null then
    update public.subscription_proposals set
      monthly_price_cents = (p_payload ->> 'monthly_price_cents')::int, allowances = p_payload -> 'allowances',
      km_cap_total = (p_payload ->> 'km_cap_total')::int, max_km_per_trip = (p_payload ->> 'max_km_per_trip')::int,
      zones = array(select upper(jsonb_array_elements_text(p_payload -> 'zones'))),
      modes = array(select jsonb_array_elements_text(p_payload -> 'modes')),
      lead_time_hours = (p_payload ->> 'lead_time_hours')::int, cancellation_notice_hours = (p_payload ->> 'cancellation_notice_hours')::int,
      included_fees = p_payload ->> 'included_fees', exclusions = p_payload ->> 'exclusions',
      carry_over_rule = p_payload ->> 'carry_over_rule', cancellation_rule = p_payload ->> 'cancellation_rule',
      termination_rule = p_payload ->> 'termination_rule', effective_date = (p_payload ->> 'effective_date')::date,
      valid_until = (p_payload ->> 'valid_until')::date, worst_case = v_worst, updated_at = now()
    where id = v_id and status = 'draft' returning * into v_row;
    if not found then raise exception 'Seul un brouillon est modifiable.'; end if;
  else
    insert into public.subscription_proposals(application_id, business_id, version, monthly_price_cents, allowances, km_cap_total, max_km_per_trip,
      zones, modes, lead_time_hours, cancellation_notice_hours, included_fees, exclusions, carry_over_rule, cancellation_rule,
      termination_rule, effective_date, valid_until, worst_case, created_by)
    values (v_app.id, v_app.business_id,
      coalesce((select max(p.version) from public.subscription_proposals p where p.business_id = v_app.business_id), 0) + 1,
      (p_payload ->> 'monthly_price_cents')::int, p_payload -> 'allowances', (p_payload ->> 'km_cap_total')::int, (p_payload ->> 'max_km_per_trip')::int,
      array(select upper(jsonb_array_elements_text(p_payload -> 'zones'))), array(select jsonb_array_elements_text(p_payload -> 'modes')),
      (p_payload ->> 'lead_time_hours')::int, (p_payload ->> 'cancellation_notice_hours')::int,
      p_payload ->> 'included_fees', p_payload ->> 'exclusions', p_payload ->> 'carry_over_rule', p_payload ->> 'cancellation_rule',
      p_payload ->> 'termination_rule', (p_payload ->> 'effective_date')::date, (p_payload ->> 'valid_until')::date, v_worst, auth.uid())
    returning * into v_row;
  end if;
  perform secoto_private.audit('proposal_saved', 'subscription_proposal', v_row.id::text, jsonb_build_object('worst_case', v_worst));
  return to_jsonb(v_row);
end;
$f$;

create or replace function public.secoto_admin_send_proposal(p_proposal_id uuid)
returns jsonb language plpgsql volatile security definer set search_path = ''
as $f$
declare v public.subscription_proposals%rowtype; v_min numeric := secoto_private.sub_policy_num('min_worst_case_margin_pct', 10); v_submitter uuid;
begin
  perform secoto_private.assert_admin();
  select * into v from public.subscription_proposals p where p.id = p_proposal_id for update;
  if not found or v.status <> 'draft' then raise exception 'Proposition introuvable ou déjà envoyée.'; end if;
  v.worst_case := secoto_private.sub_worst_case(v.monthly_price_cents, v.allowances, v.km_cap_total, v.max_km_per_trip);
  if (v.worst_case ->> 'worst_case_margin_pct')::numeric < v_min then
    raise exception 'Envoi refusé : en utilisation complète la marge serait de % %% (minimum % %%).', v.worst_case ->> 'worst_case_margin_pct', v_min;
  end if;
  update public.subscription_proposals set status = 'superseded', updated_at = now()
   where business_id = v.business_id and status = 'sent' and id <> v.id;
  update public.subscription_proposals set status = 'sent', sent_at = now(), worst_case = v.worst_case, updated_at = now()
   where id = v.id returning * into v;
  update public.eligibility_applications set status = 'proposal_sent', updated_at = now() where id = v.application_id;
  select a.submitted_by into v_submitter from public.eligibility_applications a where a.id = v.application_id;
  perform secoto_private.audit('proposal_sent', 'subscription_proposal', v.id::text, v.worst_case);
  perform secoto_private.notify_event(v_submitter, 'subscription', 'Votre proposition personnalisée',
    format('Forfait étudié pour votre activité : %s € / mois. Valable jusqu''au %s.', to_char(v.monthly_price_cents / 100.0, 'FM999990D00'), to_char(v.valid_until, 'DD/MM/YYYY')),
    null, 'abonnement', 'proposal-sent:' || v.id::text, v.id);
  return to_jsonb(v);
end;
$f$;

-- Projection client d'une proposition (sans la simulation interne).
create or replace function secoto_private.proposal_client_json(p public.subscription_proposals)
returns jsonb language sql stable set search_path = ''
as $f$
  select (to_jsonb(p) - 'worst_case' - 'created_by') || jsonb_build_object('allowances',
    coalesce((select jsonb_agg(jsonb_build_object('category', a ->> 'category', 'quantity', (a ->> 'quantity')::int))
      from jsonb_array_elements(p.allowances) a), '[]'::jsonb));
$f$;

create or replace function public.secoto_sub_accept_proposal(p_proposal_id uuid)
returns jsonb language plpgsql volatile security definer set search_path = ''
as $f$
declare v public.subscription_proposals%rowtype; v_sub public.subscriptions%rowtype;
begin
  perform secoto_private.assert_authenticated();
  if not secoto_private.flag('subscriptions') then raise exception 'Les abonnements ne sont pas encore ouverts.'; end if;
  select * into v from public.subscription_proposals p where p.id = p_proposal_id for update;
  if not found or not exists (select 1 from public.business_members bm where bm.business_id = v.business_id and bm.account_id = auth.uid() and bm.role = 'owner') then
    raise exception 'Proposition introuvable.' using errcode = 'P0002';
  end if;
  if v.status <> 'sent' then raise exception 'Cette proposition n''est plus valable (%).', v.status; end if;
  if v.valid_until < current_date then
    update public.subscription_proposals set status = 'expired' where id = v.id;
    raise exception 'Cette proposition a expiré.';
  end if;
  select * into v_sub from public.subscriptions s where s.business_id = v.business_id and s.status in ('active', 'past_due', 'suspended') for update;
  if found then
    -- Changement de formule : effet au prochain renouvellement, jamais
    -- rétroactif sur les missions déjà réservées ou confirmées.
    update public.subscriptions set pending_proposal_id = v.id, updated_at = now() where id = v_sub.id returning * into v_sub;
  else
    insert into public.subscriptions(business_id, proposal_id) values (v.business_id, v.id)
    on conflict do nothing returning * into v_sub;
    if v_sub.id is null then
      select * into v_sub from public.subscriptions s where s.business_id = v.business_id and s.status = 'pending_payment';
      update public.subscriptions set proposal_id = v.id, updated_at = now() where id = v_sub.id returning * into v_sub;
    end if;
  end if;
  update public.subscription_proposals set status = 'accepted', decided_at = now(), updated_at = now() where id = v.id;
  update public.eligibility_applications set status = 'accepted', updated_at = now() where id = v.application_id;
  perform secoto_private.audit('proposal_accepted', 'subscription_proposal', v.id::text, jsonb_build_object('subscription_id', v_sub.id));
  return jsonb_build_object('subscription_id', v_sub.id, 'status', v_sub.status, 'change_scheduled', v_sub.pending_proposal_id is not null);
end;
$f$;

create or replace function public.secoto_sub_decline_proposal(p_proposal_id uuid)
returns jsonb language plpgsql volatile security definer set search_path = ''
as $f$
begin
  update public.subscription_proposals p set status = 'declined', decided_at = now(), updated_at = now()
   where p.id = p_proposal_id and p.status = 'sent' and secoto_private.is_business_member(p.business_id, auth.uid());
  return jsonb_build_object('result', case when found then 'declined' else 'no_change' end);
end;
$f$;

-- Utilisation de la période en cours, par catégorie.
create or replace function secoto_private.sub_usage(p_sub public.subscriptions)
returns jsonb language sql stable security definer set search_path = ''
as $f$
  with pr as (select * from public.subscription_proposals p where p.id = p_sub.proposal_id),
  cats as (
    select a ->> 'category' as category, (a ->> 'quantity')::int as quantity from pr, jsonb_array_elements(pr.allowances) a
  ),
  ext as (
    select e.category, sum(coalesce(e.quantity, 0)) as quantity, sum(e.extra_km) as km from public.subscription_extensions e
    where e.subscription_id = p_sub.id and e.status = 'active' and e.period_start = p_sub.current_period_start group by e.category
  ),
  use as (
    select r.category, count(*) filter (where r.status = 'reserved') as reserved, count(*) filter (where r.status = 'consumed') as consumed,
      coalesce(sum(r.distance_km) filter (where r.status = 'reserved'), 0) as km_reserved,
      coalesce(sum(r.distance_km) filter (where r.status = 'consumed'), 0) as km_consumed
    from public.subscription_reservations r where r.subscription_id = p_sub.id and r.period_start = p_sub.current_period_start group by r.category
  )
  select jsonb_build_object(
    'categories', coalesce((select jsonb_agg(jsonb_build_object('category', c.category,
        'included', c.quantity + coalesce(ext.quantity, 0),
        'reserved', coalesce(use.reserved, 0), 'consumed', coalesce(use.consumed, 0),
        'available', greatest(c.quantity + coalesce(ext.quantity, 0) - coalesce(use.reserved, 0) - coalesce(use.consumed, 0), 0)))
      from cats c left join ext on ext.category = c.category left join use on use.category = c.category), '[]'::jsonb),
    'km', jsonb_build_object('cap', (select km_cap_total from pr) + coalesce((select sum(km) from ext), 0),
      'reserved', (select coalesce(sum(km_reserved), 0) from use), 'consumed', (select coalesce(sum(km_consumed), 0) from use)));
$f$;

create or replace function public.secoto_sub_my_overview()
returns jsonb language plpgsql stable security definer set search_path = ''
as $f$
declare v_user uuid := secoto_private.assert_authenticated(); v_business uuid; v_sub public.subscriptions%rowtype;
begin
  select bm.business_id into v_business from public.business_members bm where bm.account_id = v_user order by bm.role = 'owner' desc, bm.created_at limit 1;
  if v_business is null then
    return jsonb_build_object('enabled', secoto_private.flag('subscriptions'), 'business', null);
  end if;
  select * into v_sub from public.subscriptions s where s.business_id = v_business order by s.created_at desc limit 1;
  return jsonb_build_object(
    'enabled', secoto_private.flag('subscriptions'),
    'business', (select jsonb_build_object('id', b.id, 'name', b.name, 'siren', b.siren) from public.business_accounts b where b.id = v_business),
    'application', (select to_jsonb(a) - 'reviewed_by' from public.eligibility_applications a where a.business_id = v_business order by a.created_at desc limit 1),
    'proposals', coalesce((select jsonb_agg(secoto_private.proposal_client_json(p) order by p.version desc) from public.subscription_proposals p
                            where p.business_id = v_business and p.status <> 'draft'), '[]'::jsonb),
    'subscription', case when v_sub.id is not null then to_jsonb(v_sub) - 'stripe_subscription_id' end,
    'plan', case when v_sub.id is not null then (select secoto_private.proposal_client_json(p) from public.subscription_proposals p where p.id = v_sub.proposal_id) end,
    'usage', case when v_sub.status in ('active', 'past_due', 'suspended') then secoto_private.sub_usage(v_sub) end,
    'extensions', coalesce((select jsonb_agg(to_jsonb(e) - 'priced_by' order by e.created_at desc) from public.subscription_extensions e where e.subscription_id = v_sub.id), '[]'::jsonb));
end;
$f$;

-- ----------------------------------------------------------------------------
-- 2.1 Réservation ATOMIQUE des droits (remplace l'amorce de la 030)
-- ----------------------------------------------------------------------------
create or replace function secoto_private.sub_reserve_for_order(p_order_id uuid)
returns void language plpgsql volatile security definer set search_path = ''
as $f$
declare
  v_order public.transport_orders%rowtype;
  v_quote public.transport_quotes%rowtype;
  v_sub public.subscriptions%rowtype;
  v_plan public.subscription_proposals%rowtype;
  v_category text;
  v_km numeric;
  v_included integer;
  v_used integer;
  v_km_used numeric;
  v_km_cap numeric;
  v_existing public.subscription_reservations%rowtype;
begin
  select * into v_order from public.transport_orders o where o.id = p_order_id;
  select * into v_existing from public.subscription_reservations r where r.order_id = p_order_id;
  if found and v_existing.status in ('reserved', 'consumed') then return; end if;
  select * into v_quote from public.transport_quotes q where q.id = v_order.quote_id;
  if v_order.business_id is null then raise exception 'Réservation sur forfait : sélectionnez votre société.'; end if;

  -- Verrou de l'abonnement : deux demandes simultanées sont sérialisées ici.
  select * into v_sub from public.subscriptions s where s.business_id = v_order.business_id and s.status in ('active', 'past_due', 'suspended') for update;
  if not found then raise exception 'Aucun abonnement actif pour cette société.'; end if;
  if v_sub.status <> 'active' then raise exception 'Abonnement % : nouvelles réservations suspendues jusqu''à régularisation.', v_sub.status; end if;
  if v_order.pickup_at >= v_sub.current_period_end or v_order.pickup_at < v_sub.current_period_start then
    raise exception 'La date de prise en charge doit se situer dans la période en cours (jusqu''au %).', to_char(v_sub.current_period_end at time zone 'Europe/Paris', 'DD/MM/YYYY');
  end if;
  select * into v_plan from public.subscription_proposals p where p.id = v_sub.proposal_id;
  v_category := v_order.mode || ':' || (v_quote.vehicle ->> 'class');
  v_km := coalesce((v_quote.route ->> 'distance_km')::numeric, 0);
  if v_km <= 0 then raise exception 'Distance indisponible : réservation sur forfait impossible.'; end if;
  if not (v_order.mode = any(v_plan.modes)) then raise exception 'Mode % non couvert par votre forfait.', v_order.mode; end if;
  if not (secoto_private.department_of(v_quote.pickup ->> 'postcode') = any(v_plan.zones))
     or not (secoto_private.department_of(v_quote.delivery ->> 'postcode') = any(v_plan.zones)) then
    raise exception 'Trajet hors des zones couvertes par votre forfait.';
  end if;
  if v_km > v_plan.max_km_per_trip then raise exception 'Trajet de % km : au-delà de la distance maximale par trajet (% km).', v_km, v_plan.max_km_per_trip; end if;
  if v_order.pickup_at < now() + make_interval(hours => v_plan.lead_time_hours) then
    raise exception 'Délai de prévenance du forfait : % h minimum.', v_plan.lead_time_hours;
  end if;

  select coalesce((select (a ->> 'quantity')::int from jsonb_array_elements(v_plan.allowances) a where a ->> 'category' = v_category), 0)
       + coalesce((select sum(e.quantity) from public.subscription_extensions e where e.subscription_id = v_sub.id and e.status = 'active'
                   and e.category = v_category and e.period_start = v_sub.current_period_start), 0)
    into v_included;
  if v_included = 0 then raise exception 'Catégorie % non incluse dans votre forfait.', v_category; end if;
  select count(*), coalesce(sum(r.distance_km), 0) into v_used, v_km_used from public.subscription_reservations r
   where r.subscription_id = v_sub.id and r.period_start = v_sub.current_period_start and r.status in ('reserved', 'consumed') and r.category = v_category;
  if v_used >= v_included then raise exception 'Droits épuisés pour % sur la période : demandez une extension de votre forfait.', v_category; end if;
  select coalesce(sum(r.distance_km), 0) into v_km_used from public.subscription_reservations r
   where r.subscription_id = v_sub.id and r.period_start = v_sub.current_period_start and r.status in ('reserved', 'consumed');
  v_km_cap := v_plan.km_cap_total + coalesce((select sum(e.extra_km) from public.subscription_extensions e where e.subscription_id = v_sub.id and e.status = 'active' and e.period_start = v_sub.current_period_start), 0);
  if v_km_used + v_km > v_km_cap then raise exception 'Plafond kilométrique atteint (% / % km) : demandez une extension de votre forfait.', v_km_used, v_km_cap; end if;

  insert into public.subscription_reservations(subscription_id, order_id, proposal_id, category, distance_km, period_start, period_end, status)
  values (v_sub.id, p_order_id, v_plan.id, v_category, v_km, v_sub.current_period_start, v_sub.current_period_end, 'reserved')
  on conflict (order_id) do update set status = 'reserved', release_reason = null, updated_at = now(),
    subscription_id = excluded.subscription_id, period_start = excluded.period_start, period_end = excluded.period_end;
end;
$f$;

create or replace function secoto_private.sub_release_for_order(p_order_id uuid, p_reason text)
returns void language sql volatile security definer set search_path = ''
as $f$
  update public.subscription_reservations set status = 'released', release_reason = left(p_reason, 200), updated_at = now()
   where order_id = p_order_id and status = 'reserved';
$f$;

create or replace function secoto_private.sub_consume_for_order(p_order_id uuid)
returns void language sql volatile security definer set search_path = ''
as $f$
  update public.subscription_reservations set status = 'consumed', updated_at = now()
   where order_id = p_order_id and status = 'reserved';
$f$;

create or replace function secoto_private.sub_attach_mission(p_order_id uuid, p_mission_id uuid)
returns void language sql volatile security definer set search_path = ''
as $f$ update public.subscription_reservations set mission_id = p_mission_id, updated_at = now() where order_id = p_order_id; $f$;

-- ----------------------------------------------------------------------------
-- 2.2 Facturation récurrente (webhook Stripe Billing)
-- ----------------------------------------------------------------------------
create or replace function public.secoto_sub_apply_billing_event(
  p_subscription_id uuid, p_event_id text, p_event_type text, p_stripe_subscription_id text,
  p_period_start timestamptz, p_period_end timestamptz
)
returns jsonb language plpgsql volatile security definer set search_path = ''
as $f$
declare v public.subscriptions%rowtype; v_owner uuid;
begin
  if exists (select 1 from public.subscription_billing_events e where e.provider_event_id = p_event_id) then
    return jsonb_build_object('skipped', true, 'reason', 'event_already_processed');
  end if;
  select * into v from public.subscriptions s where s.id = p_subscription_id or (p_stripe_subscription_id is not null and s.stripe_subscription_id = p_stripe_subscription_id) for update;
  if not found then return jsonb_build_object('skipped', true, 'reason', 'unknown_subscription'); end if;
  insert into public.subscription_billing_events(provider_event_id, subscription_id, event_type, payload)
  values (p_event_id, v.id, p_event_type, jsonb_build_object('period_start', p_period_start, 'period_end', p_period_end));
  select bm.account_id into v_owner from public.business_members bm where bm.business_id = v.business_id and bm.role = 'owner' limit 1;

  if p_event_type = 'checkout.session.completed' then
    update public.subscriptions set stripe_subscription_id = coalesce(stripe_subscription_id, p_stripe_subscription_id), updated_at = now() where id = v.id;
  elsif p_event_type = 'invoice.paid' then
    -- Ignore une facture plus ancienne que la période déjà connue (désordre).
    if v.current_period_end is null or p_period_end > v.current_period_end then
      update public.subscriptions set
        status = case when status in ('pending_payment', 'active', 'past_due', 'suspended') then 'active' else status end,
        stripe_subscription_id = coalesce(stripe_subscription_id, p_stripe_subscription_id),
        proposal_id = coalesce(pending_proposal_id, proposal_id),
        pending_proposal_id = null,
        current_period_start = p_period_start, current_period_end = p_period_end, grace_until = null, updated_at = now()
      where id = v.id;
      update public.subscription_extensions set status = 'expired' where subscription_id = v.id and status = 'active' and period_end <= p_period_start;
    elsif v.status in ('past_due', 'suspended') then
      update public.subscriptions set status = 'active', grace_until = null, updated_at = now() where id = v.id;
    end if;
    perform secoto_private.notify_event(v_owner, 'subscription', 'Abonnement actif',
      format('Période du %s au %s.', to_char(p_period_start at time zone 'Europe/Paris', 'DD/MM'), to_char(p_period_end at time zone 'Europe/Paris', 'DD/MM/YYYY')),
      null, 'abonnement', 'sub-paid:' || p_event_id, v.id);
  elsif p_event_type = 'invoice.payment_failed' then
    update public.subscriptions set status = case when status = 'active' then 'past_due' else status end,
      grace_until = coalesce(grace_until, now() + make_interval(days => secoto_private.sub_policy_num('past_due_grace_days', 7)::int)), updated_at = now()
     where id = v.id;
    perform secoto_private.notify_event(v_owner, 'payment_failed', 'Échec du prélèvement de l''abonnement',
      'Mettez à jour votre moyen de paiement : les nouvelles réservations sur forfait sont suspendues jusqu''à régularisation. Les missions déjà confirmées ne sont pas affectées.',
      null, 'abonnement', 'sub-failed:' || p_event_id, v.id);
  elsif p_event_type = 'customer.subscription.deleted' then
    update public.subscriptions set status = 'cancelled', updated_at = now() where id = v.id;
  end if;
  perform secoto_private.audit('subscription_billing_event', 'subscription', v.id::text, jsonb_build_object('type', p_event_type, 'event', p_event_id));
  return jsonb_build_object('subscription_id', v.id, 'status', (select s.status from public.subscriptions s where s.id = v.id));
end;
$f$;

create or replace function public.secoto_sub_maintenance_tick()
returns jsonb language plpgsql volatile security definer set search_path = ''
as $f$
declare v_suspended int; v_expired int;
begin
  update public.subscriptions set status = 'suspended', updated_at = now() where status = 'past_due' and grace_until <= now();
  get diagnostics v_suspended = row_count;
  update public.subscription_proposals set status = 'expired', updated_at = now() where status = 'sent' and valid_until < current_date;
  get diagnostics v_expired = row_count;
  update public.subscription_extensions set status = 'expired' where status = 'priced' and offer_valid_until <= now();
  return jsonb_build_object('suspended', v_suspended, 'expired_proposals', v_expired);
end;
$f$;

create or replace function public.secoto_sub_request_cancel(p_subscription_id uuid)
returns jsonb language plpgsql volatile security definer set search_path = ''
as $f$
declare v public.subscriptions%rowtype;
begin
  select * into v from public.subscriptions s where s.id = p_subscription_id for update;
  if not found or not exists (select 1 from public.business_members bm where bm.business_id = v.business_id and bm.account_id = auth.uid() and bm.role = 'owner') then
    raise exception 'Abonnement introuvable.' using errcode = 'P0002';
  end if;
  update public.subscriptions set cancel_at_period_end = true, updated_at = now() where id = v.id returning * into v;
  perform secoto_private.audit('subscription_cancel_requested', 'subscription', v.id::text, '{}'::jsonb);
  return jsonb_build_object('id', v.id, 'cancel_at_period_end', true, 'current_period_end', v.current_period_end,
    'stripe_subscription_id_present', v.stripe_subscription_id is not null);
end;
$f$;

-- ----------------------------------------------------------------------------
-- 2.3 Extensions : prix accepté AVANT tout engagement
-- ----------------------------------------------------------------------------
create or replace function public.secoto_sub_request_extension(p_subscription_id uuid, p_category text, p_quantity int, p_extra_km int, p_note text)
returns jsonb language plpgsql volatile security definer set search_path = ''
as $f$
declare v public.subscriptions%rowtype; v_ext public.subscription_extensions%rowtype;
begin
  select * into v from public.subscriptions s where s.id = p_subscription_id;
  if not found or not secoto_private.is_business_member(v.business_id, auth.uid()) then raise exception 'Abonnement introuvable.' using errcode = 'P0002'; end if;
  if v.status <> 'active' then raise exception 'Abonnement non actif.'; end if;
  if p_category !~ '^(convoyage|plateau):(voiture|utilitaire|moto|autre)$' then raise exception 'Catégorie invalide.'; end if;
  if coalesce(p_quantity, 0) not between 1 and 200 or coalesce(p_extra_km, 0) not between 0 and 50000 then raise exception 'Quantités invalides.'; end if;
  insert into public.subscription_extensions(subscription_id, category, quantity, extra_km, note, requested_by)
  values (v.id, p_category, p_quantity, coalesce(p_extra_km, 0), left(p_note, 1000), auth.uid()) returning * into v_ext;
  perform secoto_private.notify_admins_event('subscription', 'Demande d''extension de forfait', p_category || ' × ' || p_quantity, 'abonnement', 'ext-request:' || v_ext.id::text, v_ext.id);
  return to_jsonb(v_ext);
end;
$f$;

create or replace function public.secoto_admin_price_extension(p_extension_id uuid, p_price_cents int, p_valid_hours int)
returns jsonb language plpgsql volatile security definer set search_path = ''
as $f$
declare v public.subscription_extensions%rowtype;
begin
  perform secoto_private.assert_admin();
  if coalesce(p_price_cents, 0) <= 0 or coalesce(p_valid_hours, 0) not between 1 and 720 then raise exception 'Montant ou validité invalide.'; end if;
  update public.subscription_extensions set status = 'priced', price_cents = p_price_cents, offer_valid_until = now() + make_interval(hours => p_valid_hours), priced_by = auth.uid()
   where id = p_extension_id and status in ('requested', 'priced') returning * into v;
  if not found then raise exception 'Extension introuvable.'; end if;
  perform secoto_private.audit('extension_priced', 'subscription_extension', v.id::text, jsonb_build_object('price_cents', p_price_cents));
  perform secoto_private.notify_event(v.requested_by, 'subscription', 'Extension de forfait chiffrée',
    format('%s × %s : %s €. À accepter avant tout engagement.', v.category, v.quantity, to_char(p_price_cents / 100.0, 'FM999990D00')),
    null, 'abonnement', 'ext-priced:' || v.id::text || ':' || p_price_cents, v.id);
  return to_jsonb(v);
end;
$f$;

create or replace function public.secoto_sub_accept_extension(p_extension_id uuid)
returns jsonb language plpgsql volatile security definer set search_path = ''
as $f$
declare v public.subscription_extensions%rowtype; v_sub public.subscriptions%rowtype; v_payment public.payments%rowtype;
begin
  select * into v from public.subscription_extensions e where e.id = p_extension_id for update;
  select * into v_sub from public.subscriptions s where s.id = v.subscription_id;
  if not found or not secoto_private.is_business_member(v_sub.business_id, auth.uid()) then raise exception 'Extension introuvable.' using errcode = 'P0002'; end if;
  if v.status = 'accepted' then
    return jsonb_build_object('extension_id', v.id, 'payment_id', v.payment_id);
  end if;
  if v.status <> 'priced' or v.offer_valid_until <= now() then raise exception 'Cette offre d''extension n''est plus valable.'; end if;
  insert into public.payments(account_id, purpose, amount_cents, status, capture_method, subscription_extension_id)
  values (auth.uid(), 'subscription_extension', v.price_cents, 'pending', 'automatic', v.id) returning * into v_payment;
  update public.subscription_extensions set status = 'accepted', accepted_at = now(), payment_id = v_payment.id,
    period_start = v_sub.current_period_start, period_end = v_sub.current_period_end
   where id = v.id returning * into v;
  perform secoto_private.audit('extension_accepted', 'subscription_extension', v.id::text, jsonb_build_object('payment_id', v_payment.id));
  return jsonb_build_object('extension_id', v.id, 'payment_id', v_payment.id, 'amount_cents', v.price_cents);
end;
$f$;

-- Activation de l'extension quand son paiement est encaissé.
create or replace function secoto_private.trg_extension_payment()
returns trigger language plpgsql volatile security definer set search_path = ''
as $f$
begin
  if new.subscription_extension_id is not null and new.status = 'paid' and old.status is distinct from 'paid' then
    update public.subscription_extensions set status = 'active' where id = new.subscription_extension_id and status = 'accepted';
  end if;
  return new;
end;
$f$;
drop trigger if exists trg_secoto_extension_payment on public.payments;
create trigger trg_secoto_extension_payment after update of status on public.payments
  for each row execute function secoto_private.trg_extension_payment();

create or replace function public.secoto_admin_subscriptions()
returns jsonb language plpgsql stable security definer set search_path = ''
as $f$
begin
  perform secoto_private.assert_admin();
  return coalesce((select jsonb_agg(to_jsonb(s) || jsonb_build_object('business_name', b.name,
      'plan', (select to_jsonb(p) from public.subscription_proposals p where p.id = s.proposal_id),
      'usage', case when s.current_period_start is not null then secoto_private.sub_usage(s) end,
      'extensions', (select coalesce(jsonb_agg(to_jsonb(e)), '[]'::jsonb) from public.subscription_extensions e where e.subscription_id = s.id and e.status in ('requested', 'priced', 'accepted'))))
    from public.subscriptions s join public.business_accounts b on b.id = s.business_id), '[]'::jsonb);
end;
$f$;

-- ============================================================================
-- 3. DROITS
-- ============================================================================
revoke all on all functions in schema secoto_private from public, anon, authenticated;
do $grants$
declare
  v_fn text;
  v_auth constant text[] := array[
    'public.secoto_eligibility_start(text,text)',
    'public.secoto_eligibility_save_questionnaire(uuid,jsonb)',
    'public.secoto_eligibility_replace_rows(uuid,jsonb)',
    'public.secoto_eligibility_rows(uuid)',
    'public.secoto_eligibility_register_file(uuid,text,text,text,text,bigint)',
    'public.secoto_eligibility_submit(uuid)',
    'public.secoto_admin_eligibility_list()',
    'public.secoto_admin_eligibility_summary(uuid)',
    'public.secoto_admin_set_application_status(uuid,text,text)',
    'public.secoto_admin_save_proposal(jsonb)',
    'public.secoto_admin_send_proposal(uuid)',
    'public.secoto_sub_accept_proposal(uuid)',
    'public.secoto_sub_decline_proposal(uuid)',
    'public.secoto_sub_my_overview()',
    'public.secoto_sub_request_cancel(uuid)',
    'public.secoto_sub_request_extension(uuid,text,integer,integer,text)',
    'public.secoto_admin_price_extension(uuid,integer,integer)',
    'public.secoto_sub_accept_extension(uuid)',
    'public.secoto_admin_subscriptions()'
  ];
  v_service constant text[] := array[
    'public.secoto_sub_apply_billing_event(uuid,text,text,text,timestamptz,timestamptz)',
    'public.secoto_sub_maintenance_tick()'
  ];
begin
  foreach v_fn in array v_auth loop
    execute format('revoke all on function %s from public, anon', v_fn);
    execute format('grant execute on function %s to authenticated, service_role', v_fn);
  end loop;
  foreach v_fn in array v_service loop
    execute format('revoke all on function %s from public, anon, authenticated', v_fn);
    execute format('grant execute on function %s to service_role', v_fn);
  end loop;
end
$grants$;
grant select, update on public.subscriptions, public.subscription_proposals, public.subscription_extensions to service_role;
grant select on public.business_members, public.business_accounts to service_role;

notify pgrst, 'reload schema';
commit;
