-- ============================================================================
-- SECOTO — MIGRATION 030 : TRANSPORT À LA DEMANDE
-- Devis serveur versionnés · Commandes · Paiement préalable (autorisation puis
-- capture) · Offres partenaires et attribution atomique · Journal admin ·
-- Feature flags · Export comptable · Versements partenaires (suivi manuel)
-- ----------------------------------------------------------------------------
-- ADDITIVE ET REJOUABLE. Aucune ligne existante n'est supprimée ni modifiée,
-- à trois exceptions près, toutes rétro-compatibles :
--   • payments.mission_id devient NULLABLE (un paiement de commande existe
--     avant la mission). Les paiements historiques gardent leur mission.
--   • les contraintes CHECK payments_purpose_check / payments_status_check
--     sont élargies (sur-ensemble des valeurs existantes).
--   • secoto_private.prepare_notification accepte trois écrans de plus.
-- TOUS LES FLAGS SONT DÉSACTIVÉS À L'INSTALLATION : aucun comportement visible
-- ne change tant que l'administrateur ne les active pas.
-- Retour arrière : supabase/rollback/030-032_rollback.sql
-- ============================================================================

begin;

do $guard$
begin
  if to_regclass('public.payments') is null
     or to_regprocedure('secoto_private.lock_operation(text,uuid)') is null
     or to_regprocedure('secoto_private.transporter_matches_mission(uuid,uuid)') is null
     or to_regprocedure('public.secoto_trg_mission_amounts()') is null then
    raise exception 'Migrations 001 à 024 requises avant la 030.';
  end if;
end
$guard$;

-- ============================================================================
-- 1. FEATURE FLAGS
-- ============================================================================
create table if not exists public.secoto_feature_flags (
  key        text primary key,
  enabled    boolean not null default false,
  updated_at timestamptz not null default now(),
  updated_by uuid references public.accounts(id) on delete set null,
  constraint secoto_feature_flags_key_check check (key in (
    'auto_pricing', 'od_payments', 'subscriptions',
    'dispatch_notifications', 'live_tracking'
  ))
);
insert into public.secoto_feature_flags(key) values
  ('auto_pricing'), ('od_payments'), ('subscriptions'),
  ('dispatch_notifications'), ('live_tracking')
on conflict (key) do nothing;
alter table public.secoto_feature_flags enable row level security;
revoke all on table public.secoto_feature_flags from public, anon, authenticated;

create or replace function secoto_private.flag(p_key text)
returns boolean language sql stable security definer set search_path = ''
as $f$ select coalesce((select f.enabled from public.secoto_feature_flags f where f.key = p_key), false); $f$;

-- Politique opérationnelle paramétrable (délais d'offre, verrou de capture…).
insert into public.app_settings(key, value) values ('dispatch_policy', jsonb_build_object(
  'offer_ttl_minutes', 30,
  'max_rounds', 3,
  'capture_lock_seconds', 120,
  'authorization_window_hours', 144,
  'min_margin_pct_without_admin', 15,
  'quote_validity_hours', 24
)) on conflict (key) do nothing;

create or replace function secoto_private.policy_num(p_key text, p_default numeric)
returns numeric language sql stable security definer set search_path = ''
as $f$
  select coalesce((select (s.value ->> p_key)::numeric from public.app_settings s where s.key = 'dispatch_policy'), p_default);
$f$;

-- ============================================================================
-- 2. JOURNAL DES ACTIONS ET DÉCISIONS
-- ============================================================================
create table if not exists public.secoto_audit_log (
  id         bigint generated always as identity primary key,
  actor_id   uuid,
  action     text not null,
  entity     text not null,
  entity_id  text,
  details    jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);
create index if not exists secoto_audit_log_entity_idx on public.secoto_audit_log(entity, entity_id, created_at desc);
alter table public.secoto_audit_log enable row level security;
revoke all on table public.secoto_audit_log from public, anon, authenticated;

create or replace function secoto_private.audit(p_action text, p_entity text, p_entity_id text, p_details jsonb)
returns void language sql volatile security definer set search_path = ''
as $f$
  insert into public.secoto_audit_log(actor_id, action, entity, entity_id, details)
  values (auth.uid(), p_action, p_entity, p_entity_id, coalesce(p_details, '{}'::jsonb));
$f$;

create or replace function public.secoto_feature_flags()
returns jsonb language sql stable security definer set search_path = ''
as $f$ select coalesce(jsonb_object_agg(f.key, f.enabled), '{}'::jsonb) from public.secoto_feature_flags f; $f$;

create or replace function public.secoto_admin_set_feature_flag(p_key text, p_enabled boolean)
returns jsonb language plpgsql volatile security definer set search_path = ''
as $f$
begin
  perform secoto_private.assert_admin();
  update public.secoto_feature_flags
     set enabled = coalesce(p_enabled, false), updated_at = now(), updated_by = auth.uid()
   where key = p_key;
  if not found then raise exception 'Flag inconnu : %', p_key; end if;
  perform secoto_private.audit('feature_flag_set', 'feature_flag', p_key, jsonb_build_object('enabled', p_enabled));
  return public.secoto_feature_flags();
end;
$f$;

create or replace function public.secoto_admin_audit_log(p_entity text default null, p_entity_id text default null, p_limit int default 200)
returns setof public.secoto_audit_log language plpgsql stable security definer set search_path = ''
as $f$
begin
  perform secoto_private.assert_admin();
  return query select l.* from public.secoto_audit_log l
   where (p_entity is null or l.entity = p_entity) and (p_entity_id is null or l.entity_id = p_entity_id)
   order by l.created_at desc limit least(greatest(coalesce(p_limit, 200), 1), 1000);
end;
$f$;

-- ============================================================================
-- 3. SOCIÉTÉS CLIENTES (cloisonnement des dossiers et des véhicules)
-- ============================================================================
create table if not exists public.business_accounts (
  id         uuid primary key default gen_random_uuid(),
  name       text not null check (length(btrim(name)) between 2 and 160),
  siren      text check (siren is null or siren ~ '^[0-9]{9}$'),
  created_by uuid not null references public.accounts(id),
  created_at timestamptz not null default now()
);
create table if not exists public.business_members (
  business_id uuid not null references public.business_accounts(id) on delete cascade,
  account_id  uuid not null references public.accounts(id) on delete cascade,
  role        text not null default 'member' check (role in ('owner', 'member')),
  created_at  timestamptz not null default now(),
  primary key (business_id, account_id)
);
create index if not exists business_members_account_idx on public.business_members(account_id);
alter table public.business_accounts enable row level security;
alter table public.business_members enable row level security;
revoke all on table public.business_accounts, public.business_members from public, anon, authenticated;

create or replace function secoto_private.is_business_member(p_business_id uuid, p_account uuid default auth.uid())
returns boolean language sql stable security definer set search_path = ''
as $f$ select exists (select 1 from public.business_members bm where bm.business_id = p_business_id and bm.account_id = p_account); $f$;

-- Crée la société de l'utilisateur (ou renvoie celle dont il est déjà propriétaire).
create or replace function public.secoto_business_ensure(p_name text, p_siren text default null)
returns jsonb language plpgsql volatile security definer set search_path = ''
as $f$
declare
  v_user uuid := secoto_private.assert_authenticated();
  v_id uuid;
begin
  select bm.business_id into v_id from public.business_members bm where bm.account_id = v_user and bm.role = 'owner' limit 1;
  if v_id is null then
    insert into public.business_accounts(name, siren, created_by)
    values (btrim(p_name), nullif(regexp_replace(coalesce(p_siren, ''), '\s', '', 'g'), ''), v_user)
    returning id into v_id;
    insert into public.business_members(business_id, account_id, role) values (v_id, v_user, 'owner');
  end if;
  return (select jsonb_build_object('id', b.id, 'name', b.name, 'siren', b.siren) from public.business_accounts b where b.id = v_id);
end;
$f$;

create or replace function public.secoto_my_businesses()
returns jsonb language sql stable security definer set search_path = ''
as $f$
  select coalesce(jsonb_agg(jsonb_build_object('id', b.id, 'name', b.name, 'siren', b.siren, 'role', bm.role) order by b.created_at), '[]'::jsonb)
  from public.business_members bm join public.business_accounts b on b.id = bm.business_id
  where bm.account_id = auth.uid();
$f$;

-- ============================================================================
-- 4. BARÈMES VERSIONNÉS
-- ============================================================================
create table if not exists public.pricing_grids (
  id           uuid primary key default gen_random_uuid(),
  mode         text not null check (mode in ('convoyage', 'plateau')),
  version      integer not null check (version > 0),
  status       text not null default 'draft' check (status in ('draft', 'active', 'archived')),
  params       jsonb not null,
  source_note  text not null check (length(btrim(source_note)) >= 5),
  created_by   uuid references public.accounts(id) on delete set null,
  created_at   timestamptz not null default now(),
  activated_at timestamptz,
  activated_by uuid references public.accounts(id) on delete set null,
  unique (mode, version)
);
create unique index if not exists pricing_grids_one_active_per_mode on public.pricing_grids(mode) where status = 'active';
alter table public.pricing_grids enable row level security;
revoke all on table public.pricing_grids from public, anon, authenticated;

-- Convoyage v1 : STRICTEMENT le barème validé en base (migration 009) :
-- paliers cumulatifs 1,00 / 0,90 / 0,88 €/km, plancher 115 €, convoyeur
-- 0,55 €/km, frais réels (carburant, péages) remboursés sur justificatifs.
-- Aucun supplément d'urgence (décision en vigueur).
-- Garde-fous tirés de l'analyse SECOTO-025 (barème déficitaire sur utilitaire
-- au-delà de 600 km) : prix automatique limité aux voitures et à 600 km.
insert into public.pricing_grids(mode, version, status, params, source_note, activated_at)
select 'convoyage', 1, 'active', jsonb_build_object(
  'engine', 'secoto-pricing-1',
  'tier_method', 'cumulative',
  'tiers', jsonb_build_array(
    jsonb_build_object('up_to_km', 300, 'eur_per_km', 1.00),
    jsonb_build_object('up_to_km', 600, 'eur_per_km', 0.90),
    jsonb_build_object('up_to_km', null, 'eur_per_km', 0.88)),
  'minimum_eur', 115,
  'partner_eur_per_km', 0.55,
  'partner_minimum_eur', 0,
  'approach_eur_per_km', 0,
  'return_positioning_eur', 0,
  'urgent_pct', 0,
  'urgent_threshold_hours', 24,
  'min_notice_hours', 12,
  'auto_vehicle_classes', jsonb_build_array('voiture'),
  'auto_max_km', 600,
  'luxury_auto', false,
  'constraints_auto', false,
  'min_margin_pct', 15,
  'included', jsonb_build_array(
    'Convoyeur vérifié et assuré', 'État des lieux au départ et à la livraison (photos)',
    'Bon de livraison', 'Suivi de la mission dans l''application'),
  'excluded', jsonb_build_array(
    'Carburant et péages : frais réels refacturés sur justificatifs validés',
    'Retour du convoyeur : à sa charge')
), 'Barème convoyage migration 009 (1,00/0,90/0,88 €/km, plancher 115 €, convoyeur 0,55 €/km) — limites SECOTO-025', now()
where not exists (select 1 from public.pricing_grids g where g.mode = 'convoyage');

-- Plateau : BROUILLON NON ACTIVABLE en l'état. Deux références coexistent dans
-- le projet (grille 2,20 €/km ≤300 km puis 1,80 €/km global, et le modèle
-- application « tarif transporteur × 1,20 ») ; la rémunération transporteur
-- n'est pas fixée par la grille. Devis manuel tant qu'un barème n'est pas validé.
insert into public.pricing_grids(mode, version, status, params, source_note)
select 'plateau', 1, 'draft', jsonb_build_object(
  'engine', 'secoto-pricing-1',
  'tier_method', 'global',
  'tiers', jsonb_build_array(
    jsonb_build_object('up_to_km', 300, 'eur_per_km', 2.20),
    jsonb_build_object('up_to_km', null, 'eur_per_km', 1.80)),
  'minimum_eur', 0,
  'auto_vehicle_classes', jsonb_build_array('voiture', 'moto'),
  'luxury_auto', false,
  'constraints_auto', false,
  'non_rolling_auto', false,
  'min_margin_pct', 15,
  'included', jsonb_build_array('Chargement', 'Plateau', 'Péages', 'État des lieux', 'Bon de livraison'),
  'excluded', jsonb_build_array()
), 'BROUILLON — grille plateau 2,20/1,80 €/km sans règle de rémunération transporteur : à valider avant activation'
where not exists (select 1 from public.pricing_grids g where g.mode = 'plateau');

create or replace function secoto_private.validate_grid_params(p_mode text, p jsonb)
returns void language plpgsql immutable set search_path = ''
as $f$
declare v_tier jsonb; v_prev numeric := 0;
begin
  if jsonb_typeof(p -> 'tiers') <> 'array' or jsonb_array_length(p -> 'tiers') = 0 then
    raise exception 'Barème invalide : au moins une tranche est requise.';
  end if;
  if coalesce(p ->> 'tier_method', '') not in ('cumulative', 'global') then
    raise exception 'Barème invalide : tier_method doit valoir cumulative ou global.';
  end if;
  for v_tier in select value from jsonb_array_elements(p -> 'tiers') loop
    if (v_tier ->> 'eur_per_km') is null or (v_tier ->> 'eur_per_km')::numeric <= 0 or (v_tier ->> 'eur_per_km')::numeric > 20 then
      raise exception 'Barème invalide : tarif au km hors limites.';
    end if;
    if v_tier ->> 'up_to_km' is not null then
      if (v_tier ->> 'up_to_km')::numeric <= v_prev then raise exception 'Barème invalide : tranches non croissantes.'; end if;
      v_prev := (v_tier ->> 'up_to_km')::numeric;
    end if;
  end loop;
  if (p -> 'tiers' -> (jsonb_array_length(p -> 'tiers') - 1) ->> 'up_to_km') is not null then
    raise exception 'Barème invalide : la dernière tranche doit être ouverte (up_to_km = null).';
  end if;
  if coalesce((p ->> 'min_margin_pct')::numeric, -1) < 0 or (p ->> 'min_margin_pct')::numeric >= 100 then
    raise exception 'Barème invalide : min_margin_pct requis (0 à 99).';
  end if;
end;
$f$;

-- Moteur de prix pur : aucune écriture, aucun accès réseau.
create or replace function secoto_private.price_with_grid(
  p_mode text, p jsonb, p_distance_km numeric, p_vehicle jsonb, p_hours_to_pickup numeric
)
returns jsonb language plpgsql immutable set search_path = ''
as $f$
declare
  v_km numeric := round(coalesce(p_distance_km, 0), 1);
  v_class text := coalesce(p_vehicle ->> 'class', '');
  v_rolling boolean := coalesce((p_vehicle ->> 'rolling')::boolean, true);
  v_client numeric := 0;
  v_partner numeric;
  v_margin numeric;
  v_floor numeric := 0;
  v_tier jsonb;
  v_upto numeric;
  v_rate numeric;
  v_lines jsonb := '[]'::jsonb;
  v_urgent_pct numeric := coalesce((p ->> 'urgent_pct')::numeric, 0);
begin
  if v_km <= 0 then
    return jsonb_build_object('manual_reason', 'distance_indisponible');
  end if;
  if not (v_class in (select jsonb_array_elements_text(coalesce(p -> 'auto_vehicle_classes', '[]'::jsonb)))) then
    return jsonb_build_object('manual_reason', 'categorie_vehicule_hors_bareme');
  end if;
  if p ? 'auto_max_km' and v_km > (p ->> 'auto_max_km')::numeric then
    return jsonb_build_object('manual_reason', 'distance_hors_bareme_automatique');
  end if;
  if coalesce(p_vehicle ->> 'category', 'standard') = 'luxury' and not coalesce((p ->> 'luxury_auto')::boolean, false) then
    return jsonb_build_object('manual_reason', 'vehicule_prestige');
  end if;
  if jsonb_typeof(p_vehicle -> 'constraints') = 'array' and jsonb_array_length(p_vehicle -> 'constraints') > 0
     and not coalesce((p ->> 'constraints_auto')::boolean, false) then
    return jsonb_build_object('manual_reason', 'contraintes_particulieres');
  end if;
  if not v_rolling then
    if p_mode = 'convoyage' then
      return jsonb_build_object('manual_reason', 'convoyage_impossible_vehicule_non_roulant');
    elsif not coalesce((p ->> 'non_rolling_auto')::boolean, false) then
      return jsonb_build_object('manual_reason', 'vehicule_non_roulant');
    end if;
  end if;
  if p_hours_to_pickup is not null and p_hours_to_pickup < coalesce((p ->> 'min_notice_hours')::numeric, 0) then
    return jsonb_build_object('manual_reason', 'delai_trop_court');
  end if;

  if p ->> 'tier_method' = 'global' then
    for v_tier in select value from jsonb_array_elements(p -> 'tiers') loop
      v_upto := (v_tier ->> 'up_to_km')::numeric;
      if v_upto is null or v_km <= v_upto then
        v_rate := (v_tier ->> 'eur_per_km')::numeric;
        v_client := v_km * v_rate;
        v_lines := v_lines || jsonb_build_object('label', format('%s km × %s €/km', v_km, v_rate), 'eur', round(v_client, 2));
        exit;
      end if;
    end loop;
  else
    v_floor := 0;
    for v_tier in select value from jsonb_array_elements(p -> 'tiers') loop
      exit when v_km <= v_floor;
      v_upto := (v_tier ->> 'up_to_km')::numeric;
      v_rate := (v_tier ->> 'eur_per_km')::numeric;
      v_client := v_client + (least(v_km, coalesce(v_upto, v_km)) - v_floor) * v_rate;
      v_lines := v_lines || jsonb_build_object(
        'label', format('%s à %s km × %s €/km', v_floor, least(v_km, coalesce(v_upto, v_km)), v_rate),
        'eur', round((least(v_km, coalesce(v_upto, v_km)) - v_floor) * v_rate, 2));
      v_floor := coalesce(v_upto, v_km);
    end loop;
  end if;

  if v_client < coalesce((p ->> 'minimum_eur')::numeric, 0) then
    v_lines := v_lines || jsonb_build_object('label', 'Forfait minimum', 'eur', (p ->> 'minimum_eur')::numeric);
    v_client := (p ->> 'minimum_eur')::numeric;
  end if;

  if v_urgent_pct > 0 and p_hours_to_pickup is not null
     and p_hours_to_pickup < coalesce((p ->> 'urgent_threshold_hours')::numeric, 24) then
    v_lines := v_lines || jsonb_build_object('label', format('Urgence (+%s %%)', v_urgent_pct), 'eur', round(v_client * v_urgent_pct / 100, 2));
    v_client := v_client * (1 + v_urgent_pct / 100);
  end if;
  v_client := round(v_client, 2);

  if p ? 'partner_eur_per_km' then
    v_partner := v_km * (p ->> 'partner_eur_per_km')::numeric
      + v_km * coalesce((p ->> 'approach_eur_per_km')::numeric, 0)
      + coalesce((p ->> 'return_positioning_eur')::numeric, 0);
  elsif p ? 'partner_share_pct' then
    v_partner := v_client * (p ->> 'partner_share_pct')::numeric / 100;
  else
    return jsonb_build_object('manual_reason', 'remuneration_partenaire_non_definie');
  end if;
  v_partner := round(greatest(v_partner, coalesce((p ->> 'partner_minimum_eur')::numeric, 0)), 2);
  v_margin := round(v_client - v_partner, 2);

  if v_margin < v_client * coalesce((p ->> 'min_margin_pct')::numeric, 0) / 100 then
    return jsonb_build_object('manual_reason', 'marge_insuffisante');
  end if;

  return jsonb_build_object(
    'client_cents', (v_client * 100)::integer,
    'partner_cents', (v_partner * 100)::integer,
    'margin_cents', (v_margin * 100)::integer,
    -- Convoyage : SECOTO encaisse tout. Plateau : SECOTO n'encaisse que sa
    -- marge, le transport est réglé directement au transporteur.
    'collect_cents', case when p_mode = 'plateau' then (v_margin * 100)::integer else (v_client * 100)::integer end,
    'transport_direct_cents', case when p_mode = 'plateau' then (v_partner * 100)::integer else 0 end,
    'lines', v_lines,
    'included', coalesce(p -> 'included', '[]'::jsonb),
    'excluded', coalesce(p -> 'excluded', '[]'::jsonb)
  );
end;
$f$;

create or replace function public.secoto_admin_pricing_grids()
returns jsonb language plpgsql stable security definer set search_path = ''
as $f$
begin
  perform secoto_private.assert_admin();
  return coalesce((select jsonb_agg(to_jsonb(g) order by g.mode, g.version desc) from public.pricing_grids g), '[]'::jsonb);
end;
$f$;

create or replace function public.secoto_admin_create_grid_version(p_mode text, p_params jsonb, p_source_note text)
returns jsonb language plpgsql volatile security definer set search_path = ''
as $f$
declare v_row public.pricing_grids%rowtype;
begin
  perform secoto_private.assert_admin();
  if p_mode not in ('convoyage', 'plateau') then raise exception 'Mode inconnu.'; end if;
  perform secoto_private.validate_grid_params(p_mode, p_params);
  perform pg_advisory_xact_lock(hashtext('pricing_grid:' || p_mode));
  insert into public.pricing_grids(mode, version, status, params, source_note, created_by)
  values (p_mode, coalesce((select max(g.version) from public.pricing_grids g where g.mode = p_mode), 0) + 1,
          'draft', p_params, p_source_note, auth.uid())
  returning * into v_row;
  perform secoto_private.audit('pricing_grid_created', 'pricing_grid', v_row.id::text, jsonb_build_object('mode', p_mode, 'version', v_row.version));
  return to_jsonb(v_row);
end;
$f$;

create or replace function public.secoto_admin_activate_grid(p_grid_id uuid)
returns jsonb language plpgsql volatile security definer set search_path = ''
as $f$
declare v_row public.pricing_grids%rowtype;
begin
  perform secoto_private.assert_admin();
  select * into v_row from public.pricing_grids g where g.id = p_grid_id for update;
  if not found then raise exception 'Barème introuvable.'; end if;
  perform secoto_private.validate_grid_params(v_row.mode, v_row.params);
  if not (v_row.params ? 'partner_eur_per_km' or v_row.params ? 'partner_share_pct') then
    raise exception 'Activation refusée : la rémunération partenaire n''est pas définie dans ce barème.';
  end if;
  perform pg_advisory_xact_lock(hashtext('pricing_grid:' || v_row.mode));
  update public.pricing_grids set status = 'archived' where mode = v_row.mode and status = 'active' and id <> v_row.id;
  update public.pricing_grids set status = 'active', activated_at = now(), activated_by = auth.uid()
   where id = v_row.id returning * into v_row;
  perform secoto_private.audit('pricing_grid_activated', 'pricing_grid', v_row.id::text, jsonb_build_object('mode', v_row.mode, 'version', v_row.version));
  return to_jsonb(v_row);
end;
$f$;

-- Simulation admin sans rien enregistrer.
create or replace function public.secoto_admin_simulate_price(p_grid_id uuid, p_distance_km numeric, p_vehicle jsonb, p_hours_to_pickup numeric default 72)
returns jsonb language plpgsql stable security definer set search_path = ''
as $f$
declare v_row public.pricing_grids%rowtype;
begin
  perform secoto_private.assert_admin();
  select * into v_row from public.pricing_grids g where g.id = p_grid_id;
  if not found then raise exception 'Barème introuvable.'; end if;
  return secoto_private.price_with_grid(v_row.mode, v_row.params, p_distance_km, p_vehicle, p_hours_to_pickup);
end;
$f$;

-- ============================================================================
-- 5. NOTIFICATIONS — nouveaux écrans et référence d'objet
-- ============================================================================
alter table public.notifications add column if not exists ref_id uuid;

create or replace function secoto_private.prepare_notification()
returns trigger language plpgsql volatile security definer set search_path = ''
as $function$
begin
  new.push_screen := case
    when new.push_screen in (
      'courses','documents','frais','available','assigned',
      'applications','requests','paiement','transporters',
      -- Migration 030.
      'offre','suivi','abonnement'
    ) then new.push_screen
    when new.type = 'document' then 'documents'
    when new.type in ('frais','frais_status') then 'frais'
    when new.type = 'new_application' then 'applications'
    when new.type = 'new_request' then 'requests'
    when new.type = 'new_course' then 'available'
    when new.type = 'mission_offer' then 'offre'
    when new.type in ('live_tracking') then 'suivi'
    when new.type in ('subscription') then 'abonnement'
    when new.type in ('payment','payment_failed') then 'paiement'
    when new.type = 'new_account' then 'transporters'
    when new.type in ('tracking','delivered','course_assigned','cancellation','order_update') then 'courses'
    else 'courses'
  end;
  new.event_key := coalesce(new.event_key, 'notification:' || new.id::text);
  return new;
end;
$function$;

-- Écriture directe d'une notification des nouveaux parcours. Le titre et le
-- corps restent consultables dans l'application (session authentifiée) ; la
-- copie PUSH, elle, est construite par la fonction Netlify selon la
-- confidentialité choisie par le destinataire.
create or replace function secoto_private.notify_event(
  p_account_id uuid, p_type text, p_title text, p_body text,
  p_mission_id uuid, p_screen text, p_event_key text, p_ref_id uuid
)
returns uuid language plpgsql volatile security definer set search_path = ''
as $f$
declare v_id uuid; v_audience text;
begin
  if p_account_id is null then return null; end if;
  if p_type not in ('mission_offer', 'order_update', 'live_tracking', 'subscription', 'payment', 'payment_failed', 'cancellation', 'course_assigned', 'new_request') then
    raise exception 'Type de notification non autorisé : %', p_type;
  end if;
  select a.role::text into v_audience from public.accounts a where a.id = p_account_id;
  insert into public.notifications(account_id, type, title, body, mission_id, audience, is_read, push_screen, event_key, ref_id)
  values (p_account_id, p_type, left(p_title, 120), left(p_body, 400), p_mission_id, v_audience, false, p_screen, p_event_key, p_ref_id)
  on conflict (event_key) where event_key is not null do nothing
  returning id into v_id;
  return v_id;
end;
$f$;

create or replace function secoto_private.notify_admins_event(p_type text, p_title text, p_body text, p_screen text, p_event_prefix text, p_ref_id uuid)
returns void language plpgsql volatile security definer set search_path = ''
as $f$
declare r record;
begin
  for r in select a.id from public.accounts a where a.role::text = 'admin' and a.deleted_at is null loop
    perform secoto_private.notify_event(r.id, p_type, p_title, p_body, null, p_screen, p_event_prefix || ':' || r.id::text, p_ref_id);
  end loop;
end;
$f$;

-- ============================================================================
-- 6. ÉCHÉANCES DOCUMENTAIRES PARTENAIRES
-- ============================================================================
alter table public.documents add column if not exists valid_until date;

create or replace function secoto_private.partner_documents_valid(p_partner uuid)
returns boolean language sql stable security definer set search_path = ''
as $f$
  select not exists (
    select 1 from public.documents d
    where d.account_id = p_partner and d.doc_type is null
      and d.valid_until is not null and d.valid_until < current_date
      and coalesce(d.status, '') not in ('rejected', 'refuse', 'replaced', 'remplace')
  );
$f$;

create or replace function public.secoto_admin_set_document_validity(p_document_id uuid, p_valid_until date)
returns jsonb language plpgsql volatile security definer set search_path = ''
as $f$
begin
  perform secoto_private.assert_admin();
  update public.documents set valid_until = p_valid_until where id = p_document_id and doc_type is null;
  if not found then raise exception 'Document partenaire introuvable.'; end if;
  perform secoto_private.audit('document_validity_set', 'document', p_document_id::text, jsonb_build_object('valid_until', p_valid_until));
  return jsonb_build_object('id', p_document_id, 'valid_until', p_valid_until);
end;
$f$;

create or replace function public.secoto_admin_partner_compliance()
returns jsonb language plpgsql stable security definer set search_path = ''
as $f$
begin
  perform secoto_private.assert_admin();
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'partner_id', a.id, 'name', coalesce(a.company_name, a.full_name), 'transporter_type', a.transporter_type,
      'status', a.status, 'is_verified', a.is_verified,
      'documents_valid', secoto_private.partner_documents_valid(a.id),
      'next_expiry', (select min(d.valid_until) from public.documents d where d.account_id = a.id and d.doc_type is null and d.valid_until >= current_date),
      'expired', (select coalesce(jsonb_agg(jsonb_build_object('id', d.id, 'type', d.type, 'valid_until', d.valid_until)), '[]'::jsonb)
                  from public.documents d where d.account_id = a.id and d.doc_type is null and d.valid_until < current_date),
      'available', coalesce(p.available, false),
      'notify_offline', coalesce(p.notify_offline, false)
    ) order by a.created_at)
    from public.accounts a
    left join public.partner_dispatch_preferences p on p.account_id = a.id
    where a.role::text = 'transporter' and a.deleted_at is null
  ), '[]'::jsonb);
end;
$f$;

-- ============================================================================
-- 7. PRÉFÉRENCES DE DIFFUSION DES PARTENAIRES (aucune obligation)
-- ============================================================================
create table if not exists public.partner_dispatch_preferences (
  account_id          uuid primary key references public.accounts(id) on delete cascade,
  available           boolean not null default false,
  available_changed_at timestamptz,
  notify_offline      boolean not null default false,
  lockscreen_privacy  text not null default 'masked' check (lockscreen_privacy in ('masked', 'detailed')),
  zones               text[] not null default '{}',   -- départements de départ acceptés ('75','92','2A'…) ; vide = partout
  vehicle_classes     text[] not null default '{}',   -- voiture, utilitaire, moto, autre ; vide = toutes
  equipment           text[] not null default '{}',   -- treuil, camion_ferme, plateau_2_places…
  weekdays            smallint[] not null default '{}', -- 1 = lundi … 7 = dimanche ; vide = tous
  updated_at          timestamptz not null default now()
);
alter table public.partner_dispatch_preferences enable row level security;
revoke all on table public.partner_dispatch_preferences from public, anon, authenticated;

create or replace function public.secoto_my_dispatch_preferences()
returns jsonb language plpgsql stable security definer set search_path = ''
as $f$
declare v_user uuid := secoto_private.assert_authenticated(); v jsonb;
begin
  select to_jsonb(p) - 'account_id' into v from public.partner_dispatch_preferences p where p.account_id = v_user;
  return coalesce(v, jsonb_build_object('available', false, 'notify_offline', false, 'lockscreen_privacy', 'masked',
    'zones', '[]'::jsonb, 'vehicle_classes', '[]'::jsonb, 'equipment', '[]'::jsonb, 'weekdays', '[]'::jsonb));
end;
$f$;

create or replace function public.secoto_update_dispatch_preferences(p_payload jsonb)
returns jsonb language plpgsql volatile security definer set search_path = ''
as $f$
declare
  v_user uuid := secoto_private.assert_authenticated();
  v_zones text[]; v_classes text[]; v_equipment text[]; v_days smallint[];
  v_available boolean := coalesce((p_payload ->> 'available')::boolean, false);
begin
  if secoto_private.account_role(v_user) <> 'transporter' then
    raise exception 'Réservé aux partenaires transporteurs et convoyeurs.';
  end if;
  select coalesce(array_agg(distinct upper(z)), '{}') into v_zones
    from jsonb_array_elements_text(coalesce(p_payload -> 'zones', '[]'::jsonb)) z;
  if exists (select 1 from unnest(v_zones) z where z !~ '^([0-9]{2}|2A|2B|97[1-6])$') then
    raise exception 'Zone invalide : indiquez des numéros de département (ex. 75, 92, 2A).';
  end if;
  select coalesce(array_agg(distinct c), '{}') into v_classes
    from jsonb_array_elements_text(coalesce(p_payload -> 'vehicle_classes', '[]'::jsonb)) c;
  if exists (select 1 from unnest(v_classes) c where c not in ('voiture', 'utilitaire', 'moto', 'autre')) then
    raise exception 'Catégorie de véhicule invalide.';
  end if;
  select coalesce(array_agg(distinct e), '{}') into v_equipment
    from jsonb_array_elements_text(coalesce(p_payload -> 'equipment', '[]'::jsonb)) e;
  if exists (select 1 from unnest(v_equipment) e where e not in ('treuil', 'camion_ferme', 'plateau_2_places', 'plateau_3_places', 'hayon')) then
    raise exception 'Équipement invalide.';
  end if;
  select coalesce(array_agg(distinct d::smallint), '{}') into v_days
    from jsonb_array_elements_text(coalesce(p_payload -> 'weekdays', '[]'::jsonb)) d;
  if exists (select 1 from unnest(v_days) d where d not between 1 and 7) then
    raise exception 'Jour invalide.';
  end if;

  insert into public.partner_dispatch_preferences as p(account_id, available, available_changed_at, notify_offline, lockscreen_privacy, zones, vehicle_classes, equipment, weekdays, updated_at)
  values (v_user, v_available, now(), coalesce((p_payload ->> 'notify_offline')::boolean, false),
          case when p_payload ->> 'lockscreen_privacy' = 'detailed' then 'detailed' else 'masked' end,
          v_zones, v_classes, v_equipment, v_days, now())
  on conflict (account_id) do update set
    available = excluded.available,
    available_changed_at = case when p.available is distinct from excluded.available then now() else p.available_changed_at end,
    notify_offline = excluded.notify_offline,
    lockscreen_privacy = excluded.lockscreen_privacy,
    zones = excluded.zones, vehicle_classes = excluded.vehicle_classes,
    equipment = excluded.equipment, weekdays = excluded.weekdays, updated_at = now();
  return public.secoto_my_dispatch_preferences();
end;
$f$;

-- ============================================================================
-- 8. DEVIS
-- ============================================================================
create table if not exists public.transport_quotes (
  id                     uuid primary key default gen_random_uuid(),
  account_id             uuid not null references public.accounts(id),
  business_id            uuid references public.business_accounts(id),
  mode                   text not null check (mode in ('convoyage', 'plateau')),
  status                 text not null check (status in ('priced', 'manual_review', 'manual_priced', 'accepted', 'expired', 'cancelled', 'declined')),
  pickup                 jsonb not null,
  delivery               jsonb not null,
  vehicle                jsonb not null,
  schedule               jsonb not null,
  route                  jsonb,
  grid_id                uuid references public.pricing_grids(id),
  grid_version           integer,
  engine                 text,
  client_price_cents     integer check (client_price_cents is null or client_price_cents > 0),
  partner_pay_cents      integer check (partner_pay_cents is null or partner_pay_cents >= 0),
  margin_cents           integer,
  collect_cents          integer check (collect_cents is null or collect_cents > 0),
  transport_direct_cents integer not null default 0,
  breakdown              jsonb not null default '{}'::jsonb,
  manual_reason          text,
  valid_until            timestamptz,
  pickup_at              timestamptz not null,
  admin_note             text,
  priced_by              uuid references public.accounts(id),
  created_at             timestamptz not null default now(),
  updated_at             timestamptz not null default now(),
  constraint transport_quotes_priced_amounts check (
    status not in ('priced', 'manual_priced', 'accepted')
    or (client_price_cents is not null and partner_pay_cents is not null and collect_cents is not null and valid_until is not null))
);
create index if not exists transport_quotes_account_idx on public.transport_quotes(account_id, created_at desc);
create index if not exists transport_quotes_status_idx on public.transport_quotes(status, valid_until);
alter table public.transport_quotes enable row level security;
revoke all on table public.transport_quotes from public, anon, authenticated;

create or replace function secoto_private.department_of(p_postcode text)
returns text language sql immutable set search_path = ''
as $f$
  select case
    when p_postcode ~ '^97[1-6]' then substr(p_postcode, 1, 3)
    when p_postcode ~ '^20[0-1]' then '2A'
    when p_postcode ~ '^20[2-9]' then '2B'
    else substr(p_postcode, 1, 2) end;
$f$;

-- Projection CLIENT : jamais la rémunération partenaire ni la marge.
create or replace function secoto_private.quote_client_json(q public.transport_quotes)
returns jsonb language sql stable set search_path = ''
as $f$
  select jsonb_build_object(
    'id', q.id, 'mode', q.mode, 'status',
      case when q.status in ('priced', 'manual_priced') and q.valid_until <= now() then 'expired' else q.status end,
    'pickup', q.pickup, 'delivery', q.delivery, 'vehicle', q.vehicle, 'schedule', q.schedule,
    'distance_km', q.route -> 'distance_km', 'duration_min', q.route -> 'duration_min',
    'client_price_cents', q.client_price_cents,
    'collect_cents', q.collect_cents,
    'transport_direct_cents', q.transport_direct_cents,
    'lines', coalesce(q.breakdown -> 'lines', '[]'::jsonb),
    'included', coalesce(q.breakdown -> 'included', '[]'::jsonb),
    'excluded', coalesce(q.breakdown -> 'excluded', '[]'::jsonb),
    'grid_version', q.grid_version,
    'manual_reason', q.manual_reason,
    'valid_until', q.valid_until, 'pickup_at', q.pickup_at,
    'business_id', q.business_id, 'created_at', q.created_at);
$f$;

-- Appelée UNIQUEMENT par la fonction Netlify « quote-transport » (service_role),
-- après vérification du jeton de l'utilisateur et calcul de l'itinéraire
-- routier côté serveur : la distance ne vient jamais du téléphone.
create or replace function public.secoto_quote_create(p_account_id uuid, p_payload jsonb, p_route jsonb)
returns jsonb language plpgsql volatile security definer set search_path = ''
as $f$
declare
  v_mode text := p_payload ->> 'mode';
  v_pickup jsonb := p_payload -> 'pickup';
  v_delivery jsonb := p_payload -> 'delivery';
  v_vehicle jsonb := p_payload -> 'vehicle';
  v_schedule jsonb := p_payload -> 'schedule';
  v_business uuid := nullif(p_payload ->> 'business_id', '')::uuid;
  v_pickup_date date;
  v_pickup_at timestamptz;
  v_distance numeric;
  v_grid public.pricing_grids%rowtype;
  v_price jsonb;
  v_quote public.transport_quotes%rowtype;
  v_reason text;
  v_validity numeric;
  v_constraint text;
begin
  if not exists (select 1 from public.accounts a where a.id = p_account_id and a.deleted_at is null and a.role::text in ('client', 'admin')) then
    raise exception 'Compte client introuvable.' using errcode = '42501';
  end if;
  if v_mode not in ('convoyage', 'plateau') then raise exception 'Choisissez convoyage ou plateau.'; end if;
  if v_business is not null and not secoto_private.is_business_member(v_business, p_account_id) then
    raise exception 'Société non autorisée.' using errcode = '42501';
  end if;
  -- Adresses vérifiées (Base Adresse Nationale) : libellé, code postal, coordonnées.
  if jsonb_typeof(v_pickup) <> 'object' or jsonb_typeof(v_delivery) <> 'object' then raise exception 'Adresses manquantes.'; end if;
  if coalesce(v_pickup ->> 'postcode', '') !~ '^[0-9]{5}$' or coalesce(v_delivery ->> 'postcode', '') !~ '^[0-9]{5}$' then
    raise exception 'Sélectionnez les adresses dans la liste proposée (code postal manquant).';
  end if;
  if length(coalesce(v_pickup ->> 'label', '')) not between 5 and 300 or length(coalesce(v_delivery ->> 'label', '')) not between 5 and 300 then
    raise exception 'Adresse invalide.';
  end if;
  if (v_pickup ->> 'lat') is null or (v_pickup ->> 'lng') is null or (v_delivery ->> 'lat') is null or (v_delivery ->> 'lng') is null
     or abs((v_pickup ->> 'lat')::numeric) > 90 or abs((v_delivery ->> 'lat')::numeric) > 90
     or abs((v_pickup ->> 'lng')::numeric) > 180 or abs((v_delivery ->> 'lng')::numeric) > 180 then
    raise exception 'Adresse non vérifiée : sélectionnez une proposition de la liste.';
  end if;
  if jsonb_typeof(v_vehicle) <> 'object' or length(btrim(coalesce(v_vehicle ->> 'model', ''))) not between 2 and 120 then
    raise exception 'Indiquez le modèle du véhicule.';
  end if;
  if coalesce(v_vehicle ->> 'class', '') not in ('voiture', 'utilitaire', 'moto', 'autre') then raise exception 'Catégorie de véhicule invalide.'; end if;
  if coalesce(v_vehicle ->> 'category', 'standard') not in ('standard', 'luxury') then raise exception 'Gamme de véhicule invalide.'; end if;
  if jsonb_typeof(v_vehicle -> 'rolling') <> 'boolean' then raise exception 'Précisez si le véhicule roule.'; end if;
  if v_mode = 'convoyage' and not (v_vehicle ->> 'rolling')::boolean then
    raise exception 'Un véhicule non roulant ne peut pas être convoyé : choisissez le transport sur plateau.';
  end if;
  for v_constraint in select jsonb_array_elements_text(coalesce(v_vehicle -> 'constraints', '[]'::jsonb)) loop
    if v_constraint not in ('sans_cle', 'garde_au_sol_basse', 'gabarit_hors_norme', 'non_immatricule', 'acces_difficile', 'batterie_faible') then
      raise exception 'Contrainte inconnue : %', v_constraint;
    end if;
  end loop;
  if length(coalesce(v_vehicle ->> 'notes', '')) > 500 then raise exception 'Précisions trop longues (500 caractères).'; end if;
  begin
    v_pickup_date := (v_schedule ->> 'pickup_date')::date;
  exception when others then raise exception 'Date de prise en charge invalide.';
  end;
  if v_pickup_date is null or v_pickup_date < (now() at time zone 'Europe/Paris')::date or v_pickup_date > current_date + 365 then
    raise exception 'Date de prise en charge invalide.';
  end if;
  if coalesce(v_schedule ->> 'slot', '') not in ('matin', 'apres_midi', 'journee') then raise exception 'Choisissez un créneau.'; end if;
  if coalesce((v_schedule ->> 'flexibility_days')::int, 0) not between 0 and 14 then raise exception 'Souplesse invalide (0 à 14 jours).'; end if;
  v_pickup_at := (v_pickup_date + case v_schedule ->> 'slot' when 'apres_midi' then time '13:00' else time '08:00' end) at time zone 'Europe/Paris';

  v_distance := nullif(p_route ->> 'distance_km', '')::numeric;
  if v_distance is not null and (v_distance <= 0 or v_distance > 3000) then v_distance := null; end if;

  select * into v_grid from public.pricing_grids g where g.mode = v_mode and g.status = 'active';
  if not secoto_private.flag('auto_pricing') then
    v_reason := 'prix_automatique_desactive';
  elsif v_grid.id is null then
    v_reason := 'aucun_bareme_actif';
  elsif v_distance is null then
    v_reason := 'itineraire_indisponible';
  else
    v_price := secoto_private.price_with_grid(v_mode, v_grid.params, v_distance, v_vehicle,
      extract(epoch from (v_pickup_at - now())) / 3600);
    v_reason := v_price ->> 'manual_reason';
  end if;

  v_validity := least(
    coalesce((v_grid.params ->> 'quote_validity_hours')::numeric, secoto_private.policy_num('quote_validity_hours', 24)),
    greatest(extract(epoch from (v_pickup_at - now())) / 3600, 1));

  insert into public.transport_quotes(
    account_id, business_id, mode, status, pickup, delivery, vehicle, schedule, route,
    grid_id, grid_version, engine, client_price_cents, partner_pay_cents, margin_cents,
    collect_cents, transport_direct_cents, breakdown, manual_reason, valid_until, pickup_at)
  values (
    p_account_id, v_business, v_mode,
    case when v_reason is null then 'priced' else 'manual_review' end,
    v_pickup, v_delivery, v_vehicle, v_schedule,
    case when v_distance is null then null else jsonb_build_object(
      'distance_km', round(v_distance, 1), 'duration_min', nullif(p_route ->> 'duration_min', '')::numeric,
      'provider', left(coalesce(p_route ->> 'provider', 'inconnu'), 40), 'computed_at', now()) end,
    v_grid.id, v_grid.version, v_grid.params ->> 'engine',
    case when v_reason is null then (v_price ->> 'client_cents')::int end,
    case when v_reason is null then (v_price ->> 'partner_cents')::int end,
    case when v_reason is null then (v_price ->> 'margin_cents')::int end,
    case when v_reason is null then (v_price ->> 'collect_cents')::int end,
    case when v_reason is null then (v_price ->> 'transport_direct_cents')::int else 0 end,
    case when v_reason is null then jsonb_build_object('lines', v_price -> 'lines', 'included', v_price -> 'included', 'excluded', v_price -> 'excluded')
         else jsonb_build_object('included', coalesce(v_grid.params -> 'included', '[]'::jsonb), 'excluded', coalesce(v_grid.params -> 'excluded', '[]'::jsonb)) end,
    v_reason,
    case when v_reason is null then now() + make_interval(secs => v_validity * 3600) end,
    v_pickup_at)
  returning * into v_quote;

  if v_reason is not null then
    perform secoto_private.notify_admins_event('new_request', 'Devis manuel à établir',
      format('%s → %s · %s (%s)', v_pickup ->> 'city', v_delivery ->> 'city', v_vehicle ->> 'model', v_reason),
      'requests', 'quote-manual:' || v_quote.id::text, v_quote.id);
  end if;

  return secoto_private.quote_client_json(v_quote);
end;
$f$;

create or replace function public.secoto_my_quotes()
returns jsonb language sql stable security definer set search_path = ''
as $f$
  select coalesce(jsonb_agg(secoto_private.quote_client_json(q) order by q.created_at desc), '[]'::jsonb)
  from public.transport_quotes q
  where q.account_id = auth.uid()
     or (q.business_id is not null and secoto_private.is_business_member(q.business_id, auth.uid()));
$f$;

create or replace function public.secoto_admin_quotes(p_status text default null)
returns jsonb language plpgsql stable security definer set search_path = ''
as $f$
begin
  perform secoto_private.assert_admin();
  return coalesce((select jsonb_agg(to_jsonb(q) || jsonb_build_object(
      'client_name', coalesce(a.company_name, a.full_name), 'client_email', a.email)
    order by q.created_at desc)
    from public.transport_quotes q join public.accounts a on a.id = q.account_id
    where p_status is null or q.status = p_status), '[]'::jsonb);
end;
$f$;

-- Devis manuel : l'administrateur fixe prix client et rémunération partenaire.
create or replace function public.secoto_admin_price_quote(
  p_quote_id uuid, p_client_price_cents integer, p_partner_pay_cents integer,
  p_validity_hours integer, p_note text, p_override_margin boolean default false
)
returns jsonb language plpgsql volatile security definer set search_path = ''
as $f$
declare
  v_quote public.transport_quotes%rowtype;
  v_margin integer;
  v_min_pct numeric := secoto_private.policy_num('min_margin_pct_without_admin', 15);
begin
  perform secoto_private.assert_admin();
  select * into v_quote from public.transport_quotes q where q.id = p_quote_id for update;
  if not found then raise exception 'Devis introuvable.'; end if;
  if v_quote.status not in ('manual_review', 'manual_priced', 'priced', 'expired') then raise exception 'Devis non modifiable (%).', v_quote.status; end if;
  if coalesce(p_client_price_cents, 0) <= 0 or coalesce(p_partner_pay_cents, -1) < 0 then raise exception 'Montants invalides.'; end if;
  if coalesce(p_validity_hours, 0) not between 1 and 720 then raise exception 'Validité invalide (1 à 720 h).'; end if;
  v_margin := p_client_price_cents - p_partner_pay_cents;
  if v_margin <= 0 then raise exception 'La rémunération partenaire dépasse le prix client.'; end if;
  if v_margin < p_client_price_cents * v_min_pct / 100 and not coalesce(p_override_margin, false) then
    raise exception 'Marge inférieure au seuil de % %% : confirmez explicitement la dérogation.', v_min_pct;
  end if;
  update public.transport_quotes set
    status = 'manual_priced',
    client_price_cents = p_client_price_cents,
    partner_pay_cents = p_partner_pay_cents,
    margin_cents = v_margin,
    collect_cents = case when mode = 'plateau' then v_margin else p_client_price_cents end,
    transport_direct_cents = case when mode = 'plateau' then p_partner_pay_cents else 0 end,
    breakdown = breakdown || jsonb_build_object('lines', jsonb_build_array(jsonb_build_object('label', 'Devis établi par SECOTO', 'eur', p_client_price_cents / 100.0))),
    valid_until = least(now() + make_interval(hours => p_validity_hours), greatest(pickup_at, now() + interval '1 hour')),
    admin_note = left(p_note, 1000), priced_by = auth.uid(), updated_at = now()
  where id = p_quote_id returning * into v_quote;
  perform secoto_private.audit('quote_priced', 'transport_quote', p_quote_id::text, jsonb_build_object(
    'client_price_cents', p_client_price_cents, 'partner_pay_cents', p_partner_pay_cents,
    'margin_cents', v_margin, 'override_margin', coalesce(p_override_margin, false), 'note', p_note));
  perform secoto_private.notify_event(v_quote.account_id, 'order_update', 'Votre devis est prêt',
    format('%s → %s : %s €', v_quote.pickup ->> 'city', v_quote.delivery ->> 'city', to_char(v_quote.client_price_cents / 100.0, 'FM999990D00')),
    null, 'courses', 'quote-priced:' || p_quote_id::text || ':' || extract(epoch from now())::bigint, p_quote_id);
  return to_jsonb(v_quote);
end;
$f$;

-- ============================================================================
-- 9. PAIEMENTS — extension compatible
-- ============================================================================
alter table public.payments alter column mission_id drop not null;
alter table public.payments
  add column if not exists order_id uuid,
  add column if not exists capture_method text not null default 'automatic',
  add column if not exists authorized_at timestamptz,
  add column if not exists captured_at timestamptz,
  add column if not exists released_at timestamptz,
  add column if not exists release_requested_at timestamptz,
  add column if not exists capture_before timestamptz,
  add column if not exists dispute_status text,
  add column if not exists last_event_at timestamptz;

alter table public.payments drop constraint if exists payments_purpose_check;
alter table public.payments add constraint payments_purpose_check
  check (purpose in ('commission_plateau', 'convoyage_livraison', 'od_convoyage', 'od_plateau_commission', 'subscription_extension'));
alter table public.payments drop constraint if exists payments_status_check;
alter table public.payments add constraint payments_status_check
  check (status in ('pending', 'processing', 'paid', 'failed', 'refund_pending', 'refunded', 'cancelled',
                    'requires_capture', 'capture_failed'));
alter table public.payments drop constraint if exists payments_capture_method_check;
alter table public.payments add constraint payments_capture_method_check check (capture_method in ('automatic', 'manual'));
alter table public.payments drop constraint if exists payments_target_check;
alter table public.payments add constraint payments_target_check
  check (mission_id is not null or order_id is not null or purpose = 'subscription_extension');

-- Un seul paiement vivant par commande : aucun double encaissement possible.
create unique index if not exists payments_order_live_key on public.payments(order_id)
  where order_id is not null and status in ('pending', 'processing', 'requires_capture', 'paid', 'refund_pending');

-- ============================================================================
-- 10. COMMANDES ET OFFRES
-- ============================================================================
create table if not exists public.transport_orders (
  id                     uuid primary key default gen_random_uuid(),
  public_ref             text not null unique,
  quote_id               uuid not null unique references public.transport_quotes(id),
  account_id             uuid not null references public.accounts(id),
  business_id            uuid references public.business_accounts(id),
  mode                   text not null check (mode in ('convoyage', 'plateau')),
  funding                text not null check (funding in ('card', 'subscription')),
  -- ÉTAT DU TRANSPORT. L'état du paiement vit dans public.payments.
  status                 text not null check (status in (
                           'awaiting_payment', 'searching_partner', 'partner_locked', 'partner_confirmed',
                           'picked_up', 'delivered', 'no_partner', 'cancelled')),
  payment_strategy       text not null check (payment_strategy in ('authorize_then_capture', 'capture_then_refund', 'subscription')),
  payment_id             uuid references public.payments(id),
  client_price_cents     integer not null,
  partner_pay_cents      integer not null check (partner_pay_cents >= 0),
  collect_cents          integer not null,
  transport_direct_cents integer not null default 0,
  pickup_at              timestamptz not null,
  dispatch_round         integer not null default 0,
  offers_expire_at       timestamptz,
  lock_partner_id        uuid references public.accounts(id),
  lock_offer_id          uuid,
  lock_expires_at        timestamptz,
  assigned_partner_id    uuid references public.accounts(id),
  mission_id             uuid unique references public.missions(id),
  confirmed_at           timestamptz,
  cancelled_at           timestamptz,
  cancel_reason          text,
  created_at             timestamptz not null default now(),
  updated_at             timestamptz not null default now(),
  constraint transport_orders_lock_check check (status <> 'partner_locked' or (lock_partner_id is not null and lock_expires_at is not null)),
  constraint transport_orders_confirmed_check check (status not in ('partner_confirmed', 'picked_up', 'delivered') or (assigned_partner_id is not null and mission_id is not null))
);
create index if not exists transport_orders_account_idx on public.transport_orders(account_id, created_at desc);
create index if not exists transport_orders_status_idx on public.transport_orders(status, offers_expire_at);
alter table public.payments drop constraint if exists payments_order_id_fkey;
alter table public.payments add constraint payments_order_id_fkey foreign key (order_id) references public.transport_orders(id) not valid;

create table if not exists public.transport_offers (
  id                uuid primary key default gen_random_uuid(),
  order_id          uuid not null references public.transport_orders(id) on delete cascade,
  partner_id        uuid not null references public.accounts(id),
  round             integer not null,
  status            text not null default 'sent' check (status in ('sent', 'accepted', 'declined', 'expired', 'lost', 'withdrawn', 'voided')),
  partner_pay_cents integer not null,
  created_at        timestamptz not null default now(),
  expires_at        timestamptz not null,
  seen_at           timestamptz,
  responded_at      timestamptz,
  unique (order_id, partner_id, round)
);
create index if not exists transport_offers_partner_idx on public.transport_offers(partner_id, status, expires_at);
create index if not exists transport_offers_order_idx on public.transport_offers(order_id, status);

create table if not exists public.partner_payouts (
  id           uuid primary key default gen_random_uuid(),
  mission_id   uuid not null unique references public.missions(id),
  order_id     uuid references public.transport_orders(id),
  partner_id   uuid not null references public.accounts(id),
  amount_cents integer not null check (amount_cents >= 0),
  status       text not null default 'to_pay' check (status in ('to_pay', 'paid', 'cancelled')),
  reference    text,
  paid_at      timestamptz,
  marked_by    uuid references public.accounts(id),
  created_at   timestamptz not null default now()
);

alter table public.transport_orders enable row level security;
alter table public.transport_offers enable row level security;
alter table public.partner_payouts enable row level security;
revoke all on table public.transport_orders, public.transport_offers, public.partner_payouts from public, anon, authenticated;

create or replace function secoto_private.new_order_ref()
returns text language plpgsql volatile security definer set search_path = ''
as $f$
declare v text;
begin
  loop
    v := 'CMD-' || to_char(now(), 'YYYY') || '-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 8));
    exit when not exists (select 1 from public.transport_orders o where o.public_ref = v);
  end loop;
  return v;
end;
$f$;

-- Libellés client : on distingue sans ambiguïté transport et paiement.
create or replace function secoto_private.order_client_json(o public.transport_orders)
returns jsonb language sql stable security definer set search_path = ''
as $f$
  select jsonb_build_object(
    'id', o.id, 'public_ref', o.public_ref, 'mode', o.mode, 'funding', o.funding,
    'status', o.status, 'payment_strategy', o.payment_strategy,
    'payment_status', p.status, 'payment_id', o.payment_id,
    'client_price_cents', o.client_price_cents, 'collect_cents', o.collect_cents,
    'transport_direct_cents', o.transport_direct_cents,
    'pickup', q.pickup, 'delivery', q.delivery, 'vehicle', q.vehicle, 'schedule', q.schedule,
    'distance_km', q.route -> 'distance_km',
    'included', coalesce(q.breakdown -> 'included', '[]'::jsonb), 'excluded', coalesce(q.breakdown -> 'excluded', '[]'::jsonb),
    'pickup_at', o.pickup_at, 'mission_id', o.mission_id,
    'partner_name', case when o.assigned_partner_id is not null then (select coalesce(a.company_name, a.full_name) from public.accounts a where a.id = o.assigned_partner_id) end,
    'confirmed_at', o.confirmed_at, 'cancelled_at', o.cancelled_at, 'cancel_reason', o.cancel_reason,
    'created_at', o.created_at, 'updated_at', o.updated_at,
    'milestones', jsonb_build_object(
      'demande_recue', o.created_at,
      'paiement_autorise', coalesce(p.authorized_at, case when o.funding = 'subscription' then o.created_at end),
      'paiement_encaisse', p.captured_at,
      'partenaire_confirme', o.confirmed_at,
      'vehicule_recupere', (select min(e.created_at) from public.mission_tracking_events e where e.mission_id = o.mission_id and e.event_type::text = 'pickup_inspection'),
      'livraison_effectuee', (select min(e.created_at) from public.mission_tracking_events e where e.mission_id = o.mission_id and e.event_type::text = 'delivery_inspection')))
  from public.transport_quotes q
  left join public.payments p on p.id = o.payment_id
  where q.id = o.quote_id;
$f$;

create or replace function public.secoto_od_my_orders()
returns jsonb language sql stable security definer set search_path = ''
as $f$
  select coalesce(jsonb_agg(secoto_private.order_client_json(o) order by o.created_at desc), '[]'::jsonb)
  from public.transport_orders o
  where o.account_id = auth.uid()
     or (o.business_id is not null and secoto_private.is_business_member(o.business_id, auth.uid()));
$f$;

-- Éligibilité d'un partenaire à une commande. Source de vérité unique.
create or replace function secoto_private.od_partner_eligible(p_partner uuid, p_order uuid)
returns boolean language sql stable security definer set search_path = ''
as $f$
  select exists (
    select 1
    from public.transport_orders o
    join public.transport_quotes q on q.id = o.quote_id
    join public.accounts a on a.id = p_partner
    join public.partner_dispatch_preferences pr on pr.account_id = a.id
    where o.id = p_order
      and a.role::text = 'transporter' and a.status::text = 'active'
      and coalesce(a.is_verified, false) and a.deleted_at is null
      and pr.available
      and secoto_private.partner_documents_valid(a.id)
      and (
        (o.mode = 'convoyage' and a.transporter_type::text = 'convoyeur')
        or (o.mode = 'plateau' and a.transporter_type::text in ('vl', 'pl') and (
              (coalesce(q.vehicle ->> 'category', 'standard') = 'standard' and coalesce(a.receives_standard_plateau, true))
           or (q.vehicle ->> 'category' = 'luxury' and a.luxury_closed_transport_status = 'approved')))
      )
      and (cardinality(pr.zones) = 0 or secoto_private.department_of(q.pickup ->> 'postcode') = any(pr.zones))
      and (cardinality(pr.vehicle_classes) = 0 or (q.vehicle ->> 'class') = any(pr.vehicle_classes))
      and (cardinality(pr.weekdays) = 0 or extract(isodow from (o.pickup_at at time zone 'Europe/Paris'))::smallint = any(pr.weekdays))
      and (o.mode <> 'plateau' or coalesce((q.vehicle ->> 'rolling')::boolean, true) or 'treuil' = any(pr.equipment))
      and not exists (select 1 from public.transport_offers x where x.order_id = o.id and x.partner_id = a.id and x.status = 'declined')
  );
$f$;

-- Diffusion d'un nouveau tour d'offres.
create or replace function secoto_private.od_broadcast(p_order_id uuid)
returns integer language plpgsql volatile security definer set search_path = ''
as $f$
declare
  v_order public.transport_orders%rowtype;
  v_quote public.transport_quotes%rowtype;
  v_count integer := 0;
  v_offer_id uuid;
  r record;
  v_ttl numeric := secoto_private.policy_num('offer_ttl_minutes', 30);
begin
  select * into v_order from public.transport_orders o where o.id = p_order_id for update;
  if v_order.status <> 'searching_partner' then return 0; end if;
  select * into v_quote from public.transport_quotes q where q.id = v_order.quote_id;

  update public.transport_offers set status = 'expired', responded_at = coalesce(responded_at, now())
   where order_id = p_order_id and status = 'sent';

  update public.transport_orders
     set dispatch_round = dispatch_round + 1,
         offers_expire_at = now() + make_interval(mins => v_ttl::int),
         updated_at = now()
   where id = p_order_id returning * into v_order;

  if not secoto_private.flag('dispatch_notifications') then
    -- Diffusion automatique coupée : l'administrateur attribue lui-même.
    perform secoto_private.notify_admins_event('new_request', 'Commande à attribuer',
      format('%s · %s → %s', v_order.public_ref, v_quote.pickup ->> 'city', v_quote.delivery ->> 'city'),
      'requests', 'order-dispatch-manual:' || v_order.id::text || ':' || v_order.dispatch_round, v_order.id);
    return 0;
  end if;

  for r in select a.id from public.accounts a where secoto_private.od_partner_eligible(a.id, p_order_id) loop
    insert into public.transport_offers(order_id, partner_id, round, partner_pay_cents, expires_at)
    values (p_order_id, r.id, v_order.dispatch_round, v_order.partner_pay_cents, v_order.offers_expire_at)
    on conflict (order_id, partner_id, round) do nothing
    returning id into v_offer_id;
    if v_offer_id is not null then
      v_count := v_count + 1;
      -- Corps in-app détaillé (session authentifiée). La copie push est
      -- recalculée par le serveur selon la confidentialité du partenaire.
      perform secoto_private.notify_event(r.id, 'mission_offer', 'Mission disponible',
        format('%s (%s) → %s (%s) · %s · %s € pour vous',
          v_quote.pickup ->> 'city', v_quote.pickup ->> 'postcode',
          v_quote.delivery ->> 'city', v_quote.delivery ->> 'postcode',
          v_quote.vehicle ->> 'model', to_char(v_order.partner_pay_cents / 100.0, 'FM999990D00')),
        null, 'offre', 'offer:' || v_offer_id::text, v_offer_id);
    end if;
  end loop;

  perform secoto_private.audit('order_broadcast', 'transport_order', p_order_id::text,
    jsonb_build_object('round', v_order.dispatch_round, 'offers', v_count));
  return v_count;
end;
$f$;

-- Passage en recherche de partenaire (paiement garanti ou forfait réservé).
create or replace function secoto_private.od_open_dispatch(p_order_id uuid)
returns void language plpgsql volatile security definer set search_path = ''
as $f$
begin
  update public.transport_orders set status = 'searching_partner', updated_at = now()
   where id = p_order_id and status = 'awaiting_payment';
  if found then
    perform secoto_private.od_broadcast(p_order_id);
  end if;
end;
$f$;

-- Réservation d'une commande sur un devis valide.
create or replace function public.secoto_od_book_quote(p_quote_id uuid, p_use_subscription boolean, p_idempotency_key uuid)
returns jsonb language plpgsql volatile security definer set search_path = ''
as $f$
declare
  v_user uuid := secoto_private.assert_authenticated();
  v_existing jsonb;
  v_quote public.transport_quotes%rowtype;
  v_order public.transport_orders%rowtype;
  v_payment public.payments%rowtype;
  v_strategy text;
  v_client_type text;
  v_hours numeric;
begin
  v_existing := secoto_private.lock_operation('od_book_quote', p_idempotency_key);
  if v_existing is not null then return v_existing; end if;

  select * into v_quote from public.transport_quotes q where q.id = p_quote_id for update;
  if not found or not (v_quote.account_id = v_user or (v_quote.business_id is not null and secoto_private.is_business_member(v_quote.business_id, v_user))) then
    raise exception 'Devis introuvable.' using errcode = 'P0002';
  end if;

  select * into v_order from public.transport_orders o where o.quote_id = p_quote_id;
  if found then
    return secoto_private.finish_operation('od_book_quote', p_idempotency_key,
      jsonb_build_object('order', secoto_private.order_client_json(v_order), 'already_booked', true));
  end if;

  if v_quote.status not in ('priced', 'manual_priced') then raise exception 'Ce devis ne peut pas être réservé (%).', v_quote.status; end if;
  if v_quote.valid_until <= now() then
    update public.transport_quotes set status = 'expired', updated_at = now() where id = p_quote_id;
    raise exception 'Ce devis a expiré. Recalculez le prix pour obtenir un devis à jour.';
  end if;
  if v_quote.pickup_at <= now() then raise exception 'La date de prise en charge est dépassée.'; end if;

  if coalesce(p_use_subscription, false) then
    if not secoto_private.flag('subscriptions') then raise exception 'Les abonnements ne sont pas encore ouverts.'; end if;
    v_strategy := 'subscription';
  else
    if not secoto_private.flag('od_payments') then
      raise exception 'Le paiement en ligne n''est pas encore ouvert : contactez SECOTO pour confirmer ce devis.';
    end if;
    v_hours := extract(epoch from (v_quote.pickup_at - now())) / 3600;
    -- Une autorisation carte expire au bout de ~7 jours : au-delà de la
    -- fenêtre, on encaisse et on rembourse intégralement si aucun partenaire.
    v_strategy := case when v_hours <= secoto_private.policy_num('authorization_window_hours', 144)
                       then 'authorize_then_capture' else 'capture_then_refund' end;
  end if;

  insert into public.transport_orders(public_ref, quote_id, account_id, business_id, mode, funding, status, payment_strategy,
    client_price_cents, partner_pay_cents, collect_cents, transport_direct_cents, pickup_at)
  values (secoto_private.new_order_ref(), v_quote.id, v_user, v_quote.business_id, v_quote.mode,
    case when v_strategy = 'subscription' then 'subscription' else 'card' end,
    'awaiting_payment', v_strategy, v_quote.client_price_cents, v_quote.partner_pay_cents,
    v_quote.collect_cents, v_quote.transport_direct_cents, v_quote.pickup_at)
  returning * into v_order;

  update public.transport_quotes set status = 'accepted', updated_at = now() where id = p_quote_id;

  if v_strategy = 'subscription' then
    perform secoto_private.sub_reserve_for_order(v_order.id);
    perform secoto_private.od_open_dispatch(v_order.id);
  else
    select case when a.client_type = 'particulier' then 'particulier' else 'pro' end into v_client_type
      from public.accounts a where a.id = v_user;
    insert into public.payments(mission_id, order_id, account_id, purpose, amount_cents, status, capture_method, waiver_required)
    values (null, v_order.id, v_user,
      case when v_order.mode = 'plateau' then 'od_plateau_commission' else 'od_convoyage' end,
      v_order.collect_cents, 'pending',
      case when v_strategy = 'authorize_then_capture' then 'manual' else 'automatic' end,
      -- Même règle que la commission plateau existante (mise en relation).
      v_order.mode = 'plateau' and coalesce(v_client_type, 'pro') = 'particulier')
    returning * into v_payment;
    update public.transport_orders set payment_id = v_payment.id where id = v_order.id returning * into v_order;
  end if;

  perform secoto_private.audit('order_booked', 'transport_order', v_order.id::text,
    jsonb_build_object('quote_id', p_quote_id, 'strategy', v_strategy));

  return secoto_private.finish_operation('od_book_quote', p_idempotency_key,
    jsonb_build_object('order', secoto_private.order_client_json(v_order), 'already_booked', false));
end;
$f$;

-- Remplacée par la migration 031 lorsque les abonnements sont installés.
create or replace function secoto_private.sub_reserve_for_order(p_order_id uuid)
returns void language plpgsql volatile security definer set search_path = ''
as $f$ begin raise exception 'Module abonnement non installé.'; end; $f$;
create or replace function secoto_private.sub_release_for_order(p_order_id uuid, p_reason text)
returns void language plpgsql volatile security definer set search_path = ''
as $f$ begin return; end; $f$;
create or replace function secoto_private.sub_consume_for_order(p_order_id uuid)
returns void language plpgsql volatile security definer set search_path = ''
as $f$ begin return; end; $f$;

-- Confirmation définitive : crée la mission et l'attribue, en une transaction.
create or replace function secoto_private.od_confirm(p_order_id uuid)
returns jsonb language plpgsql volatile security definer set search_path = ''
as $f$
declare
  v_order public.transport_orders%rowtype;
  v_quote public.transport_quotes%rowtype;
  v_partner public.accounts%rowtype;
  v_mission public.missions%rowtype;
begin
  select * into v_order from public.transport_orders o where o.id = p_order_id for update;
  if v_order.status in ('partner_confirmed', 'picked_up', 'delivered') then
    return jsonb_build_object('result', 'confirmed', 'mission_id', v_order.mission_id, 'partner_id', v_order.assigned_partner_id);
  end if;
  if v_order.status <> 'partner_locked' then
    return jsonb_build_object('result', 'not_locked', 'status', v_order.status);
  end if;
  select * into v_quote from public.transport_quotes q where q.id = v_order.quote_id;
  select * into v_partner from public.accounts a where a.id = v_order.lock_partner_id;

  -- Mission créée « publiée » puis attribuée dans la MÊME transaction : aucun
  -- tiers ne la voit publiée, et les déclencheurs d'attribution existants
  -- (documents, notifications) s'exécutent comme pour une attribution admin.
  insert into public.missions(public_ref, type, status, from_city, to_city, pickup_address, delivery_address,
    mission_date, vehicle, distance_km, client_name, client_contact, client_phone, notes,
    created_by_role, client_account_id, vehicle_category, manual_pricing, manual_carrier_pay, manual_margin,
    payment_status, payment_method)
  select secoto_private.new_public_ref('MIS'), v_order.mode, 'published',
    v_quote.pickup ->> 'city', v_quote.delivery ->> 'city', v_quote.pickup ->> 'label', v_quote.delivery ->> 'label',
    v_order.pickup_at, left(v_quote.vehicle ->> 'model', 120), (v_quote.route ->> 'distance_km')::numeric,
    coalesce(a.company_name, a.full_name), a.email, a.phone,
    left(concat_ws(' · ', 'Commande ' || v_order.public_ref,
      'Créneau ' || (v_quote.schedule ->> 'slot'),
      case when (v_quote.schedule ->> 'flexibility_days')::int > 0 then 'Souplesse ' || (v_quote.schedule ->> 'flexibility_days') || ' j' end,
      case when not coalesce((v_quote.vehicle ->> 'rolling')::boolean, true) then 'NON ROULANT' end,
      nullif(v_quote.vehicle ->> 'notes', '')), 2000),
    'client', v_order.account_id, coalesce(v_quote.vehicle ->> 'category', 'standard'),
    true, v_order.partner_pay_cents / 100.0, (v_order.client_price_cents - v_order.partner_pay_cents) / 100.0,
    case when v_order.funding = 'subscription' then 'not_required'
         when (select p.status from public.payments p where p.id = v_order.payment_id) = 'paid' then 'paid'
         else 'awaiting_payment' end,
    case when v_order.funding = 'subscription' then 'abonnement' else 'carte' end
  from public.accounts a where a.id = v_order.account_id
  returning * into v_mission;

  update public.missions
     set status = 'assigned', progress_status = 'assigned_pending',
         assigned_transporter_id = v_partner.id,
         assigned_transporter_name = coalesce(v_partner.company_name, v_partner.full_name)
   where id = v_mission.id returning * into v_mission;

  update public.transport_orders
     set status = 'partner_confirmed', assigned_partner_id = v_partner.id, mission_id = v_mission.id,
         confirmed_at = now(), lock_expires_at = null, updated_at = now()
   where id = p_order_id returning * into v_order;

  update public.transport_offers set status = 'accepted', responded_at = coalesce(responded_at, now())
   where id = v_order.lock_offer_id;
  update public.transport_offers set status = 'lost', responded_at = coalesce(responded_at, now())
   where order_id = p_order_id and status = 'sent';
  if v_order.payment_id is not null then
    update public.payments set mission_id = v_mission.id, updated_at = now() where id = v_order.payment_id;
  end if;
  perform secoto_private.sub_attach_mission(p_order_id, v_mission.id);

  perform secoto_private.notify_event(v_partner.id, 'course_assigned', 'Mission confirmée',
    format('%s → %s · %s', v_quote.pickup ->> 'city', v_quote.delivery ->> 'city', v_quote.vehicle ->> 'model'),
    v_mission.id, 'assigned', 'od-confirmed:partner:' || p_order_id::text, p_order_id);
  perform secoto_private.notify_event(v_order.account_id, 'course_assigned', 'Transporteur confirmé',
    format('Commande %s : un partenaire SECOTO prend en charge votre véhicule.', v_order.public_ref),
    v_mission.id, 'courses', 'od-confirmed:client:' || p_order_id::text, p_order_id);
  perform secoto_private.audit('order_confirmed', 'transport_order', p_order_id::text,
    jsonb_build_object('mission_id', v_mission.id, 'partner_id', v_partner.id));
  return jsonb_build_object('result', 'confirmed', 'mission_id', v_mission.id, 'partner_id', v_partner.id);
end;
$f$;

create or replace function secoto_private.sub_attach_mission(p_order_id uuid, p_mission_id uuid)
returns void language plpgsql volatile security definer set search_path = ''
as $f$ begin return; end; $f$;

-- Libère un verrou dont la capture a échoué ou expiré : la commande repart en
-- recherche, sans mission confirmée.
create or replace function secoto_private.od_release_lock(p_order_id uuid, p_reason text)
returns void language plpgsql volatile security definer set search_path = ''
as $f$
declare v_order public.transport_orders%rowtype;
begin
  select * into v_order from public.transport_orders o where o.id = p_order_id for update;
  if v_order.status <> 'partner_locked' then return; end if;
  update public.transport_offers set status = 'voided', responded_at = now() where id = v_order.lock_offer_id and status in ('sent', 'accepted');
  update public.transport_orders
     set status = 'searching_partner', lock_partner_id = null, lock_offer_id = null, lock_expires_at = null, updated_at = now()
   where id = p_order_id;
  perform secoto_private.notify_event(v_order.lock_partner_id, 'order_update', 'Mission non confirmée',
    'Le paiement du client n''a pas pu être finalisé : cette mission n''est pas confirmée. Aucune pénalité.',
    null, 'offre', 'od-lock-released:' || p_order_id::text || ':' || coalesce(v_order.lock_offer_id::text, ''), v_order.lock_offer_id);
  perform secoto_private.audit('order_lock_released', 'transport_order', p_order_id::text, jsonb_build_object('reason', p_reason));
end;
$f$;

-- ----------------------------------------------------------------------------
-- 10.1 Acceptation / refus par le partenaire — ATOMIQUE
-- ----------------------------------------------------------------------------
create or replace function secoto_private.od_try_accept(p_order_id uuid, p_offer_id uuid, p_partner uuid)
returns jsonb language plpgsql volatile security definer set search_path = ''
as $f$
declare
  v_order public.transport_orders%rowtype;
  v_offer public.transport_offers%rowtype;
  v_payment_status text;
begin
  -- Le verrou de ligne sérialise TOUTES les acceptations d'une même commande.
  select * into v_order from public.transport_orders o where o.id = p_order_id for update;
  select * into v_offer from public.transport_offers x where x.id = p_offer_id;

  if v_order.status in ('partner_confirmed', 'picked_up', 'delivered') then
    if v_order.assigned_partner_id = p_partner then
      return jsonb_build_object('result', 'confirmed', 'mission_id', v_order.mission_id);
    end if;
    update public.transport_offers set status = 'lost', responded_at = coalesce(responded_at, now()) where id = p_offer_id and status = 'sent';
    return jsonb_build_object('result', 'already_assigned');
  end if;
  if v_order.status = 'partner_locked' then
    if v_order.lock_partner_id = p_partner then
      return jsonb_build_object('result', 'pending_capture', 'payment_id', v_order.payment_id, 'order_id', v_order.id);
    end if;
    return jsonb_build_object('result', 'already_assigned');
  end if;
  if v_order.status <> 'searching_partner' then
    return jsonb_build_object('result', 'unavailable');
  end if;
  if v_offer.status <> 'sent' or v_offer.expires_at <= now() or v_offer.round <> v_order.dispatch_round then
    return jsonb_build_object('result', 'expired');
  end if;
  if not secoto_private.od_partner_eligible(p_partner, p_order_id) then
    return jsonb_build_object('result', 'not_eligible');
  end if;

  if v_order.funding = 'card' then
    select p.status into v_payment_status from public.payments p where p.id = v_order.payment_id;
  end if;

  update public.transport_orders
     set status = 'partner_locked', lock_partner_id = p_partner, lock_offer_id = p_offer_id,
         lock_expires_at = now() + make_interval(secs => secoto_private.policy_num('capture_lock_seconds', 120)::int),
         updated_at = now()
   where id = p_order_id;
  update public.transport_offers set responded_at = now() where id = p_offer_id;

  if v_order.funding = 'subscription' or v_payment_status = 'paid' then
    return secoto_private.od_confirm(p_order_id);
  elsif v_payment_status = 'requires_capture' then
    return jsonb_build_object('result', 'pending_capture', 'payment_id', v_order.payment_id, 'order_id', v_order.id);
  end if;
  -- Paiement ni autorisé ni encaissé : on n'attribue pas.
  perform secoto_private.od_release_lock(p_order_id, 'payment_not_guaranteed');
  return jsonb_build_object('result', 'unavailable');
end;
$f$;

create or replace function public.secoto_offer_accept(p_offer_id uuid, p_idempotency_key uuid)
returns jsonb language plpgsql volatile security definer set search_path = ''
as $f$
declare
  v_user uuid := secoto_private.assert_authenticated();
  v_offer public.transport_offers%rowtype;
  v_result jsonb;
begin
  select * into v_offer from public.transport_offers x where x.id = p_offer_id and x.partner_id = v_user;
  if not found then raise exception 'Proposition introuvable.' using errcode = 'P0002'; end if;
  -- Rejeu : la même clé renvoie la même réponse, sans nouvel effet.
  v_result := secoto_private.lock_operation('offer_accept', p_idempotency_key);
  if v_result is not null and v_result ->> 'result' not in ('pending_capture') then return v_result; end if;
  v_result := secoto_private.od_try_accept(v_offer.order_id, p_offer_id, v_user);
  if v_result ->> 'result' in ('confirmed', 'already_assigned', 'expired', 'unavailable', 'not_eligible') then
    perform secoto_private.finish_operation('offer_accept', p_idempotency_key, v_result);
  end if;
  return v_result;
end;
$f$;

create or replace function public.secoto_offer_decline(p_offer_id uuid)
returns jsonb language plpgsql volatile security definer set search_path = ''
as $f$
declare v_user uuid := secoto_private.assert_authenticated();
begin
  -- Un refus n'a AUCUNE conséquence sur le compte : il n'est ni compté ni noté.
  update public.transport_offers set status = 'declined', responded_at = now()
   where id = p_offer_id and partner_id = v_user and status = 'sent';
  return jsonb_build_object('result', case when found then 'declined' else 'no_change' end);
end;
$f$;

create or replace function public.secoto_offer_mark_seen(p_offer_id uuid)
returns void language sql volatile security definer set search_path = ''
as $f$ update public.transport_offers set seen_at = coalesce(seen_at, now()) where id = p_offer_id and partner_id = auth.uid(); $f$;

-- Projection PARTENAIRE : jamais le prix client ni la marge, jamais les
-- coordonnées du client avant confirmation.
create or replace function secoto_private.offer_partner_json(x public.transport_offers)
returns jsonb language sql stable security definer set search_path = ''
as $f$
  select jsonb_build_object(
    'id', x.id, 'order_ref', o.public_ref, 'mode', o.mode,
    'state', case
      when o.assigned_partner_id = x.partner_id then 'confirmed'
      when o.status = 'partner_locked' and o.lock_partner_id = x.partner_id then 'pending_capture'
      when o.status in ('partner_locked', 'partner_confirmed', 'picked_up', 'delivered') then 'already_assigned'
      when o.status in ('cancelled', 'no_partner') then 'unavailable'
      when x.status = 'declined' then 'declined'
      when x.status in ('expired', 'voided', 'withdrawn', 'lost') or x.expires_at <= now() or x.round <> o.dispatch_round then 'expired'
      else 'available' end,
    'partner_pay_cents', x.partner_pay_cents,
    'expires_at', x.expires_at,
    'pickup', jsonb_build_object('label', q.pickup ->> 'label', 'city', q.pickup ->> 'city', 'postcode', q.pickup ->> 'postcode'),
    'delivery', jsonb_build_object('label', q.delivery ->> 'label', 'city', q.delivery ->> 'city', 'postcode', q.delivery ->> 'postcode'),
    'distance_km', q.route -> 'distance_km', 'duration_min', q.route -> 'duration_min',
    'vehicle', q.vehicle, 'schedule', q.schedule, 'pickup_at', o.pickup_at,
    'partner_included', case when o.mode = 'convoyage'
      then jsonb_build_array('Frais réels (carburant, péages) remboursés sur justificatifs validés')
      else jsonb_build_array('Péages inclus dans votre rémunération') end,
    'partner_excluded', case when o.mode = 'convoyage'
      then jsonb_build_array('Retour après livraison : à votre charge')
      else jsonb_build_array('Transport réglé directement par le client, selon le bon de mission') end,
    'mission_id', case when o.assigned_partner_id = x.partner_id then o.mission_id end)
  from public.transport_orders o join public.transport_quotes q on q.id = o.quote_id
  where o.id = x.order_id;
$f$;

create or replace function public.secoto_offer_get(p_offer_id uuid)
returns jsonb language sql stable security definer set search_path = ''
as $f$ select secoto_private.offer_partner_json(x) from public.transport_offers x where x.id = p_offer_id and x.partner_id = auth.uid(); $f$;

create or replace function public.secoto_my_offers()
returns jsonb language sql stable security definer set search_path = ''
as $f$
  select coalesce(jsonb_agg(secoto_private.offer_partner_json(x) order by x.created_at desc), '[]'::jsonb)
  from public.transport_offers x
  where x.partner_id = auth.uid() and x.created_at > now() - interval '7 days';
$f$;

-- ----------------------------------------------------------------------------
-- 10.2 Résultat de capture (serveur) et événements de paiement (webhook)
-- ----------------------------------------------------------------------------
create or replace function public.secoto_od_capture_result(p_order_id uuid, p_success boolean, p_error text)
returns jsonb language plpgsql volatile security definer set search_path = ''
as $f$
declare v_order public.transport_orders%rowtype;
begin
  select * into v_order from public.transport_orders o where o.id = p_order_id for update;
  if not found then raise exception 'Commande introuvable.'; end if;
  if p_success then
    update public.payments set status = 'paid', captured_at = coalesce(captured_at, now()), paid_at = coalesce(paid_at, now()), updated_at = now()
     where id = v_order.payment_id and status in ('requires_capture', 'processing', 'paid');
    return secoto_private.od_confirm(p_order_id);
  end if;
  update public.payments set status = 'capture_failed', last_error = left(coalesce(p_error, 'capture_failed'), 500), updated_at = now()
   where id = v_order.payment_id and status = 'requires_capture';
  perform secoto_private.od_release_lock(p_order_id, 'capture_failed');
  perform secoto_private.notify_event(v_order.account_id, 'payment_failed', 'Paiement à mettre à jour',
    format('Commande %s : l''encaissement a échoué au moment de l''attribution. Aucun transport n''est confirmé. Mettez à jour votre moyen de paiement.', v_order.public_ref),
    null, 'paiement', 'od-capture-failed:' || p_order_id::text || ':' || extract(epoch from now())::bigint, p_order_id);
  perform secoto_private.notify_admins_event('order_update', 'Échec de capture',
    format('Commande %s : capture refusée (%s).', v_order.public_ref, left(coalesce(p_error, ''), 120)),
    'requests', 'od-capture-failed-admin:' || p_order_id::text || ':' || extract(epoch from now())::bigint, p_order_id);
  return jsonb_build_object('result', 'capture_failed');
end;
$f$;

-- Verrou expiré sans paiement à capturer (forfait, ou intent absent) : libération simple.
create or replace function public.secoto_od_expire_lock(p_order_id uuid)
returns jsonb language plpgsql volatile security definer set search_path = ''
as $f$
declare v_order public.transport_orders%rowtype;
begin
  select * into v_order from public.transport_orders o where o.id = p_order_id for update;
  if v_order.status = 'partner_locked' and v_order.lock_expires_at <= now() then
    if v_order.funding = 'subscription' then
      return secoto_private.od_confirm(p_order_id);
    end if;
    perform secoto_private.od_release_lock(p_order_id, 'lock_expired');
    return jsonb_build_object('result', 'released');
  end if;
  return jsonb_build_object('result', 'no_change', 'status', v_order.status);
end;
$f$;

-- Machine d'état MONOTONE : un événement rejoué ou reçu dans le désordre ne
-- fait jamais régresser un paiement (ex. « autorisé » après « encaissé »).
create or replace function public.secoto_od_apply_payment_event(
  p_payment_id uuid, p_event_id text, p_event_type text, p_intent_id text,
  p_amount_refunded_cents integer, p_capture_before timestamptz, p_error text
)
returns jsonb language plpgsql volatile security definer set search_path = ''
as $f$
declare
  v_payment public.payments%rowtype;
  v_order public.transport_orders%rowtype;
  v_new text;
  v_effect text := 'none';
begin
  select * into v_payment from public.payments p where p.id = p_payment_id for update;
  if not found then return jsonb_build_object('skipped', true, 'reason', 'unknown_payment'); end if;
  if v_payment.purpose not in ('od_convoyage', 'od_plateau_commission', 'subscription_extension') then
    return jsonb_build_object('skipped', true, 'reason', 'legacy_purpose');
  end if;
  if p_event_id is not null and exists (select 1 from public.payment_events e where e.provider_event_id = p_event_id) then
    return jsonb_build_object('skipped', true, 'reason', 'event_already_processed');
  end if;

  v_new := v_payment.status;
  case p_event_type
    when 'payment_intent.amount_capturable_updated' then
      if v_payment.status in ('pending', 'processing', 'failed') then v_new := 'requires_capture'; end if;
    when 'payment_intent.succeeded' then
      if v_payment.status in ('pending', 'processing', 'failed', 'requires_capture', 'capture_failed') then v_new := 'paid'; end if;
    when 'payment_intent.payment_failed' then
      if v_payment.status in ('pending', 'processing') then v_new := 'failed'; end if;
    when 'payment_intent.canceled' then
      if v_payment.status in ('pending', 'processing', 'requires_capture', 'capture_failed', 'failed') then v_new := 'cancelled'; end if;
    when 'charge.refunded' then
      if coalesce(p_amount_refunded_cents, 0) >= v_payment.amount_cents then v_new := 'refunded'; end if;
    when 'charge.dispute.created' then null;
    when 'charge.dispute.closed' then null;
    else
      return jsonb_build_object('skipped', true, 'reason', 'event_type_ignored');
  end case;

  update public.payments set
    status = v_new,
    provider_intent_id = coalesce(provider_intent_id, p_intent_id),
    authorized_at = case when v_new = 'requires_capture' then coalesce(authorized_at, now()) else authorized_at end,
    capture_before = coalesce(p_capture_before, capture_before),
    captured_at = case when v_new = 'paid' then coalesce(captured_at, now()) else captured_at end,
    paid_at = case when v_new = 'paid' then coalesce(paid_at, now()) else paid_at end,
    failed_at = case when v_new = 'failed' then now() else failed_at end,
    released_at = case when v_new = 'cancelled' then coalesce(released_at, now()) else released_at end,
    refunded_amount_cents = greatest(refunded_amount_cents, coalesce(p_amount_refunded_cents, 0)),
    dispute_status = case p_event_type when 'charge.dispute.created' then 'open' when 'charge.dispute.closed' then 'closed' else dispute_status end,
    last_error = case when v_new = 'failed' then left(coalesce(p_error, ''), 500) else last_error end,
    last_event_at = now(), updated_at = now()
  where id = p_payment_id returning * into v_payment;

  insert into public.payment_events(payment_id, event_type, provider_event_id, payload)
  values (p_payment_id, p_event_type, p_event_id, jsonb_build_object('intent', p_intent_id, 'status', v_new, 'refunded', p_amount_refunded_cents, 'error', p_error))
  on conflict (provider_event_id) where provider_event_id is not null do nothing;

  if v_payment.order_id is not null then
    select * into v_order from public.transport_orders o where o.id = v_payment.order_id for update;
    if v_new in ('requires_capture', 'paid') and v_order.status = 'awaiting_payment' then
      perform secoto_private.od_open_dispatch(v_order.id);
      v_effect := 'dispatch_opened';
      perform secoto_private.notify_event(v_order.account_id, 'payment',
        case when v_new = 'paid' then 'Paiement encaissé' else 'Paiement autorisé' end,
        case when v_new = 'paid'
          then format('Commande %s : paiement encaissé. Nous recherchons un partenaire ; sans attribution, remboursement intégral.', v_order.public_ref)
          else format('Commande %s : paiement autorisé, rien n''est débité tant qu''un partenaire n''a pas confirmé.', v_order.public_ref) end,
        null, 'courses', 'od-payment-ok:' || v_order.id::text, v_order.id);
    elsif v_new = 'paid' and v_order.status = 'partner_locked' then
      perform secoto_private.od_confirm(v_order.id);
      v_effect := 'confirmed';
    elsif v_new = 'cancelled' and v_order.status in ('awaiting_payment', 'searching_partner', 'partner_locked') then
      -- Autorisation libérée ou expirée sans attribution : la commande s'arrête.
      update public.transport_offers set status = 'withdrawn', responded_at = now() where order_id = v_order.id and status = 'sent';
      update public.transport_orders set status = 'cancelled', cancelled_at = now(),
        cancel_reason = coalesce(cancel_reason, 'autorisation_de_paiement_liberee'), lock_expires_at = null, updated_at = now()
       where id = v_order.id;
      v_effect := 'order_cancelled';
    elsif v_new = 'failed' then
      perform secoto_private.notify_event(v_order.account_id, 'payment_failed', 'Paiement refusé',
        format('Commande %s : le paiement n''a pas abouti. Aucune demande n''est diffusée.', v_order.public_ref),
        null, 'paiement', 'od-payment-failed:' || p_payment_id::text || ':' || coalesce(p_event_id, ''), v_order.id);
    end if;
  end if;

  if p_event_type = 'charge.dispute.created' then
    perform secoto_private.notify_admins_event('payment_failed', 'Contestation bancaire',
      format('Paiement %s contesté.', p_payment_id), 'paiement', 'dispute:' || p_payment_id::text, p_payment_id);
  end if;
  return jsonb_build_object('payment_id', p_payment_id, 'status', v_new, 'effect', v_effect);
end;
$f$;

-- ----------------------------------------------------------------------------
-- 10.3 Annulation client, maintenance, actions de paiement à exécuter
-- ----------------------------------------------------------------------------
create or replace function secoto_private.od_stop_order(p_order_id uuid, p_status text, p_reason text)
returns void language plpgsql volatile security definer set search_path = ''
as $f$
declare v_order public.transport_orders%rowtype;
begin
  select * into v_order from public.transport_orders o where o.id = p_order_id for update;
  update public.transport_offers set status = 'withdrawn', responded_at = now() where order_id = p_order_id and status = 'sent';
  update public.transport_orders set status = p_status, cancelled_at = case when p_status = 'cancelled' then now() else cancelled_at end,
    cancel_reason = p_reason, lock_partner_id = null, lock_offer_id = null, lock_expires_at = null, updated_at = now()
   where id = p_order_id;
  if v_order.funding = 'subscription' then
    -- Faute de partenaire, ou annulée avant attribution : le forfait n'est pas consommé.
    perform secoto_private.sub_release_for_order(p_order_id, p_reason);
  elsif v_order.payment_id is not null then
    -- Libération (autorisation) ou remboursement intégral (encaissement) :
    -- exécutés par la fonction serveur « od-maintenance » via Stripe.
    update public.payments set release_requested_at = coalesce(release_requested_at, now()),
      refund_reason = coalesce(refund_reason, p_reason),
      status = case when status = 'paid' then 'refund_pending' else status end,
      refund_requested_at = case when status = 'paid' then coalesce(refund_requested_at, now()) else refund_requested_at end,
      updated_at = now()
     where id = v_order.payment_id and status in ('pending', 'processing', 'requires_capture', 'capture_failed', 'paid');
  end if;
end;
$f$;

create or replace function public.secoto_od_cancel_order(p_order_id uuid, p_idempotency_key uuid)
returns jsonb language plpgsql volatile security definer set search_path = ''
as $f$
declare
  v_user uuid := secoto_private.assert_authenticated();
  v_existing jsonb;
  v_order public.transport_orders%rowtype;
begin
  v_existing := secoto_private.lock_operation('od_cancel_order', p_idempotency_key);
  if v_existing is not null then return v_existing; end if;
  select * into v_order from public.transport_orders o where o.id = p_order_id for update;
  if not found or not (v_order.account_id = v_user or (v_order.business_id is not null and secoto_private.is_business_member(v_order.business_id, v_user))) then
    raise exception 'Commande introuvable.' using errcode = 'P0002';
  end if;
  if v_order.status = 'partner_locked' then
    raise exception 'Un partenaire est en cours de confirmation : réessayez dans deux minutes.';
  end if;
  if v_order.status in ('partner_confirmed', 'picked_up') then
    raise exception 'Le transport est confirmé : contactez SECOTO, les conditions d''annulation s''appliquent.';
  end if;
  if v_order.status in ('cancelled', 'delivered') then
    return secoto_private.finish_operation('od_cancel_order', p_idempotency_key, secoto_private.order_client_json(v_order));
  end if;
  perform secoto_private.od_stop_order(p_order_id, 'cancelled', 'annulation_client_avant_attribution');
  perform secoto_private.audit('order_cancelled_by_client', 'transport_order', p_order_id::text, '{}'::jsonb);
  select * into v_order from public.transport_orders o where o.id = p_order_id;
  return secoto_private.finish_operation('od_cancel_order', p_idempotency_key, secoto_private.order_client_json(v_order));
end;
$f$;

-- Exécutée chaque minute par la fonction Netlify « od-maintenance ».
create or replace function public.secoto_od_maintenance_tick()
returns jsonb language plpgsql volatile security definer set search_path = ''
as $f$
declare
  r record;
  v_rounds integer := secoto_private.policy_num('max_rounds', 3)::int;
  v_rebroadcast integer := 0; v_no_partner integer := 0; v_expired_quotes integer := 0;
  v_locks jsonb := '[]'::jsonb;
  v_actions jsonb;
begin
  update public.transport_quotes set status = 'expired', updated_at = now()
   where status in ('priced', 'manual_priced') and valid_until <= now();
  get diagnostics v_expired_quotes = row_count;

  update public.transport_offers set status = 'expired' where status = 'sent' and expires_at <= now();

  for r in select o.id, o.dispatch_round, o.pickup_at, o.account_id, o.public_ref from public.transport_orders o
            where o.status = 'searching_partner' and o.offers_expire_at <= now()
            for update skip locked loop
    if r.dispatch_round >= v_rounds or r.pickup_at <= now() then
      perform secoto_private.od_stop_order(r.id, 'no_partner', 'aucun_partenaire_disponible');
      perform secoto_private.notify_event(r.account_id, 'order_update', 'Aucun partenaire disponible',
        format('Commande %s : aucun partenaire n''a pu confirmer. Votre paiement est libéré ou remboursé intégralement.', r.public_ref),
        null, 'courses', 'od-no-partner:' || r.id::text, r.id);
      perform secoto_private.notify_admins_event('order_update', 'Commande sans partenaire',
        r.public_ref, 'requests', 'od-no-partner-admin:' || r.id::text, r.id);
      v_no_partner := v_no_partner + 1;
    else
      perform secoto_private.od_broadcast(r.id);
      v_rebroadcast := v_rebroadcast + 1;
    end if;
  end loop;

  -- Verrous expirés : le serveur vérifie l'état réel chez Stripe avant de trancher.
  select coalesce(jsonb_agg(jsonb_build_object('order_id', o.id, 'payment_id', o.payment_id, 'intent_id', p.provider_intent_id, 'funding', o.funding)), '[]'::jsonb)
    into v_locks
    from public.transport_orders o left join public.payments p on p.id = o.payment_id
   where o.status = 'partner_locked' and o.lock_expires_at <= now();

  select coalesce(jsonb_agg(jsonb_build_object('payment_id', p.id, 'intent_id', p.provider_intent_id, 'status', p.status,
      'action', case when p.status = 'refund_pending' then 'refund' else 'cancel' end,
      'amount_cents', p.amount_cents - p.refunded_amount_cents)), '[]'::jsonb)
    into v_actions
    from public.payments p
   where p.purpose in ('od_convoyage', 'od_plateau_commission', 'subscription_extension')
     and p.release_requested_at is not null and p.status in ('pending', 'processing', 'requires_capture', 'capture_failed', 'refund_pending');

  return jsonb_build_object('expired_quotes', v_expired_quotes, 'rebroadcast', v_rebroadcast, 'no_partner', v_no_partner,
    'expired_locks', v_locks, 'payment_actions', v_actions);
end;
$f$;

-- Résultat d'une action de libération / remboursement exécutée chez Stripe.
create or replace function public.secoto_od_payment_action_result(p_payment_id uuid, p_action text, p_success boolean, p_error text)
returns void language plpgsql volatile security definer set search_path = ''
as $f$
begin
  if p_success then
    update public.payments set
      status = case when p_action = 'refund' then 'refunded' else 'cancelled' end,
      refunded_amount_cents = case when p_action = 'refund' then amount_cents else refunded_amount_cents end,
      released_at = case when p_action = 'cancel' then coalesce(released_at, now()) else released_at end,
      release_requested_at = null, updated_at = now()
    where id = p_payment_id and status in ('pending', 'processing', 'requires_capture', 'capture_failed', 'refund_pending');
    -- Aucun intent créé : rien à libérer chez Stripe.
  else
    update public.payments set last_error = left(coalesce(p_error, p_action || '_failed'), 500), updated_at = now() where id = p_payment_id;
  end if;
end;
$f$;

-- ----------------------------------------------------------------------------
-- 10.4 Administration des commandes
-- ----------------------------------------------------------------------------
create or replace function public.secoto_admin_od_orders(p_status text default null)
returns jsonb language plpgsql stable security definer set search_path = ''
as $f$
begin
  perform secoto_private.assert_admin();
  return coalesce((
    select jsonb_agg(secoto_private.order_client_json(o) || jsonb_build_object(
      'partner_pay_cents', o.partner_pay_cents,
      'margin_cents', o.client_price_cents - o.partner_pay_cents,
      'dispatch_round', o.dispatch_round, 'offers_expire_at', o.offers_expire_at,
      'lock_partner_id', o.lock_partner_id, 'lock_expires_at', o.lock_expires_at,
      'client_name', (select coalesce(a.company_name, a.full_name) from public.accounts a where a.id = o.account_id),
      'offers', (select jsonb_build_object(
          'sent', count(*) filter (where x.status = 'sent' and x.round = o.dispatch_round),
          'seen', count(*) filter (where x.seen_at is not null and x.round = o.dispatch_round),
          'declined', count(*) filter (where x.status = 'declined'),
          'unanswered', count(*) filter (where x.status = 'expired'))
        from public.transport_offers x where x.order_id = o.id),
      'refund_pending', (select p.status = 'refund_pending' or p.release_requested_at is not null from public.payments p where p.id = o.payment_id),
      'dispute', (select p.dispute_status from public.payments p where p.id = o.payment_id))
      order by o.created_at desc)
    from public.transport_orders o where p_status is null or o.status = p_status), '[]'::jsonb);
end;
$f$;

create or replace function public.secoto_admin_od_rebroadcast(p_order_id uuid)
returns jsonb language plpgsql volatile security definer set search_path = ''
as $f$
declare v_order public.transport_orders%rowtype; v_count int;
begin
  perform secoto_private.assert_admin();
  select * into v_order from public.transport_orders o where o.id = p_order_id for update;
  if v_order.status = 'no_partner' then
    -- Relance possible seulement si le paiement ou le forfait est toujours valable.
    if v_order.funding = 'card' and not exists (select 1 from public.payments p where p.id = v_order.payment_id and p.status in ('requires_capture', 'paid') and p.release_requested_at is null) then
      raise exception 'Le paiement a été libéré : le client doit réserver à nouveau.';
    end if;
    if v_order.funding = 'subscription' then perform secoto_private.sub_reserve_for_order(p_order_id); end if;
    update public.transport_orders set status = 'searching_partner', dispatch_round = 0, cancel_reason = null, updated_at = now() where id = p_order_id;
  elsif v_order.status <> 'searching_partner' then
    raise exception 'Relance impossible au statut %.', v_order.status;
  end if;
  v_count := secoto_private.od_broadcast(p_order_id);
  perform secoto_private.audit('order_rebroadcast_admin', 'transport_order', p_order_id::text, jsonb_build_object('offers', v_count));
  return jsonb_build_object('offers', v_count);
end;
$f$;

-- Hausse de rémunération après validation du prix client : dans la marge
-- disponible au-delà du seuil, sinon dérogation explicite et tracée.
create or replace function public.secoto_admin_od_set_partner_pay(p_order_id uuid, p_partner_pay_cents integer, p_override boolean, p_note text)
returns jsonb language plpgsql volatile security definer set search_path = ''
as $f$
declare
  v_order public.transport_orders%rowtype;
  v_min_pct numeric := secoto_private.policy_num('min_margin_pct_without_admin', 15);
  v_margin integer;
begin
  perform secoto_private.assert_admin();
  select * into v_order from public.transport_orders o where o.id = p_order_id for update;
  if v_order.status not in ('searching_partner', 'no_partner') then raise exception 'Rémunération modifiable uniquement pendant la recherche.'; end if;
  if v_order.mode = 'plateau' then
    raise exception 'Plateau : le tarif transporteur est réglé par le client ; établissez un nouveau devis.';
  end if;
  if coalesce(p_partner_pay_cents, -1) < 0 then raise exception 'Montant invalide.'; end if;
  v_margin := v_order.client_price_cents - p_partner_pay_cents;
  if v_margin < 0 then raise exception 'La rémunération dépasse le prix payé par le client.'; end if;
  if v_margin < v_order.client_price_cents * v_min_pct / 100 and not coalesce(p_override, false) then
    raise exception 'Marge restante inférieure au seuil de % %% : validation administrateur explicite requise.', v_min_pct;
  end if;
  if coalesce(p_override, false) and length(btrim(coalesce(p_note, ''))) < 5 then
    raise exception 'Justifiez la dérogation.';
  end if;
  update public.transport_orders set partner_pay_cents = p_partner_pay_cents, updated_at = now() where id = p_order_id;
  perform secoto_private.audit('order_partner_pay_changed', 'transport_order', p_order_id::text, jsonb_build_object(
    'from', v_order.partner_pay_cents, 'to', p_partner_pay_cents, 'margin_cents', v_margin, 'override', coalesce(p_override, false), 'note', p_note));
  if v_order.status = 'searching_partner' then perform secoto_private.od_broadcast(p_order_id); end if;
  return jsonb_build_object('partner_pay_cents', p_partner_pay_cents, 'margin_cents', v_margin);
end;
$f$;

-- Attribution manuelle par l'administrateur : même verrou, même capture.
create or replace function public.secoto_admin_od_lock_for_partner(p_order_id uuid, p_partner_id uuid)
returns jsonb language plpgsql volatile security definer set search_path = ''
as $f$
declare v_order public.transport_orders%rowtype; v_offer_id uuid; v_result jsonb;
begin
  perform secoto_private.assert_admin();
  select * into v_order from public.transport_orders o where o.id = p_order_id for update;
  if v_order.status <> 'searching_partner' then raise exception 'Commande non disponible (%).', v_order.status; end if;
  insert into public.transport_offers(order_id, partner_id, round, partner_pay_cents, expires_at)
  values (p_order_id, p_partner_id, v_order.dispatch_round, v_order.partner_pay_cents, now() + interval '10 minutes')
  on conflict (order_id, partner_id, round) do update set status = 'sent', expires_at = excluded.expires_at
  returning id into v_offer_id;
  -- L'éligibilité (documents, type, statut) reste exigée, sauf disponibilité déclarée.
  if not exists (select 1 from public.accounts a where a.id = p_partner_id and a.role::text = 'transporter' and a.status::text = 'active'
                 and coalesce(a.is_verified, false) and secoto_private.partner_documents_valid(a.id)) then
    raise exception 'Partenaire non vérifié ou documents expirés.';
  end if;
  insert into public.partner_dispatch_preferences(account_id) values (p_partner_id) on conflict do nothing;
  update public.transport_orders set status = 'partner_locked', lock_partner_id = p_partner_id, lock_offer_id = v_offer_id,
    lock_expires_at = now() + make_interval(secs => secoto_private.policy_num('capture_lock_seconds', 120)::int), updated_at = now()
   where id = p_order_id;
  perform secoto_private.audit('order_locked_by_admin', 'transport_order', p_order_id::text, jsonb_build_object('partner_id', p_partner_id));
  if v_order.funding = 'subscription' or exists (select 1 from public.payments p where p.id = v_order.payment_id and p.status = 'paid') then
    return secoto_private.od_confirm(p_order_id);
  end if;
  return jsonb_build_object('result', 'pending_capture', 'order_id', p_order_id, 'payment_id', v_order.payment_id);
end;
$f$;

-- Remplacement d'un partenaire confirmé (avant récupération du véhicule).
create or replace function public.secoto_admin_od_replace_partner(p_order_id uuid, p_reason text)
returns jsonb language plpgsql volatile security definer set search_path = ''
as $f$
declare v_order public.transport_orders%rowtype;
begin
  perform secoto_private.assert_admin();
  if length(btrim(coalesce(p_reason, ''))) < 5 then raise exception 'Motif requis.'; end if;
  select * into v_order from public.transport_orders o where o.id = p_order_id for update;
  if v_order.status <> 'partner_confirmed' then raise exception 'Remplacement possible uniquement avant la récupération du véhicule.'; end if;
  -- L'ancienne mission est annulée (le suivi GPS s'arrête par déclencheur) ;
  -- une nouvelle mission sera créée à la prochaine confirmation.
  update public.missions set status = 'cancelled', cancelled_at = now(), cancellation_reason = left('Remplacement partenaire : ' || p_reason, 500)
   where id = v_order.mission_id;
  perform secoto_private.notify_event(v_order.assigned_partner_id, 'cancellation', 'Mission réattribuée',
    'SECOTO a réattribué cette mission. Aucune pénalité ne s''applique.', v_order.mission_id, 'assigned',
    'od-replaced:' || p_order_id::text || ':' || v_order.mission_id::text, p_order_id);
  update public.transport_orders set status = 'searching_partner', assigned_partner_id = null, mission_id = null,
    lock_partner_id = null, lock_offer_id = null, confirmed_at = null, dispatch_round = 0, updated_at = now()
   where id = p_order_id;
  perform secoto_private.sub_attach_mission(p_order_id, null);
  perform secoto_private.audit('order_partner_replaced', 'transport_order', p_order_id::text,
    jsonb_build_object('reason', p_reason, 'previous_partner', v_order.assigned_partner_id, 'previous_mission', v_order.mission_id));
  perform secoto_private.od_broadcast(p_order_id);
  return jsonb_build_object('result', 'searching_partner');
end;
$f$;

create or replace function public.secoto_admin_od_cancel_order(p_order_id uuid, p_reason text, p_refund boolean)
returns jsonb language plpgsql volatile security definer set search_path = ''
as $f$
declare v_order public.transport_orders%rowtype;
begin
  perform secoto_private.assert_admin();
  if length(btrim(coalesce(p_reason, ''))) < 5 then raise exception 'Motif requis.'; end if;
  select * into v_order from public.transport_orders o where o.id = p_order_id for update;
  if v_order.status in ('delivered', 'cancelled') then raise exception 'Commande déjà close.'; end if;
  if v_order.mission_id is not null then
    update public.missions set status = 'cancelled', cancelled_at = now(), cancellation_reason = left(p_reason, 500) where id = v_order.mission_id;
  end if;
  if coalesce(p_refund, true) then
    perform secoto_private.od_stop_order(p_order_id, 'cancelled', left(p_reason, 200));
  else
    -- Sans remboursement (conditions d'annulation appliquées) : décision tracée.
    update public.transport_offers set status = 'withdrawn' where order_id = p_order_id and status = 'sent';
    update public.transport_orders set status = 'cancelled', cancelled_at = now(), cancel_reason = left(p_reason, 200), updated_at = now() where id = p_order_id;
    if v_order.funding = 'subscription' then perform secoto_private.sub_consume_for_order(p_order_id); end if;
  end if;
  perform secoto_private.audit('order_cancelled_by_admin', 'transport_order', p_order_id::text, jsonb_build_object('reason', p_reason, 'refund', coalesce(p_refund, true)));
  perform secoto_private.notify_event(v_order.account_id, 'cancellation', 'Commande annulée',
    format('Commande %s annulée par SECOTO : %s', v_order.public_ref, left(p_reason, 200)), v_order.mission_id, 'courses',
    'od-admin-cancel:' || p_order_id::text, p_order_id);
  return jsonb_build_object('result', 'cancelled');
end;
$f$;

-- ----------------------------------------------------------------------------
-- 10.5 Synchronisation mission → commande, versements, export comptable
-- ----------------------------------------------------------------------------
create or replace function secoto_private.trg_od_sync_from_mission()
returns trigger language plpgsql volatile security definer set search_path = ''
as $f$
declare v_order public.transport_orders%rowtype;
begin
  select * into v_order from public.transport_orders o where o.mission_id = new.id;
  if not found then return new; end if;
  if coalesce(new.progress_status, '') in ('pickup_completed', 'in_transit', 'incident_reported', 'delivery_started')
     and v_order.status = 'partner_confirmed' then
    update public.transport_orders set status = 'picked_up', updated_at = now() where id = v_order.id;
  elsif (coalesce(new.progress_status, '') in ('delivery_completed', 'completed') or new.status::text = 'completed')
     and v_order.status in ('partner_confirmed', 'picked_up') then
    update public.transport_orders set status = 'delivered', updated_at = now() where id = v_order.id;
    perform secoto_private.sub_consume_for_order(v_order.id);
    if v_order.mode = 'convoyage' then
      -- Convoyage : SECOTO verse la paye du convoyeur (virement, suivi manuel).
      insert into public.partner_payouts(mission_id, order_id, partner_id, amount_cents)
      values (new.id, v_order.id, v_order.assigned_partner_id, v_order.partner_pay_cents)
      on conflict (mission_id) do nothing;
    end if;
  end if;
  return new;
end;
$f$;

drop trigger if exists trg_secoto_od_sync_from_mission on public.missions;
create trigger trg_secoto_od_sync_from_mission
  after update of status, progress_status on public.missions
  for each row execute function secoto_private.trg_od_sync_from_mission();

create or replace function public.secoto_admin_partner_payouts(p_status text default 'to_pay')
returns jsonb language plpgsql stable security definer set search_path = ''
as $f$
begin
  perform secoto_private.assert_admin();
  return coalesce((select jsonb_agg(to_jsonb(pp) || jsonb_build_object(
      'partner_name', coalesce(a.company_name, a.full_name), 'mission_ref', m.public_ref,
      'client_payment_status', (select p.status from public.payments p join public.transport_orders o on o.payment_id = p.id where o.id = pp.order_id))
    order by pp.created_at)
    from public.partner_payouts pp join public.accounts a on a.id = pp.partner_id join public.missions m on m.id = pp.mission_id
    where p_status is null or pp.status = p_status), '[]'::jsonb);
end;
$f$;

create or replace function public.secoto_admin_mark_payout_paid(p_payout_id uuid, p_reference text)
returns jsonb language plpgsql volatile security definer set search_path = ''
as $f$
declare v public.partner_payouts%rowtype;
begin
  perform secoto_private.assert_admin();
  if length(btrim(coalesce(p_reference, ''))) < 3 then raise exception 'Référence du virement requise.'; end if;
  update public.partner_payouts set status = 'paid', paid_at = now(), reference = left(p_reference, 120), marked_by = auth.uid()
   where id = p_payout_id and status = 'to_pay' returning * into v;
  if not found then raise exception 'Versement introuvable ou déjà réglé.'; end if;
  perform secoto_private.audit('payout_marked_paid', 'partner_payout', p_payout_id::text, jsonb_build_object('reference', p_reference));
  return to_jsonb(v);
end;
$f$;

create or replace function public.secoto_admin_accounting_export(p_from date, p_to date)
returns table (
  event_date date, kind text, reference text, mission_ref text, purpose text,
  amount_eur numeric, refunded_eur numeric, partner_pay_eur numeric, margin_eur numeric,
  payment_status text, provider_id text
)
language plpgsql stable security definer set search_path = ''
as $f$
begin
  perform secoto_private.assert_admin();
  if p_from is null or p_to is null or p_to < p_from or p_to - p_from > 400 then raise exception 'Période invalide (400 jours maximum).'; end if;
  return query
    select coalesce(p.captured_at, p.paid_at, p.created_at)::date, 'encaissement'::text,
      coalesce(o.public_ref, p.id::text), m.public_ref, p.purpose,
      round(p.amount_cents / 100.0, 2), round(p.refunded_amount_cents / 100.0, 2),
      case when o.id is not null then round(o.partner_pay_cents / 100.0, 2) else m.carrier_pay end,
      case when o.id is not null then round((o.client_price_cents - o.partner_pay_cents) / 100.0, 2) else m.margin end,
      p.status, p.provider_intent_id
    from public.payments p
    left join public.transport_orders o on o.id = p.order_id
    left join public.missions m on m.id = coalesce(p.mission_id, o.mission_id)
    where coalesce(p.captured_at, p.paid_at, p.created_at)::date between p_from and p_to
      and p.status in ('paid', 'refund_pending', 'refunded')
    union all
    select coalesce(pp.paid_at, pp.created_at)::date, 'versement_partenaire', coalesce(pp.reference, pp.id::text), m.public_ref, 'partner_payout',
      round(-pp.amount_cents / 100.0, 2), 0::numeric, round(pp.amount_cents / 100.0, 2), null::numeric, pp.status, null::text
    from public.partner_payouts pp join public.missions m on m.id = pp.mission_id
    where coalesce(pp.paid_at, pp.created_at)::date between p_from and p_to
    order by 1, 2;
end;
$f$;

-- ----------------------------------------------------------------------------
-- 10.6 Pas de double facturation : paiement « à la livraison » d'une mission
-- déjà prépayée = uniquement les frais réels validés.
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
  v_prepaid boolean;
  v_frais_cents integer;
begin
  v_existing := secoto_private.lock_operation('prepare_delivery_payment', p_idempotency_key);
  if v_existing is not null then return v_existing; end if;

  select * into v_mission from public.missions m where m.id = p_mission_id;
  if not found then raise exception 'Mission introuvable.'; end if;
  if v_mission.type::text <> 'convoyage' then
    raise exception 'Paiement a la livraison reserve au convoyage.';
  end if;

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

  -- Migration 030 : commande prépayée ou incluse dans un forfait.
  select exists (select 1 from public.transport_orders o where o.mission_id = p_mission_id) into v_prepaid;
  v_frais_cents := (round(coalesce((
      select sum(f.montant) from public.frais f
      where f.mission_id = p_mission_id and f.statut::text = 'valide'), 0) * 100))::integer;
  if v_prepaid and v_frais_cents <= 0 then
    raise exception 'Prestation deja reglee : aucun frais reel valide a regler.';
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
      case when v_prepaid then v_frais_cents
           else (round((v_mission.client_price * 100)))::integer + v_frais_cents end,
      'pending', false
    )
    returning * into v_payment;

    if not v_prepaid then
      update public.missions set payment_status = 'awaiting_payment' where id = p_mission_id;
    end if;
  end if;

  return secoto_private.finish_operation(
    'prepare_delivery_payment',
    p_idempotency_key,
    jsonb_build_object(
      'payment_id',   v_payment.id,
      'status',       v_payment.status,
      'amount_cents', v_payment.amount_cents,
      'frais_only',   v_prepaid
    )
  );
end;
$function$;

-- ============================================================================
-- 11. DROITS
-- ============================================================================
-- Aucun revoke global sur secoto_private ici : la migration 003 a déjà posé le
-- cloisonnement, et plusieurs helpers (current_is_admin, can_read_mission…)
-- sont appelés PAR LES POLITIQUES RLS avec l'identité de l'utilisateur. Un
-- revoke global leur retirerait le droit d'exécution et bloquerait toute
-- lecture, pour tous les rôles. Les nouvelles fonctions sont fermées une par
-- une ci-dessous.

do $grants$
declare
  v_fn text;
  v_auth constant text[] := array[
    'public.secoto_feature_flags()',
    'public.secoto_admin_set_feature_flag(text,boolean)',
    'public.secoto_admin_audit_log(text,text,integer)',
    'public.secoto_business_ensure(text,text)',
    'public.secoto_my_businesses()',
    'public.secoto_admin_pricing_grids()',
    'public.secoto_admin_create_grid_version(text,jsonb,text)',
    'public.secoto_admin_activate_grid(uuid)',
    'public.secoto_admin_simulate_price(uuid,numeric,jsonb,numeric)',
    'public.secoto_admin_set_document_validity(uuid,date)',
    'public.secoto_admin_partner_compliance()',
    'public.secoto_my_dispatch_preferences()',
    'public.secoto_update_dispatch_preferences(jsonb)',
    'public.secoto_my_quotes()',
    'public.secoto_admin_quotes(text)',
    'public.secoto_admin_price_quote(uuid,integer,integer,integer,text,boolean)',
    'public.secoto_od_my_orders()',
    'public.secoto_od_book_quote(uuid,boolean,uuid)',
    'public.secoto_offer_accept(uuid,uuid)',
    'public.secoto_offer_decline(uuid)',
    'public.secoto_offer_mark_seen(uuid)',
    'public.secoto_offer_get(uuid)',
    'public.secoto_my_offers()',
    'public.secoto_od_cancel_order(uuid,uuid)',
    'public.secoto_admin_od_orders(text)',
    'public.secoto_admin_od_rebroadcast(uuid)',
    'public.secoto_admin_od_set_partner_pay(uuid,integer,boolean,text)',
    'public.secoto_admin_od_lock_for_partner(uuid,uuid)',
    'public.secoto_admin_od_replace_partner(uuid,text)',
    'public.secoto_admin_od_cancel_order(uuid,text,boolean)',
    'public.secoto_admin_partner_payouts(text)',
    'public.secoto_admin_mark_payout_paid(uuid,text)',
    'public.secoto_admin_accounting_export(date,date)',
    'public.secoto_prepare_delivery_payment(uuid,uuid)'
  ];
  v_service constant text[] := array[
    'public.secoto_quote_create(uuid,jsonb,jsonb)',
    'public.secoto_od_capture_result(uuid,boolean,text)',
    'public.secoto_od_expire_lock(uuid)',
    'public.secoto_od_apply_payment_event(uuid,text,text,text,integer,timestamptz,text)',
    'public.secoto_od_maintenance_tick()',
    'public.secoto_od_payment_action_result(uuid,text,boolean,text)'
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

-- Temps réel : la table payments est soumise à la RLS « son propre paiement »,
-- ce qui permet à l'écran de paiement de suivre le passage à « autorisé » ou
-- « encaissé » sans interroger le serveur en boucle. Aucune autre table des
-- nouveaux parcours n'est diffusée (aucune politique de lecture directe).
do $realtime$
begin
  begin
    alter publication supabase_realtime add table public.payments;
  exception when duplicate_object then null;
    when undefined_object then null;
  end;
end
$realtime$;

grant usage on schema secoto_private to service_role;
grant select, insert, update on public.transport_orders, public.transport_quotes, public.transport_offers,
  public.partner_payouts, public.partner_dispatch_preferences, public.secoto_feature_flags to service_role;
grant select on public.secoto_audit_log, public.pricing_grids, public.business_accounts, public.business_members to service_role;

notify pgrst, 'reload schema';
commit;
