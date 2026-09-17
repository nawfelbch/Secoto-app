-- ============================================================================
-- SECOTO 030 — A COLLER DANS LE SQL EDITOR SUPABASE (projet znnigxmzacukpfueqfrh)
-- ----------------------------------------------------------------------------
-- Contenu : migrations 030 (transport a la demande), 031 (abonnement
-- professionnel) et 032 (suivi de position), dans cet ordre.
--
-- AVANT D'EXECUTER
--   1. Sauvegarde PITR du projet + export des tables payments et missions.
--   2. Executer en une seule fois : chaque migration est une transaction
--      complete, additive et rejouable. Aucune reecriture de table.
--
-- APRES EXECUTION, verifier :
--   select key, enabled from public.secoto_feature_flags;   -- tout doit etre false
--   select mode, version, status from public.pricing_grids; -- convoyage v1 active, plateau v1 draft
--
-- RETOUR ARRIERE : update public.secoto_feature_flags set enabled = false;
-- (suppression complete : supabase/rollback/030-032_rollback.sql)
-- ============================================================================

-- ############ MIGRATION 030 ############
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
revoke all on all functions in schema secoto_private from public, anon, authenticated;

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

-- ############ MIGRATION 031 ############
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

-- ############ MIGRATION 032 ############
-- ============================================================================
-- SECOTO — MIGRATION 032 : SUIVI DE POSITION PENDANT LA MISSION
-- ----------------------------------------------------------------------------
-- • Partage activé par le partenaire APRÈS « Véhicule récupéré », avec son
--   consentement explicite, pour CETTE mission uniquement.
-- • Visible par : le client de la mission, le partenaire affecté, les
--   administrateurs SECOTO. Rien d'autre.
-- • Arrêt automatique à la livraison, à l'annulation, à la réattribution.
-- • Position du TRANSPORTEUR (téléphone), jamais d'un traceur dans le véhicule.
-- • Conservation : positions supprimées 30 jours après la fin du partage,
--   et au plus tard 90 jours après leur enregistrement (secoto_live_purge).
-- Additive et rejouable. Flag : live_tracking.
-- ============================================================================

begin;

do $guard$
begin
  if to_regprocedure('secoto_private.flag(text)') is null then
    raise exception 'Migration 030 requise avant la 032.';
  end if;
end
$guard$;

create table if not exists public.mission_live_sessions (
  mission_id       uuid primary key references public.missions(id) on delete cascade,
  partner_id       uuid not null references public.accounts(id),
  status           text not null check (status in ('active', 'stopped')),
  consent_at       timestamptz not null,
  started_at       timestamptz not null default now(),
  stopped_at       timestamptz,
  stop_reason      text,
  last_position_at timestamptz,
  updated_at       timestamptz not null default now()
);

create table if not exists public.mission_live_positions (
  id          bigint generated always as identity primary key,
  mission_id  uuid not null references public.missions(id) on delete cascade,
  partner_id  uuid not null references public.accounts(id),
  lat         double precision not null check (lat between -90 and 90),
  lng         double precision not null check (lng between -180 and 180),
  accuracy_m  real check (accuracy_m is null or accuracy_m >= 0),
  speed_mps   real,
  heading     real,
  recorded_at timestamptz not null,
  received_at timestamptz not null default now()
);
create index if not exists mission_live_positions_mission_idx on public.mission_live_positions(mission_id, recorded_at desc);
create index if not exists mission_live_positions_received_idx on public.mission_live_positions(received_at);

create table if not exists public.mission_live_eta (
  mission_id           uuid primary key references public.missions(id) on delete cascade,
  eta_at               timestamptz,
  remaining_km         numeric(8,1),
  provider             text,
  based_on_position_at timestamptz,
  multi_mission        boolean not null default false,
  computed_at          timestamptz not null default now(),
  approach_notified_at timestamptz,
  last_notified_eta    timestamptz,
  last_notified_at     timestamptz
);

alter table public.mission_live_sessions enable row level security;
alter table public.mission_live_positions enable row level security;
alter table public.mission_live_eta enable row level security;
revoke all on table public.mission_live_sessions, public.mission_live_positions, public.mission_live_eta from public, anon, authenticated;

insert into public.app_settings(key, value) values ('live_tracking_policy', jsonb_build_object(
  'fresh_seconds', 90, 'recent_seconds', 300, 'min_point_interval_seconds', 5,
  'retention_days_after_stop', 30, 'max_retention_days', 90,
  'approach_minutes', 20, 'eta_change_minutes', 20, 'eta_notify_cooldown_minutes', 30
)) on conflict (key) do nothing;

create or replace function secoto_private.live_num(p_key text, p_default numeric)
returns numeric language sql stable security definer set search_path = ''
as $f$ select coalesce((select (s.value ->> p_key)::numeric from public.app_settings s where s.key = 'live_tracking_policy'), p_default); $f$;

create or replace function secoto_private.live_stop(p_mission_id uuid, p_reason text)
returns void language plpgsql volatile security definer set search_path = ''
as $f$
declare v_client uuid;
begin
  update public.mission_live_sessions set status = 'stopped', stopped_at = now(), stop_reason = left(p_reason, 120), updated_at = now()
   where mission_id = p_mission_id and status = 'active';
  if found then
    delete from public.mission_live_eta where mission_id = p_mission_id;
    select m.client_account_id into v_client from public.missions m where m.id = p_mission_id;
    perform secoto_private.notify_event(v_client, 'live_tracking', 'Suivi en direct terminé',
      case p_reason when 'delivered' then 'Livraison effectuée : le partage de position est arrêté.'
                    else 'Le partage de position est arrêté pour cette mission.' end,
      p_mission_id, 'suivi', 'live-stop:' || p_mission_id::text || ':' || extract(epoch from now())::bigint, p_mission_id);
  end if;
end;
$f$;

create or replace function public.secoto_live_start(p_mission_id uuid, p_consent boolean)
returns jsonb language plpgsql volatile security definer set search_path = ''
as $f$
declare
  v_user uuid := secoto_private.assert_authenticated();
  v_mission public.missions%rowtype;
  v_session public.mission_live_sessions%rowtype;
begin
  if not secoto_private.flag('live_tracking') then raise exception 'Le suivi en direct n''est pas encore ouvert.'; end if;
  if not coalesce(p_consent, false) then raise exception 'Votre accord explicite est requis pour partager votre position.'; end if;
  select * into v_mission from public.missions m where m.id = p_mission_id for update;
  if not found or v_mission.assigned_transporter_id is distinct from v_user then raise exception 'Mission introuvable.' using errcode = 'P0002'; end if;
  if v_mission.status::text <> 'assigned'
     or coalesce(v_mission.progress_status, '') not in ('pickup_completed', 'in_transit', 'incident_reported', 'delivery_started') then
    raise exception 'Le partage de position s''active après « Véhicule récupéré » et s''arrête à la livraison.';
  end if;
  insert into public.mission_live_sessions as s(mission_id, partner_id, status, consent_at)
  values (p_mission_id, v_user, 'active', now())
  on conflict (mission_id) do update set
    partner_id = excluded.partner_id, status = 'active', consent_at = now(),
    started_at = case when s.status = 'active' and s.partner_id = excluded.partner_id then s.started_at else now() end,
    stopped_at = null, stop_reason = null, updated_at = now()
  returning * into v_session;
  perform secoto_private.notify_event(v_mission.client_account_id, 'live_tracking', 'Suivi en direct disponible',
    'Vous pouvez suivre la position du transporteur jusqu''à la livraison.', p_mission_id, 'suivi',
    'live-start:' || p_mission_id::text || ':' || extract(epoch from v_session.started_at)::bigint, p_mission_id);
  return to_jsonb(v_session);
end;
$f$;

create or replace function public.secoto_live_stop(p_mission_id uuid)
returns jsonb language plpgsql volatile security definer set search_path = ''
as $f$
declare v_user uuid := secoto_private.assert_authenticated();
begin
  if not (secoto_private.is_admin(v_user) or exists (select 1 from public.mission_live_sessions s where s.mission_id = p_mission_id and s.partner_id = v_user)) then
    raise exception 'Mission introuvable.' using errcode = 'P0002';
  end if;
  perform secoto_private.live_stop(p_mission_id, case when secoto_private.is_admin(v_user) then 'admin' else 'partner' end);
  return jsonb_build_object('status', 'stopped');
end;
$f$;

-- Lot de positions (file d'attente hors réseau incluse). Refus silencieux des
-- points invalides, trop anciens, futurs ou trop rapprochés.
create or replace function public.secoto_live_push_positions(p_mission_id uuid, p_points jsonb)
returns jsonb language plpgsql volatile security definer set search_path = ''
as $f$
declare
  v_user uuid := secoto_private.assert_authenticated();
  v_session public.mission_live_sessions%rowtype;
  v_mission public.missions%rowtype;
  p jsonb;
  v_at timestamptz;
  v_last timestamptz;
  v_accepted int := 0; v_rejected int := 0;
  v_min_gap numeric := secoto_private.live_num('min_point_interval_seconds', 5);
begin
  select * into v_session from public.mission_live_sessions s where s.mission_id = p_mission_id for update;
  select * into v_mission from public.missions m where m.id = p_mission_id;
  if v_session.mission_id is null or v_session.partner_id <> v_user or v_session.status <> 'active'
     or v_mission.assigned_transporter_id is distinct from v_user then
    return jsonb_build_object('accepted', 0, 'rejected', coalesce(jsonb_array_length(p_points), 0), 'sharing', 'stopped');
  end if;
  if jsonb_typeof(p_points) <> 'array' or jsonb_array_length(p_points) > 100 then raise exception 'Lot de positions invalide (100 maximum).'; end if;
  v_last := v_session.last_position_at;
  for p in select value from jsonb_array_elements(p_points) order by (value ->> 'recorded_at') loop
    begin
      v_at := (p ->> 'recorded_at')::timestamptz;
      if v_at > now() + interval '2 minutes' or v_at < now() - interval '2 hours'
         or abs((p ->> 'lat')::float8) > 90 or abs((p ->> 'lng')::float8) > 180
         or coalesce((p ->> 'accuracy_m')::real, 0) > 5000
         or (v_last is not null and v_at < v_last + make_interval(secs => v_min_gap)) then
        v_rejected := v_rejected + 1;
        continue;
      end if;
      insert into public.mission_live_positions(mission_id, partner_id, lat, lng, accuracy_m, speed_mps, heading, recorded_at)
      values (p_mission_id, v_user, (p ->> 'lat')::float8, (p ->> 'lng')::float8, (p ->> 'accuracy_m')::real,
              (p ->> 'speed_mps')::real, (p ->> 'heading')::real, v_at);
      v_last := v_at;
      v_accepted := v_accepted + 1;
    exception when others then
      v_rejected := v_rejected + 1;
    end;
  end loop;
  update public.mission_live_sessions set last_position_at = v_last, updated_at = now() where mission_id = p_mission_id;
  return jsonb_build_object('accepted', v_accepted, 'rejected', v_rejected, 'sharing', 'active');
end;
$f$;

-- Lecture : client de la mission, partenaire affecté, administrateurs.
create or replace function public.secoto_live_view(p_mission_id uuid)
returns jsonb language plpgsql stable security definer set search_path = ''
as $f$
declare
  v_user uuid := secoto_private.assert_authenticated();
  v_mission public.missions%rowtype;
  v_session public.mission_live_sessions%rowtype;
  v_pos public.mission_live_positions%rowtype;
  v_eta public.mission_live_eta%rowtype;
  v_age numeric;
  v_dest jsonb;
begin
  select * into v_mission from public.missions m where m.id = p_mission_id;
  if not found or not (secoto_private.is_admin(v_user) or v_mission.client_account_id = v_user or v_mission.assigned_transporter_id = v_user) then
    raise exception 'Mission introuvable.' using errcode = 'P0002';
  end if;
  select * into v_session from public.mission_live_sessions s where s.mission_id = p_mission_id;
  select q.delivery into v_dest from public.transport_orders o join public.transport_quotes q on q.id = o.quote_id where o.mission_id = p_mission_id;
  v_dest := coalesce(v_dest, jsonb_build_object('label', v_mission.delivery_address, 'city', v_mission.to_city));

  if v_session.mission_id is null or v_session.status <> 'active' then
    return jsonb_build_object('sharing', coalesce(v_session.status, 'not_started'), 'stop_reason', v_session.stop_reason,
      'enabled', secoto_private.flag('live_tracking'), 'destination', v_dest, 'mode', v_mission.type,
      'progress_status', v_mission.progress_status);
  end if;
  -- Aucune position antérieure à l'affectation actuelle du partenaire.
  select * into v_pos from public.mission_live_positions p
   where p.mission_id = p_mission_id and p.partner_id = v_session.partner_id and p.recorded_at >= v_session.started_at - interval '2 hours'
   order by p.recorded_at desc limit 1;
  select * into v_eta from public.mission_live_eta e where e.mission_id = p_mission_id;
  v_age := case when v_pos.id is not null then extract(epoch from (now() - v_pos.recorded_at)) end;
  return jsonb_build_object(
    'sharing', 'active', 'enabled', true, 'started_at', v_session.started_at,
    'mode', v_mission.type,
    'position_source', 'telephone_du_transporteur',
    'position', case when v_pos.id is not null then jsonb_build_object('lat', v_pos.lat, 'lng', v_pos.lng, 'accuracy_m', v_pos.accuracy_m,
                     'recorded_at', v_pos.recorded_at) end,
    'age_seconds', round(v_age),
    'freshness', case when v_pos.id is null then 'none'
                      when v_age <= secoto_private.live_num('fresh_seconds', 90) then 'live'
                      when v_age <= secoto_private.live_num('recent_seconds', 300) then 'recent'
                      else 'stale' end,
    'destination', v_dest,
    'eta', case when v_eta.eta_at is not null and v_eta.based_on_position_at >= now() - interval '10 minutes' then
      jsonb_build_object('eta_at', v_eta.eta_at, 'remaining_km', v_eta.remaining_km, 'computed_at', v_eta.computed_at,
        'multi_mission', v_eta.multi_mission) end,
    'progress_status', v_mission.progress_status,
    'server_time', now());
end;
$f$;

-- Arrêt automatique : livraison, annulation, réattribution.
create or replace function secoto_private.trg_live_autostop()
returns trigger language plpgsql volatile security definer set search_path = ''
as $f$
begin
  if new.assigned_transporter_id is distinct from old.assigned_transporter_id then
    perform secoto_private.live_stop(new.id, 'reassigned');
  elsif new.status::text in ('cancelled', 'completed') and old.status::text is distinct from new.status::text then
    perform secoto_private.live_stop(new.id, case when new.status::text = 'completed' then 'delivered' else 'cancelled' end);
  elsif coalesce(new.progress_status, '') in ('delivery_completed', 'completed') and coalesce(old.progress_status, '') is distinct from coalesce(new.progress_status, '') then
    perform secoto_private.live_stop(new.id, 'delivered');
  end if;
  return new;
end;
$f$;
drop trigger if exists trg_secoto_live_autostop on public.missions;
create trigger trg_secoto_live_autostop after update of status, progress_status, assigned_transporter_id on public.missions
  for each row execute function secoto_private.trg_live_autostop();

-- ETA : cibles à recalculer, résultat, notifications mesurées.
create or replace function public.secoto_live_eta_targets()
returns jsonb language sql stable security definer set search_path = ''
as $f$
  select coalesce(jsonb_agg(jsonb_build_object(
    'mission_id', s.mission_id, 'lat', p.lat, 'lng', p.lng, 'recorded_at', p.recorded_at,
    'destination', coalesce((select q.delivery from public.transport_orders o join public.transport_quotes q on q.id = o.quote_id where o.mission_id = s.mission_id),
                            jsonb_build_object('label', m.delivery_address, 'city', m.to_city)),
    'multi_mission', exists (select 1 from public.missions m2 where m2.assigned_transporter_id = s.partner_id and m2.id <> s.mission_id
                             and m2.status::text = 'assigned' and coalesce(m2.progress_status, '') in ('pickup_completed', 'in_transit', 'incident_reported', 'delivery_started')))), '[]'::jsonb)
  from public.mission_live_sessions s
  join public.missions m on m.id = s.mission_id
  join lateral (select * from public.mission_live_positions lp where lp.mission_id = s.mission_id order by lp.recorded_at desc limit 1) p on true
  left join public.mission_live_eta e on e.mission_id = s.mission_id
  where s.status = 'active' and p.recorded_at >= now() - interval '5 minutes'
    and (e.computed_at is null or e.computed_at <= now() - interval '3 minutes' or e.based_on_position_at < p.recorded_at - interval '5 minutes');
$f$;

create or replace function public.secoto_live_set_eta(p_mission_id uuid, p_eta_at timestamptz, p_remaining_km numeric, p_provider text, p_based_on timestamptz, p_multi boolean)
returns jsonb language plpgsql volatile security definer set search_path = ''
as $f$
declare
  v public.mission_live_eta%rowtype;
  v_client uuid;
  v_notify text := null;
begin
  if not exists (select 1 from public.mission_live_sessions s where s.mission_id = p_mission_id and s.status = 'active') then
    return jsonb_build_object('skipped', true);
  end if;
  insert into public.mission_live_eta as e(mission_id, eta_at, remaining_km, provider, based_on_position_at, multi_mission, computed_at)
  values (p_mission_id, p_eta_at, p_remaining_km, left(p_provider, 40), p_based_on, coalesce(p_multi, false), now())
  on conflict (mission_id) do update set eta_at = excluded.eta_at, remaining_km = excluded.remaining_km, provider = excluded.provider,
    based_on_position_at = excluded.based_on_position_at, multi_mission = excluded.multi_mission, computed_at = now()
  returning * into v;
  select m.client_account_id into v_client from public.missions m where m.id = p_mission_id;

  if v.eta_at is not null and v.approach_notified_at is null
     and v.eta_at <= now() + make_interval(mins => secoto_private.live_num('approach_minutes', 20)::int) then
    v_notify := 'approach';
    update public.mission_live_eta set approach_notified_at = now(), last_notified_eta = v.eta_at, last_notified_at = now() where mission_id = p_mission_id;
    perform secoto_private.notify_event(v_client, 'live_tracking', 'Livraison imminente',
      format('Arrivée estimée vers %s (estimation).', to_char(v.eta_at at time zone 'Europe/Paris', 'HH24:MI')),
      p_mission_id, 'suivi', 'live-approach:' || p_mission_id::text, p_mission_id);
  elsif v.eta_at is not null and v.last_notified_eta is not null
     and abs(extract(epoch from (v.eta_at - v.last_notified_eta))) >= secoto_private.live_num('eta_change_minutes', 20) * 60
     and v.last_notified_at <= now() - make_interval(mins => secoto_private.live_num('eta_notify_cooldown_minutes', 30)::int) then
    v_notify := 'changed';
    update public.mission_live_eta set last_notified_eta = v.eta_at, last_notified_at = now() where mission_id = p_mission_id;
    perform secoto_private.notify_event(v_client, 'live_tracking', 'Heure de livraison mise à jour',
      format('Nouvelle estimation : vers %s.', to_char(v.eta_at at time zone 'Europe/Paris', 'HH24:MI')),
      p_mission_id, 'suivi', 'live-eta:' || p_mission_id::text || ':' || extract(epoch from now())::bigint, p_mission_id);
  elsif v.eta_at is not null and v.last_notified_eta is null then
    -- Première estimation : référence sans notification.
    update public.mission_live_eta set last_notified_eta = v.eta_at, last_notified_at = now() where mission_id = p_mission_id;
  end if;
  return jsonb_build_object('mission_id', p_mission_id, 'notified', v_notify);
end;
$f$;

create or replace function public.secoto_live_purge()
returns jsonb language plpgsql volatile security definer set search_path = ''
as $f$
declare v_a int; v_b int;
begin
  delete from public.mission_live_positions p using public.mission_live_sessions s
   where s.mission_id = p.mission_id and s.status = 'stopped'
     and s.stopped_at < now() - make_interval(days => secoto_private.live_num('retention_days_after_stop', 30)::int);
  get diagnostics v_a = row_count;
  delete from public.mission_live_positions p where p.received_at < now() - make_interval(days => secoto_private.live_num('max_retention_days', 90)::int);
  get diagnostics v_b = row_count;
  return jsonb_build_object('deleted_after_stop', v_a, 'deleted_max_age', v_b);
end;
$f$;

revoke all on all functions in schema secoto_private from public, anon, authenticated;
do $grants$
declare v_fn text;
begin
  foreach v_fn in array array['public.secoto_live_start(uuid,boolean)', 'public.secoto_live_stop(uuid)',
      'public.secoto_live_push_positions(uuid,jsonb)', 'public.secoto_live_view(uuid)'] loop
    execute format('revoke all on function %s from public, anon', v_fn);
    execute format('grant execute on function %s to authenticated, service_role', v_fn);
  end loop;
  foreach v_fn in array array['public.secoto_live_eta_targets()',
      'public.secoto_live_set_eta(uuid,timestamptz,numeric,text,timestamptz,boolean)', 'public.secoto_live_purge()'] loop
    execute format('revoke all on function %s from public, anon, authenticated', v_fn);
    execute format('grant execute on function %s to service_role', v_fn);
  end loop;
end
$grants$;

notify pgrst, 'reload schema';
commit;
