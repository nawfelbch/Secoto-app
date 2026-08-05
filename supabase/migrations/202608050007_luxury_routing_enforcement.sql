-- SECOTO 1.2 — routage serveur, visibilité et validation camion fermé
-- À exécuter après 202608050006_luxury_transport_foundation.sql.
-- Migration additive et rejouable.

begin;

do $guard$
begin
  if to_regprocedure(
    'secoto_private.transporter_matches_mission(uuid,uuid)'
  ) is null then
    raise exception 'Migration SECOTO 006 requise avant la migration 007.';
  end if;

  if not exists (
    select 1
    from information_schema.columns
    where table_schema = 'public'
      and table_name = 'missions'
      and column_name = 'vehicle_category'
  ) then
    raise exception 'Colonne missions.vehicle_category absente.';
  end if;
end
$guard$;

-- Cohérence des anciens comptes.
update public.accounts
set
  receives_standard_plateau = false,
  luxury_closed_transport_status = 'not_requested',
  luxury_closed_transport_requested_at = null
where role::text = 'transporter'
  and transporter_type::text = 'convoyeur';

update public.accounts
set
  luxury_closed_transport_status = 'not_requested',
  luxury_closed_transport_requested_at = null
where role::text = 'transporter'
  and transporter_type::text not in ('vl', 'pl');

create or replace function secoto_private.safe_vehicle_category(
  p_payload jsonb
)
returns text
language plpgsql
immutable
security invoker
set search_path = ''
as $function$
declare
  v_category text := coalesce(
    nullif(btrim(p_payload ->> 'vehicle_category'), ''),
    'standard'
  );
begin
  if v_category not in ('standard', 'luxury') then
    raise exception 'Catégorie de véhicule invalide.';
  end if;
  return v_category;
end;
$function$;

-- Inscription : le transporteur exprime une demande, SECOTO reste seul
-- habilité à valider la capacité camion fermé.
create or replace function public.handle_new_user()
returns trigger
language plpgsql
volatile
security definer
set search_path = ''
as $function$
declare
  v_role text;
  v_client_type text;
  v_transporter_type text;
  v_receives_standard boolean;
  v_luxury_requested boolean;
begin
  v_role := case
    when new.raw_user_meta_data ->> 'role' in ('client', 'transporter')
      then new.raw_user_meta_data ->> 'role'
    else 'client'
  end;

  v_client_type := case
    when v_role = 'client'
      and new.raw_user_meta_data ->> 'client_type' in ('particulier', 'pro')
      then new.raw_user_meta_data ->> 'client_type'
    when v_role = 'client' then 'particulier'
    else null
  end;

  v_transporter_type := case
    when v_role = 'transporter'
      and new.raw_user_meta_data ->> 'transporter_type'
        in ('convoyeur', 'vl', 'pl')
      then new.raw_user_meta_data ->> 'transporter_type'
    else null
  end;

  v_receives_standard := case
    when v_transporter_type in ('vl', 'pl')
      then coalesce(
        lower(new.raw_user_meta_data ->> 'receives_standard_plateau')
          <> 'false',
        true
      )
    else false
  end;

  v_luxury_requested :=
    v_transporter_type in ('vl', 'pl')
    and lower(coalesce(
      new.raw_user_meta_data ->> 'luxury_closed_transport_requested',
      'false'
    )) = 'true';

  insert into public.accounts(
    id,
    email,
    role,
    full_name,
    company_name,
    phone,
    city,
    status,
    docs_count,
    is_verified,
    transporter_type,
    client_type,
    receives_standard_plateau,
    luxury_closed_transport_status,
    luxury_closed_transport_requested_at
  )
  values (
    new.id,
    new.email,
    v_role,
    left(coalesce(
      nullif(btrim(new.raw_user_meta_data ->> 'full_name'), ''),
      split_part(coalesce(new.email, 'utilisateur'), '`@', 1)
    ), 160),
    left(nullif(btrim(new.raw_user_meta_data ->> 'company_name'), ''), 200),
    left(nullif(btrim(new.raw_user_meta_data ->> 'phone'), ''), 40),
    left(nullif(btrim(new.raw_user_meta_data ->> 'city'), ''), 160),
    case when v_role = 'transporter' then 'pending' else 'active' end,
    0,
    false,
    v_transporter_type,
    v_client_type,
    v_receives_standard,
    case when v_luxury_requested then 'pending' else 'not_requested' end,
    case when v_luxury_requested then now() else null end
  )
  on conflict (id) do nothing;

  return new;
end;
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
  v_requested boolean := coalesce(
    p_luxury_closed_transport_requested,
    false
  );
  v_standard boolean := coalesce(p_receives_standard_plateau, true);
  v_next_status text;
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

  if v_account.transporter_type::text not in ('vl', 'pl') then
    raise exception
      'Les préférences plateau concernent uniquement les transporteurs VL ou PL.';
  end if;

  v_next_status := case
    when not v_requested then 'not_requested'
    when v_account.luxury_closed_transport_status = 'approved' then 'approved'
    when v_account.luxury_closed_transport_status = 'suspended' then 'suspended'
    when v_account.luxury_closed_transport_status = 'pending' then 'pending'
    else 'pending'
  end;

  update public.accounts
  set
    receives_standard_plateau = v_standard,
    luxury_closed_transport_status = v_next_status,
    luxury_closed_transport_requested_at = case
      when v_next_status = 'pending'
        and luxury_closed_transport_status <> 'pending'
        then now()
      when v_next_status = 'not_requested' then null
      else luxury_closed_transport_requested_at
    end,
    luxury_closed_transport_reviewed_at = case
      when v_next_status = 'not_requested' then null
      else luxury_closed_transport_reviewed_at
    end,
    luxury_closed_transport_reviewed_by = case
      when v_next_status = 'not_requested' then null
      else luxury_closed_transport_reviewed_by
    end
  where id = v_actor
  returning * into v_account;

  return jsonb_build_object(
    'id', v_account.id,
    'transporter_type', v_account.transporter_type,
    'receives_standard_plateau', v_account.receives_standard_plateau,
    'luxury_closed_transport_status',
      v_account.luxury_closed_transport_status,
    'luxury_closed_transport_requested_at',
      v_account.luxury_closed_transport_requested_at
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

  if not (
    (
      v_account.luxury_closed_transport_status = 'pending'
      and p_status in ('approved', 'rejected')
    )
    or
    (
      v_account.luxury_closed_transport_status = 'approved'
      and p_status = 'suspended'
    )
    or
    (
      v_account.luxury_closed_transport_status = 'suspended'
      and p_status = 'approved'
    )
  ) then
    raise exception 'Transition de capacité premium interdite.';
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
    'luxury_closed_transport_status',
      v_account.luxury_closed_transport_status,
    'luxury_closed_transport_reviewed_at',
      v_account.luxury_closed_transport_reviewed_at
  );
end;
$function$;

-- Formulaire public sans compte.
create or replace function public.secoto_create_public_request(
  p_payload jsonb,
  p_idempotency_key uuid
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $function$
declare
  v_existing jsonb;
  v_request public.mission_requests%rowtype;
  v_type text;
  v_category text;
  v_distance numeric;
begin
  if auth.uid() is not null then
    raise exception
      'Le formulaire public est réservé aux visiteurs non connectés.';
  end if;

  if p_payload is null or pg_column_size(p_payload) > 20000 then
    raise exception 'Données de demande invalides.';
  end if;

  v_existing := secoto_private.lock_operation(
    'create_public_request',
    p_idempotency_key
  );
  if v_existing is not null then return v_existing; end if;

  v_type := coalesce(p_payload ->> 'type', 'convoyage');
  if v_type not in ('convoyage', 'plateau') then
    raise exception 'Type de mission invalide.';
  end if;

  v_category := secoto_private.safe_vehicle_category(p_payload);
  v_distance := secoto_private.safe_numeric(
    p_payload, 'distance_km', 0, 10000, null
  );

  insert into public.mission_requests(
    public_ref,
    status,
    requester_id,
    requester_name,
    requester_company,
    type,
    vehicle_category,
    from_city,
    to_city,
    pickup_address,
    delivery_address,
    mission_date,
    vehicle,
    plate,
    distance_km,
    client_name,
    client_contact,
    client_phone,
    price_mode,
    proposed_price,
    notes,
    created_by_role,
    approved_mission_id
  )
  values (
    secoto_private.new_public_ref('REQ'),
    'pending',
    null,
    secoto_private.safe_text(p_payload, 'client_name', 160, true),
    null,
    v_type,
    v_category,
    secoto_private.safe_text(p_payload, 'from_city', 160, true),
    secoto_private.safe_text(p_payload, 'to_city', 160, true),
    secoto_private.safe_text(p_payload, 'pickup_address', 500, false),
    secoto_private.safe_text(p_payload, 'delivery_address', 500, false),
    secoto_private.safe_mission_date(p_payload),
    secoto_private.safe_text(p_payload, 'vehicle', 240, true),
    secoto_private.safe_text(p_payload, 'plate', 40, false),
    v_distance,
    secoto_private.safe_text(p_payload, 'client_name', 160, true),
    secoto_private.safe_text(p_payload, 'client_contact', 240, false),
    secoto_private.safe_text(p_payload, 'client_phone', 40, true),
    'fixed',
    secoto_private.safe_numeric(
      p_payload, 'proposed_price', 0, 1000000, null
    ),
    secoto_private.safe_text(p_payload, 'notes', 4000, false),
    'guest',
    null
  )
  returning * into v_request;

  if length(regexp_replace(
    coalesce(v_request.client_phone, ''),
    '\D',
    '',
    'g'
  )) < 6 then
    raise exception 'Numéro de téléphone invalide.';
  end if;

  perform secoto_private.notify_admins(
    'new_request',
    null,
    'requests',
    'request:' || v_request.id::text
  );

  return secoto_private.finish_operation(
    'create_public_request',
    p_idempotency_key,
    jsonb_build_object(
      'id', v_request.id,
      'public_ref', v_request.public_ref,
      'status', v_request.status
    )
  );
end;
$function$;

-- Création admin.
create or replace function public.secoto_create_mission(
  p_payload jsonb,
  p_idempotency_key uuid
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $function$
declare
  v_existing jsonb;
  v_mission public.missions%rowtype;
  v_type text;
  v_category text;
  v_distance numeric;
  v_carrier_cost numeric;
  v_payment text;
begin
  perform secoto_private.assert_admin();

  v_existing := secoto_private.lock_operation(
    'create_mission',
    p_idempotency_key
  );
  if v_existing is not null then return v_existing; end if;

  v_type := coalesce(p_payload ->> 'type', 'convoyage');
  if v_type not in ('convoyage', 'plateau') then
    raise exception 'Type de mission invalide.';
  end if;

  v_category := secoto_private.safe_vehicle_category(p_payload);
  v_distance := secoto_private.safe_numeric(
    p_payload, 'distance_km', 0, 10000, 0
  );
  v_carrier_cost := case
    when v_type = 'convoyage' then round(v_distance * 0.55, 2)
    else secoto_private.safe_numeric(
      p_payload, 'carrier_cost', 0, 1000000, 0
    )
  end;

  v_payment := coalesce(p_payload ->> 'payment_method', 'virement');
  if v_payment not in ('virement', 'especes') then
    raise exception 'Mode de règlement invalide.';
  end if;

  insert into public.missions(
    public_ref,
    type,
    vehicle_category,
    status,
    progress_status,
    from_city,
    to_city,
    pickup_address,
    delivery_address,
    mission_date,
    vehicle,
    plate,
    distance_km,
    carrier_cost,
    client_name,
    client_contact,
    client_phone,
    price_mode,
    proposed_price,
    payment_method,
    notes,
    created_by_role,
    client_account_id,
    assigned_transporter_id,
    assigned_transporter_name,
    source_request_id
  )
  values (
    secoto_private.new_public_ref('MIS'),
    v_type,
    v_category,
    'published',
    null,
    secoto_private.safe_text(p_payload, 'from_city', 160, true),
    secoto_private.safe_text(p_payload, 'to_city', 160, true),
    secoto_private.safe_text(p_payload, 'pickup_address', 500, false),
    secoto_private.safe_text(p_payload, 'delivery_address', 500, false),
    secoto_private.safe_mission_date(p_payload),
    secoto_private.safe_text(p_payload, 'vehicle', 240, true),
    secoto_private.safe_text(p_payload, 'plate', 40, false),
    v_distance,
    v_carrier_cost,
    secoto_private.safe_text(p_payload, 'client_name', 160, false),
    secoto_private.safe_text(p_payload, 'client_contact', 240, false),
    secoto_private.safe_text(p_payload, 'client_phone', 40, false),
    'fixed',
    secoto_private.safe_numeric(
      p_payload, 'proposed_price', 0, 1000000, null
    ),
    v_payment,
    secoto_private.safe_text(p_payload, 'notes', 4000, false),
    'admin',
    null,
    null,
    null,
    null
  )
  returning * into v_mission;

  perform secoto_private.notify_verified_transporters(
    v_mission.id,
    'mission-published:' || v_mission.id::text
  );

  return secoto_private.finish_operation(
    'create_mission',
    p_idempotency_key,
    to_jsonb(v_mission)
  );
end;
$function$;

-- Création client.
create or replace function public.secoto_create_client_mission(
  p_payload jsonb,
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
  v_account public.accounts%rowtype;
  v_existing jsonb;
  v_mission public.missions%rowtype;
  v_type text;
  v_category text;
  v_distance numeric;
  v_carrier_cost numeric;
  v_payment text;
begin
  select *
  into v_account
  from public.accounts a
  where a.id = v_user_id
    and a.role::text = 'client'
    and a.status::text = 'active'
    and a.deleted_at is null;

  if not found then
    raise exception 'Compte client actif requis.';
  end if;

  v_existing := secoto_private.lock_operation(
    'create_client_mission',
    p_idempotency_key
  );
  if v_existing is not null then return v_existing; end if;

  v_type := coalesce(p_payload ->> 'type', 'convoyage');
  if v_type not in ('convoyage', 'plateau') then
    raise exception 'Type de mission invalide.';
  end if;

  v_category := secoto_private.safe_vehicle_category(p_payload);
  v_distance := secoto_private.safe_numeric(
    p_payload, 'distance_km', 0, 10000, 0
  );
  v_carrier_cost := case
    when v_type = 'convoyage' then round(v_distance * 0.55, 2)
    else 0
  end;

  v_payment := coalesce(p_payload ->> 'payment_method', 'virement');
  if v_payment not in ('virement', 'especes') then
    raise exception 'Mode de règlement invalide.';
  end if;

  insert into public.missions(
    public_ref,
    type,
    vehicle_category,
    status,
    progress_status,
    from_city,
    to_city,
    pickup_address,
    delivery_address,
    mission_date,
    vehicle,
    plate,
    distance_km,
    carrier_cost,
    client_name,
    client_contact,
    client_phone,
    price_mode,
    proposed_price,
    payment_method,
    notes,
    created_by_role,
    client_account_id,
    assigned_transporter_id,
    assigned_transporter_name,
    source_request_id
  )
  values (
    secoto_private.new_public_ref('MIS'),
    v_type,
    v_category,
    'published',
    null,
    secoto_private.safe_text(p_payload, 'from_city', 160, true),
    secoto_private.safe_text(p_payload, 'to_city', 160, true),
    secoto_private.safe_text(p_payload, 'pickup_address', 500, false),
    secoto_private.safe_text(p_payload, 'delivery_address', 500, false),
    secoto_private.safe_mission_date(p_payload),
    secoto_private.safe_text(p_payload, 'vehicle', 240, true),
    secoto_private.safe_text(p_payload, 'plate', 40, false),
    v_distance,
    v_carrier_cost,
    coalesce(
      secoto_private.safe_text(p_payload, 'client_name', 160, false),
      v_account.full_name,
      v_account.company_name
    ),
    coalesce(
      secoto_private.safe_text(p_payload, 'client_contact', 240, false),
      v_account.email
    ),
    coalesce(
      secoto_private.safe_text(p_payload, 'client_phone', 40, false),
      v_account.phone
    ),
    'fixed',
    secoto_private.safe_numeric(
      p_payload, 'proposed_price', 0, 1000000, null
    ),
    v_payment,
    secoto_private.safe_text(p_payload, 'notes', 4000, false),
    'client',
    v_user_id,
    null,
    null,
    null
  )
  returning * into v_mission;

  perform secoto_private.notify_verified_transporters(
    v_mission.id,
    'mission-published:' || v_mission.id::text
  );
  perform secoto_private.notify_admins(
    'system',
    v_mission.id,
    'courses',
    'client-mission:' || v_mission.id::text
  );
  perform secoto_private.notify_one(
    v_user_id,
    'system',
    v_mission.id,
    'courses',
    'client-mission-created:' || v_mission.id::text
  );

  return secoto_private.finish_operation(
    'create_client_mission',
    p_idempotency_key,
    to_jsonb(v_mission)
      - array[
        'carrier_cost',
        'carrier_pay',
        'margin',
        'assigned_application_id'
      ]
  );
end;
$function$;

-- Demande d'un transporteur.
create or replace function public.secoto_create_transporter_request(
  p_payload jsonb,
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
  v_account public.accounts%rowtype;
  v_existing jsonb;
  v_request public.mission_requests%rowtype;
  v_type text;
  v_category text;
begin
  if not secoto_private.is_verified_transporter(v_user_id) then
    raise exception 'Compte transporteur vérifié requis.';
  end if;

  select *
  into v_account
  from public.accounts a
  where a.id = v_user_id;

  v_existing := secoto_private.lock_operation(
    'create_transporter_request',
    p_idempotency_key
  );
  if v_existing is not null then return v_existing; end if;

  v_type := coalesce(p_payload ->> 'type', 'convoyage');
  if v_type not in ('convoyage', 'plateau') then
    raise exception 'Type de mission invalide.';
  end if;
  v_category := secoto_private.safe_vehicle_category(p_payload);

  insert into public.mission_requests(
    public_ref,
    status,
    requester_id,
    requester_name,
    requester_company,
    type,
    vehicle_category,
    from_city,
    to_city,
    pickup_address,
    delivery_address,
    mission_date,
    vehicle,
    plate,
    distance_km,
    client_name,
    client_contact,
    client_phone,
    price_mode,
    proposed_price,
    notes,
    created_by_role,
    approved_mission_id
  )
  values (
    secoto_private.new_public_ref('REQ'),
    'pending',
    v_user_id,
    v_account.full_name,
    v_account.company_name,
    v_type,
    v_category,
    secoto_private.safe_text(p_payload, 'from_city', 160, true),
    secoto_private.safe_text(p_payload, 'to_city', 160, true),
    secoto_private.safe_text(p_payload, 'pickup_address', 500, false),
    secoto_private.safe_text(p_payload, 'delivery_address', 500, false),
    secoto_private.safe_mission_date(p_payload),
    secoto_private.safe_text(p_payload, 'vehicle', 240, true),
    secoto_private.safe_text(p_payload, 'plate', 40, false),
    secoto_private.safe_numeric(
      p_payload, 'distance_km', 0, 10000, null
    ),
    secoto_private.safe_text(p_payload, 'client_name', 160, false),
    secoto_private.safe_text(p_payload, 'client_contact', 240, false),
    secoto_private.safe_text(p_payload, 'client_phone', 40, false),
    'fixed',
    secoto_private.safe_numeric(
      p_payload, 'proposed_price', 0, 1000000, null
    ),
    secoto_private.safe_text(p_payload, 'notes', 4000, false),
    'transporter',
    null
  )
  returning * into v_request;

  perform secoto_private.notify_admins(
    'new_request',
    null,
    'requests',
    'request:' || v_request.id::text
  );

  return secoto_private.finish_operation(
    'create_transporter_request',
    p_idempotency_key,
    to_jsonb(v_request)
  );
end;
$function$;

-- Validation d'une demande en mission.
create or replace function public.secoto_approve_request(
  p_request_id uuid,
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
  v_request public.mission_requests%rowtype;
  v_mission public.missions%rowtype;
  v_requester_role text;
  v_client_id uuid;
  v_carrier_cost numeric;
begin
  v_existing := secoto_private.lock_operation(
    'approve_request',
    p_idempotency_key
  );
  if v_existing is not null then return v_existing; end if;

  select *
  into v_request
  from public.mission_requests r
  where r.id = p_request_id
  for update;

  if not found or v_request.status::text <> 'pending' then
    raise exception 'Demande introuvable ou déjà traitée.';
  end if;

  if v_request.requester_id is not null then
    select a.role::text
    into v_requester_role
    from public.accounts a
    where a.id = v_request.requester_id;
  end if;

  v_client_id := case
    when v_requester_role = 'client' then v_request.requester_id
    else null
  end;

  v_carrier_cost := case
    when v_request.type::text = 'convoyage'
      then round(greatest(
        coalesce(v_request.distance_km, 0),
        0
      ) * 0.55, 2)
    else 0
  end;

  insert into public.missions(
    public_ref,
    type,
    vehicle_category,
    status,
    progress_status,
    from_city,
    to_city,
    pickup_address,
    delivery_address,
    mission_date,
    vehicle,
    plate,
    distance_km,
    carrier_cost,
    client_name,
    client_contact,
    client_phone,
    price_mode,
    proposed_price,
    payment_method,
    notes,
    created_by_role,
    client_account_id,
    assigned_transporter_id,
    assigned_transporter_name,
    source_request_id
  )
  values (
    secoto_private.new_public_ref('MIS'),
    v_request.type,
    v_request.vehicle_category,
    'published',
    null,
    v_request.from_city,
    v_request.to_city,
    v_request.pickup_address,
    v_request.delivery_address,
    v_request.mission_date,
    v_request.vehicle,
    v_request.plate,
    v_request.distance_km,
    v_carrier_cost,
    v_request.client_name,
    v_request.client_contact,
    v_request.client_phone,
    v_request.price_mode,
    v_request.proposed_price,
    'virement',
    v_request.notes,
    v_request.created_by_role,
    v_client_id,
    null,
    null,
    v_request.id
  )
  returning * into v_mission;

  update public.mission_requests
  set
    status = 'approved',
    approved_mission_id = v_mission.id,
    decided_at = now(),
    decided_by = v_admin_id
  where id = p_request_id;

  perform secoto_private.notify_verified_transporters(
    v_mission.id,
    'mission-published:' || v_mission.id::text
  );

  if v_request.requester_id is not null then
    perform secoto_private.notify_one(
      v_request.requester_id,
      'system',
      v_mission.id,
      case when v_requester_role = 'transporter'
        then 'requests' else 'courses' end,
      'request-approved:' || p_request_id::text
    );
  end if;

  return secoto_private.finish_operation(
    'approve_request',
    p_idempotency_key,
    to_jsonb(v_mission)
  );
end;
$function$;

-- Notification uniquement aux transporteurs compatibles.
create or replace function secoto_private.notify_verified_transporters(
  p_mission_id uuid,
  p_event_key_prefix text
)
returns void
language plpgsql
volatile
security definer
set search_path = ''
as $function$
declare
  v_transporter record;
begin
  for v_transporter in
    select a.id
    from public.accounts a
    where secoto_private.transporter_matches_mission(
      a.id,
      p_mission_id
    )
  loop
    perform secoto_private.notify_one(
      v_transporter.id,
      'new_course',
      p_mission_id,
      'available',
      p_event_key_prefix || ':' || v_transporter.id::text
    );
  end loop;
end;
$function$;

-- Candidature : même règle que la notification et la visibilité.
create or replace function public.secoto_apply_to_mission(
  p_mission_id uuid,
  p_proposed_price numeric,
  p_message text,
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
  v_account public.accounts%rowtype;
  v_mission public.missions%rowtype;
  v_application public.mission_applications%rowtype;
  v_existing jsonb;
begin
  if not secoto_private.is_verified_transporter(v_user_id) then
    raise exception 'Compte transporteur vérifié requis.';
  end if;

  if p_proposed_price is null
     or p_proposed_price <= 0
     or p_proposed_price > 1000000 then
    raise exception 'Tarif proposé invalide.';
  end if;

  if p_message is not null and length(p_message) > 2000 then
    raise exception 'Message de candidature trop long.';
  end if;

  v_existing := secoto_private.lock_operation(
    'apply_to_mission',
    p_idempotency_key
  );
  if v_existing is not null then return v_existing; end if;

  select *
  into v_mission
  from public.missions m
  where m.id = p_mission_id
  for update;

  if not found
     or v_mission.status::text <> 'published'
     or v_mission.assigned_transporter_id is not null then
    raise exception 'Cette mission n''accepte plus de candidature.';
  end if;

  if not secoto_private.transporter_matches_mission(
    v_user_id,
    p_mission_id
  ) then
    raise exception
      'Cette mission ne correspond pas à vos capacités transport validées.'
      using errcode = '42501';
  end if;

  select *
  into v_account
  from public.accounts a
  where a.id = v_user_id;

  insert into public.mission_applications(
    mission_id,
    transporter_id,
    transporter_name,
    transporter_company,
    transporter_status,
    message,
    proposed_price,
    price_note,
    status
  )
  values (
    p_mission_id,
    v_user_id,
    v_account.full_name,
    v_account.company_name,
    'verified',
    nullif(btrim(p_message), ''),
    round(p_proposed_price, 2),
    null,
    'pending'
  )
  returning * into v_application;

  perform secoto_private.notify_admins(
    'new_application',
    p_mission_id,
    'applications',
    'application:' || v_application.id::text
  );

  return secoto_private.finish_operation(
    'apply_to_mission',
    p_idempotency_key,
    to_jsonb(v_application)
  );
exception
  when unique_violation then
    raise exception using
      errcode = '23505',
      message = 'Vous avez déjà candidaté à cette mission.';
end;
$function$;

-- Attribution : contrôle à nouveau les capacités, y compris après une
-- suspension administrative intervenue après la candidature.
create or replace function public.secoto_assign_mission(
  p_mission_id uuid,
  p_application_id uuid,
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
  v_mission public.missions%rowtype;
  v_application public.mission_applications%rowtype;
  v_carrier_cost numeric;
begin
  v_existing := secoto_private.lock_operation(
    'assign_mission',
    p_idempotency_key
  );
  if v_existing is not null then return v_existing; end if;

  select *
  into v_mission
  from public.missions m
  where m.id = p_mission_id
  for update;

  if not found
     or v_mission.status::text <> 'published'
     or v_mission.assigned_transporter_id is not null then
    raise exception 'Mission déjà attribuée ou indisponible.';
  end if;

  select *
  into v_application
  from public.mission_applications ma
  where ma.id = p_application_id
    and ma.mission_id = p_mission_id
  for update;

  if not found or v_application.status::text <> 'pending' then
    raise exception 'Candidature invalide ou déjà traitée.';
  end if;

  if not secoto_private.transporter_matches_mission(
    v_application.transporter_id,
    p_mission_id
  ) then
    raise exception
      'Le transporteur sélectionné n''est plus compatible avec cette mission.';
  end if;

  v_carrier_cost := case
    when v_mission.type::text = 'convoyage'
      then round(greatest(
        coalesce(v_mission.distance_km, 0),
        0
      ) * 0.55, 2)
    when v_mission.type::text = 'plateau'
      then round(greatest(v_application.proposed_price, 0), 2)
    else 0
  end;

  update public.missions
  set
    status = 'assigned',
    progress_status = 'assigned_pending',
    assigned_transporter_id = v_application.transporter_id,
    assigned_transporter_name = v_application.transporter_name,
    assigned_application_id = v_application.id,
    carrier_cost = v_carrier_cost
  where id = p_mission_id
  returning * into v_mission;

  update public.mission_applications
  set
    status = case
      when id = p_application_id then 'accepted'
      else 'rejected'
    end,
    decided_at = now(),
    decided_by = v_admin_id
  where mission_id = p_mission_id
    and status::text = 'pending';

  perform secoto_private.notify_one(
    v_application.transporter_id,
    'course_assigned',
    p_mission_id,
    'assigned',
    'mission-assigned:transporter:' || p_mission_id::text
  );

  if v_mission.client_account_id is not null then
    perform secoto_private.notify_one(
      v_mission.client_account_id,
      'course_assigned',
      p_mission_id,
      'courses',
      'mission-assigned:client:' || p_mission_id::text
    );
  end if;

  return secoto_private.finish_operation(
    'assign_mission',
    p_idempotency_key,
    to_jsonb(v_mission)
  );
end;
$function$;

-- Vues cloisonnées. La nouvelle colonne est ajoutée en fin de vue afin de
-- préserver l'ordre historique des colonnes existantes.
create or replace view public.secoto_missions_admin_v2
with (security_barrier = true)
as
select
  m.id,
  m.public_ref,
  m.type,
  m.status,
  m.progress_status,
  m.from_city,
  m.to_city,
  m.pickup_address,
  m.delivery_address,
  m.mission_date,
  m.vehicle,
  m.plate,
  m.distance_km,
  m.carrier_cost,
  m.client_price,
  m.carrier_pay,
  m.margin,
  m.client_name,
  m.client_contact,
  m.client_phone,
  m.price_mode,
  m.proposed_price,
  m.payment_method,
  m.notes,
  m.created_by_role,
  m.client_account_id,
  m.assigned_transporter_id,
  m.assigned_transporter_name,
  m.source_request_id,
  m.created_at,
  m.vehicle_category
from public.missions m
where secoto_private.is_admin(auth.uid());

create or replace view public.secoto_missions_client_v2
with (security_barrier = true)
as
select
  m.id,
  m.public_ref,
  m.type,
  m.status,
  m.progress_status,
  m.from_city,
  m.to_city,
  m.pickup_address,
  m.delivery_address,
  m.mission_date,
  m.vehicle,
  m.plate,
  m.distance_km,
  m.client_price,
  m.client_name,
  m.client_contact,
  m.client_phone,
  m.price_mode,
  m.proposed_price,
  m.payment_method,
  m.notes,
  m.created_by_role,
  m.client_account_id,
  m.assigned_transporter_id,
  m.assigned_transporter_name,
  m.source_request_id,
  m.created_at,
  m.vehicle_category
from public.missions m
where m.client_account_id = auth.uid();

create or replace view public.secoto_missions_transporter_v2
with (security_barrier = true)
as
select
  m.id,
  m.public_ref,
  m.type,
  m.status,
  m.progress_status,
  m.from_city,
  m.to_city,
  m.pickup_address,
  m.delivery_address,
  m.mission_date,
  m.vehicle,
  m.plate,
  m.distance_km,
  m.carrier_cost,
  m.carrier_pay,
  m.client_name,
  m.client_contact,
  m.client_phone,
  m.payment_method,
  m.notes,
  m.assigned_transporter_id,
  m.assigned_transporter_name,
  m.created_at,
  m.vehicle_category
from public.missions m
where m.assigned_transporter_id = auth.uid();

create or replace view public.secoto_public_missions_v2
with (security_barrier = true)
as
select
  m.id,
  m.public_ref,
  m.type,
  m.status,
  m.progress_status,
  m.from_city,
  m.to_city,
  m.vehicle,
  m.distance_km,
  m.created_at,
  m.vehicle_category
from public.missions m
where secoto_private.transporter_matches_mission(auth.uid(), m.id);

grant select on table public.secoto_missions_admin_v2 to authenticated;
grant select on table public.secoto_missions_client_v2 to authenticated;
grant select on table public.secoto_missions_transporter_v2 to authenticated;
grant select on table public.secoto_public_missions_v2 to authenticated;

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

notify pgrst, 'reload schema';

commit;
