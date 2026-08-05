-- SECOTO 1.2 — fondations transport de véhicules de prestige
-- Migration additive et rejouable.
-- Règles :
--   convoyage standard ou prestige -> convoyeurs vérifiés
--   plateau standard -> VL/PL acceptant les missions standard
--   prestige en camion fermé -> VL/PL avec capacité premium validée

begin;

do $guard$
begin
  if to_regclass('public.accounts') is null
     or to_regclass('public.missions') is null
     or to_regclass('public.mission_requests') is null then
    raise exception 'Tables SECOTO requises absentes.';
  end if;
end
$guard$;

alter table public.accounts
  add column if not exists receives_standard_plateau boolean not null default true,
  add column if not exists luxury_closed_transport_status text not null default 'not_requested',
  add column if not exists luxury_closed_transport_requested_at timestamptz,
  add column if not exists luxury_closed_transport_reviewed_at timestamptz,
  add column if not exists luxury_closed_transport_reviewed_by uuid
    references public.accounts(id) on delete set null;

alter table public.missions
  add column if not exists vehicle_category text not null default 'standard';

alter table public.mission_requests
  add column if not exists vehicle_category text not null default 'standard';

do $constraints$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname = 'accounts_luxury_closed_transport_status_check'
      and conrelid = 'public.accounts'::regclass
  ) then
    alter table public.accounts
      add constraint accounts_luxury_closed_transport_status_check
      check (
        luxury_closed_transport_status in (
          'not_requested',
          'pending',
          'approved',
          'rejected',
          'suspended'
        )
      );
  end if;

  if not exists (
    select 1
    from pg_constraint
    where conname = 'missions_vehicle_category_check'
      and conrelid = 'public.missions'::regclass
  ) then
    alter table public.missions
      add constraint missions_vehicle_category_check
      check (vehicle_category in ('standard', 'luxury'));
  end if;

  if not exists (
    select 1
    from pg_constraint
    where conname = 'mission_requests_vehicle_category_check'
      and conrelid = 'public.mission_requests'::regclass
  ) then
    alter table public.mission_requests
      add constraint mission_requests_vehicle_category_check
      check (vehicle_category in ('standard', 'luxury'));
  end if;
end
$constraints$;

create index if not exists idx_accounts_transport_routing
  on public.accounts(
    transporter_type,
    is_verified,
    status,
    receives_standard_plateau,
    luxury_closed_transport_status
  )
  where role::text = 'transporter'
    and deleted_at is null;

create index if not exists idx_missions_transport_routing
  on public.missions(type, vehicle_category, status);

create index if not exists idx_mission_requests_transport_routing
  on public.mission_requests(type, vehicle_category, status);

create or replace function secoto_private.transporter_matches_mission(
  p_account_id uuid,
  p_mission_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = ''
as $function$
  select exists (
    select 1
    from public.accounts a
    join public.missions m on m.id = p_mission_id
    where a.id = p_account_id
      and a.role::text = 'transporter'
      and a.status::text = 'active'
      and coalesce(a.is_verified, false)
      and a.deleted_at is null
      and m.status::text = 'published'
      and (
        (
          m.type::text = 'convoyage'
          and a.transporter_type::text = 'convoyeur'
        )
        or
        (
          m.type::text = 'plateau'
          and m.vehicle_category = 'standard'
          and a.transporter_type::text in ('vl', 'pl')
          and coalesce(a.receives_standard_plateau, true)
        )
        or
        (
          m.type::text = 'plateau'
          and m.vehicle_category = 'luxury'
          and a.transporter_type::text in ('vl', 'pl')
          and a.luxury_closed_transport_status = 'approved'
        )
      )
  );
$function$;

create or replace function secoto_private.current_transporter_matches_mission(
  p_mission_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = ''
as $function$
  select secoto_private.transporter_matches_mission(auth.uid(), p_mission_id);
$function$;

create or replace function public.secoto_update_my_transport_preferences(
  p_luxury_closed_transport_requested boolean,
  p_receives_standard_plateau boolean
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $function$
declare
  v_actor uuid := auth.uid();
  v_account public.accounts%rowtype;
  v_requested boolean := coalesce(p_luxury_closed_transport_requested, false);
  v_standard boolean := coalesce(p_receives_standard_plateau, true);
begin
  if v_actor is null then
    raise exception 'Authentification requise.' using errcode = '42501';
  end if;

  select *
  into v_account
  from public.accounts a
  where a.id = v_actor
    and a.role::text = 'transporter'
    and a.deleted_at is null
  for update;

  if not found then
    raise exception 'Compte transporteur introuvable.' using errcode = 'P0002';
  end if;

  if v_account.transporter_type::text = 'convoyeur' and v_requested then
    raise exception 'La capacité camion fermé concerne uniquement les transporteurs VL ou PL.';
  end if;

  update public.accounts
  set
    receives_standard_plateau = case
      when transporter_type::text in ('vl', 'pl') then v_standard
      else false
    end,
    luxury_closed_transport_status = case
      when transporter_type::text not in ('vl', 'pl') then 'not_requested'
      when v_requested
        and luxury_closed_transport_status in ('not_requested', 'rejected')
        then 'pending'
      when not v_requested
        and luxury_closed_transport_status = 'pending'
        then 'not_requested'
      else luxury_closed_transport_status
    end,
    luxury_closed_transport_requested_at = case
      when transporter_type::text in ('vl', 'pl')
        and v_requested
        and luxury_closed_transport_status in ('not_requested', 'rejected')
        then now()
      when not v_requested then null
      else luxury_closed_transport_requested_at
    end
  where id = v_actor
  returning * into v_account;

  return jsonb_build_object(
    'id', v_account.id,
    'transporter_type', v_account.transporter_type,
    'receives_standard_plateau', v_account.receives_standard_plateau,
    'luxury_closed_transport_status', v_account.luxury_closed_transport_status,
    'luxury_closed_transport_requested_at', v_account.luxury_closed_transport_requested_at
  );
end;
$function$;

create or replace function public.secoto_admin_review_luxury_capacity(
  p_transporter_id uuid,
  p_status text
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $function$
declare
  v_account public.accounts%rowtype;
begin
  perform secoto_private.assert_admin();

  if p_status not in ('approved', 'rejected', 'suspended') then
    raise exception 'Décision premium invalide.';
  end if;

  select *
  into v_account
  from public.accounts a
  where a.id = p_transporter_id
    and a.role::text = 'transporter'
    and a.transporter_type::text in ('vl', 'pl')
    and a.deleted_at is null
  for update;

  if not found then
    raise exception 'Transporteur VL/PL introuvable.' using errcode = 'P0002';
  end if;

  update public.accounts
  set
    luxury_closed_transport_status = p_status,
    luxury_closed_transport_reviewed_at = now(),
    luxury_closed_transport_reviewed_by = auth.uid()
  where id = p_transporter_id
  returning * into v_account;

  return jsonb_build_object(
    'id', v_account.id,
    'transporter_type', v_account.transporter_type,
    'receives_standard_plateau', v_account.receives_standard_plateau,
    'luxury_closed_transport_status', v_account.luxury_closed_transport_status,
    'luxury_closed_transport_reviewed_at', v_account.luxury_closed_transport_reviewed_at
  );
end;
$function$;

revoke all on function
  public.secoto_update_my_transport_preferences(boolean, boolean)
  from public, anon;
revoke all on function
  public.secoto_admin_review_luxury_capacity(uuid, text)
  from public, anon;

grant execute on function
  public.secoto_update_my_transport_preferences(boolean, boolean)
  to authenticated;
grant execute on function
  public.secoto_admin_review_luxury_capacity(uuid, text)
  to authenticated;

comment on column public.missions.vehicle_category is
  'standard ou luxury. Une mission luxury de type plateau exige un camion fermé validé.';
comment on column public.accounts.luxury_closed_transport_status is
  'Validation SECOTO de la capacité transport premium en camion fermé.';
comment on function secoto_private.transporter_matches_mission(uuid, uuid) is
  'Source de vérité du routage convoyeur / plateau standard / camion fermé premium.';

notify pgrst, 'reload schema';

commit;
