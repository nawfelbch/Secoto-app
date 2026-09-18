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

-- Aucun revoke global sur secoto_private ici : la migration 003 a déjà posé le
-- cloisonnement, et plusieurs helpers (current_is_admin, can_read_mission…)
-- sont appelés PAR LES POLITIQUES RLS avec l'identité de l'utilisateur. Un
-- revoke global leur retirerait le droit d'exécution et bloquerait toute
-- lecture, pour tous les rôles. Les nouvelles fonctions sont fermées une par
-- une ci-dessous.
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
