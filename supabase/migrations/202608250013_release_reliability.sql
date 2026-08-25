-- SECOTO 1.3 — fiabilité finale : offres transporteur et reconnexion client.
-- Additif, transactionnel et rejouable.

begin;

-- Le front 1.3 envoie ces disponibilités avec le tarif. La migration qui les
-- portait n'avait jamais été versionnée dans le dépôt : PostgREST ne trouvait
-- donc aucune signature RPC compatible et refusait toute candidature.
alter table public.mission_applications
  add column if not exists proposed_price_grouped numeric,
  add column if not exists pickup_earliest_at timestamptz,
  add column if not exists pickup_latest_at timestamptz,
  add column if not exists delivery_earliest_at timestamptz,
  add column if not exists delivery_latest_at timestamptz;

do $constraints$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'mission_applications_grouped_price_check'
  ) then
    alter table public.mission_applications
      add constraint mission_applications_grouped_price_check
      check (
        proposed_price_grouped is null
        or (proposed_price_grouped > 0 and proposed_price_grouped <= 1000000)
      );
  end if;
  if not exists (
    select 1 from pg_constraint
    where conname = 'mission_applications_pickup_window_check'
  ) then
    alter table public.mission_applications
      add constraint mission_applications_pickup_window_check
      check (
        pickup_earliest_at is null or pickup_latest_at is null
        or pickup_earliest_at <= pickup_latest_at
      );
  end if;
  if not exists (
    select 1 from pg_constraint
    where conname = 'mission_applications_delivery_window_check'
  ) then
    alter table public.mission_applications
      add constraint mission_applications_delivery_window_check
      check (
        delivery_earliest_at is null or delivery_latest_at is null
        or delivery_earliest_at <= delivery_latest_at
      );
  end if;
end
$constraints$;

create or replace function public.secoto_apply_to_mission(
  p_mission_id uuid,
  p_proposed_price numeric,
  p_message text,
  p_idempotency_key uuid,
  p_pickup_earliest_at timestamptz,
  p_pickup_latest_at timestamptz,
  p_delivery_earliest_at timestamptz,
  p_delivery_latest_at timestamptz,
  p_proposed_price_grouped numeric
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
  if p_proposed_price_grouped is not null
     and (p_proposed_price_grouped <= 0 or p_proposed_price_grouped > 1000000) then
    raise exception 'Tarif groupé invalide.';
  end if;
  if p_pickup_earliest_at is null or p_pickup_latest_at is null
     or p_delivery_earliest_at is null or p_delivery_latest_at is null then
    raise exception 'Toutes les disponibilités sont obligatoires.';
  end if;
  if p_pickup_earliest_at > p_pickup_latest_at then
    raise exception 'La disponibilité d''enlèvement est invalide.';
  end if;
  if p_delivery_earliest_at > p_delivery_latest_at then
    raise exception 'La disponibilité de livraison est invalide.';
  end if;
  if p_message is not null and length(p_message) > 2000 then
    raise exception 'Message de candidature trop long.';
  end if;

  v_existing := secoto_private.lock_operation(
    'apply_to_mission', p_idempotency_key
  );
  if v_existing is not null then return v_existing; end if;

  select * into v_mission
  from public.missions m
  where m.id = p_mission_id
  for update;
  if not found
     or v_mission.status::text <> 'published'
     or v_mission.assigned_transporter_id is not null then
    raise exception 'Cette mission n''accepte plus de candidature.';
  end if;
  if not secoto_private.transporter_matches_mission(v_user_id, p_mission_id) then
    raise exception 'Cette mission ne correspond pas à vos capacités transport validées.'
      using errcode = '42501';
  end if;

  select * into v_account from public.accounts a where a.id = v_user_id;

  insert into public.mission_applications(
    mission_id, transporter_id, transporter_name, transporter_company,
    transporter_status, message, proposed_price, proposed_price_grouped,
    pickup_earliest_at, pickup_latest_at,
    delivery_earliest_at, delivery_latest_at,
    price_note, status
  ) values (
    p_mission_id, v_user_id, v_account.full_name, v_account.company_name,
    'verified', nullif(btrim(p_message), ''), round(p_proposed_price, 2),
    case when p_proposed_price_grouped is null then null
         else round(p_proposed_price_grouped, 2) end,
    p_pickup_earliest_at, p_pickup_latest_at,
    p_delivery_earliest_at, p_delivery_latest_at,
    null, 'pending'
  ) returning * into v_application;

  perform secoto_private.notify_admins(
    'new_application', p_mission_id, 'applications',
    'application:' || v_application.id::text
  );

  return secoto_private.finish_operation(
    'apply_to_mission', p_idempotency_key, to_jsonb(v_application)
  );
exception
  when unique_violation then
    raise exception using
      errcode = '23505',
      message = 'Vous avez déjà candidaté à cette mission.';
end;
$function$;

revoke all on function public.secoto_apply_to_mission(
  uuid, numeric, text, uuid, timestamptz, timestamptz,
  timestamptz, timestamptz, numeric
) from public, anon;
grant execute on function public.secoto_apply_to_mission(
  uuid, numeric, text, uuid, timestamptz, timestamptz,
  timestamptz, timestamptz, numeric
) to authenticated;

-- Le téléphone + code est un moyen de connexion, pas un coupon à usage
-- unique. Après le premier rattachement, le même couple peut recréer une
-- session uniquement pour le compte client déjà lié. Les limites d'essais et
-- la comparaison téléphone/code restent inchangées.
create or replace function public.secoto_prepare_client_phone_access(
  p_phone text,
  p_code text,
  p_ip_hash text,
  p_phone_hash text
)
returns table (
  mission_id uuid,
  public_ref text,
  client_name text,
  normalized_phone text,
  account_id uuid
)
language plpgsql
volatile
security definer
set search_path = ''
as $function$
declare
  v_phone text;
  v_code text;
  v_claim public.mission_claims%rowtype;
  v_expected_phone text;
  v_mission public.missions%rowtype;
  v_account_count integer;
  v_account_id uuid;
begin
  if coalesce(auth.role(), '') <> 'service_role' then
    raise exception 'ACCESS_FORBIDDEN' using errcode = '42501';
  end if;
  if length(coalesce(p_ip_hash, '')) <> 64
     or length(coalesce(p_phone_hash, '')) <> 64 then
    raise exception 'ACCESS_INVALID';
  end if;
  if (select count(*) from public.client_access_attempts a
      where a.ip_hash = p_ip_hash and not a.succeeded
        and a.attempted_at > now() - interval '15 minutes') >= 12
     or (select count(*) from public.client_access_attempts a
         where a.phone_hash = p_phone_hash and not a.succeeded
           and a.attempted_at > now() - interval '15 minutes') >= 6 then
    raise exception 'ACCESS_RATE_LIMITED';
  end if;

  v_phone := secoto_private.normalize_claim_phone(p_phone);
  v_code := upper(regexp_replace(coalesce(p_code, ''), '[^A-Za-z0-9]', '', 'g'));
  if v_phone is null or length(v_code) <> 10 then raise exception 'ACCESS_INVALID'; end if;

  select mc.* into v_claim from public.mission_claims mc
  where mc.access_code_hash = encode(extensions.digest(v_code, 'sha256'), 'hex');
  if not found then raise exception 'ACCESS_INVALID'; end if;
  if v_claim.status::text not in ('pending', 'claimed') then
    raise exception 'ACCESS_USED';
  end if;
  if v_claim.status::text = 'pending' and v_claim.expires_at <= now() then
    raise exception 'ACCESS_EXPIRED';
  end if;

  select m.* into v_mission from public.missions m where m.id = v_claim.mission_id;
  if not found then raise exception 'ACCESS_INVALID'; end if;
  v_expected_phone := coalesce(
    secoto_private.normalize_claim_phone(v_mission.client_phone),
    secoto_private.normalize_claim_phone(v_mission.client_contact)
  );
  if not secoto_private.claim_phone_matches(v_expected_phone, v_phone) then
    raise exception 'ACCESS_INVALID';
  end if;

  if v_claim.status::text = 'claimed' then
    v_account_id := v_claim.claimed_by_account_id;
    if v_account_id is null
       or v_mission.client_account_id is distinct from v_account_id
       or not exists (
         select 1 from public.accounts a
         where a.id = v_account_id and a.role::text = 'client'
           and a.status::text = 'active' and a.deleted_at is null
           and secoto_private.claim_phone_matches(a.phone, v_phone)
       ) then
      raise exception 'ACCESS_USED';
    end if;
  else
    select count(*) into v_account_count
    from public.accounts a
    where a.role::text = 'client' and a.status::text = 'active'
      and a.deleted_at is null
      and secoto_private.claim_phone_matches(a.phone, v_phone);
    if v_account_count > 1 then raise exception 'ACCESS_INVALID'; end if;
    if v_account_count = 1 then
      select a.id into v_account_id
      from public.accounts a
      where a.role::text = 'client' and a.status::text = 'active'
        and a.deleted_at is null
        and secoto_private.claim_phone_matches(a.phone, v_phone)
      limit 1;
    end if;
  end if;

  return query select v_mission.id, v_mission.public_ref,
    v_mission.client_name, v_phone, v_account_id;
end;
$function$;

create or replace function public.secoto_complete_client_phone_access(
  p_phone text,
  p_code text,
  p_account_id uuid
)
returns table (mission_id uuid, public_ref text, claimed_at timestamptz)
language plpgsql
volatile
security definer
set search_path = ''
as $function$
declare
  v_phone text;
  v_code text;
  v_claim public.mission_claims%rowtype;
  v_mission public.missions%rowtype;
  v_account public.accounts%rowtype;
  v_expected_phone text;
  v_now timestamptz := now();
begin
  if coalesce(auth.role(), '') <> 'service_role' then
    raise exception 'ACCESS_FORBIDDEN' using errcode = '42501';
  end if;
  v_phone := secoto_private.normalize_claim_phone(p_phone);
  v_code := upper(regexp_replace(coalesce(p_code, ''), '[^A-Za-z0-9]', '', 'g'));
  if v_phone is null or length(v_code) <> 10 or p_account_id is null then
    raise exception 'ACCESS_INVALID';
  end if;

  select mc.* into v_claim from public.mission_claims mc
  where mc.access_code_hash = encode(extensions.digest(v_code, 'sha256'), 'hex')
  for update;
  if not found then raise exception 'ACCESS_INVALID'; end if;
  if v_claim.status::text not in ('pending', 'claimed') then raise exception 'ACCESS_USED'; end if;
  if v_claim.status::text = 'pending' and v_claim.expires_at <= v_now then
    update public.mission_claims set status = 'expired', updated_at = v_now
    where id = v_claim.id;
    raise exception 'ACCESS_EXPIRED';
  end if;

  select * into v_account from public.accounts a
  where a.id = p_account_id and a.role::text = 'client'
    and a.status::text = 'active' and a.deleted_at is null
  for update;
  if not found or not secoto_private.claim_phone_matches(v_account.phone, v_phone) then
    raise exception 'ACCESS_INVALID';
  end if;

  select * into v_mission from public.missions m
  where m.id = v_claim.mission_id for update;
  if not found then raise exception 'ACCESS_INVALID'; end if;
  v_expected_phone := coalesce(
    secoto_private.normalize_claim_phone(v_mission.client_phone),
    secoto_private.normalize_claim_phone(v_mission.client_contact)
  );
  if not secoto_private.claim_phone_matches(v_expected_phone, v_phone) then
    raise exception 'ACCESS_INVALID';
  end if;

  if v_claim.status::text = 'claimed' then
    if v_claim.claimed_by_account_id is distinct from p_account_id
       or v_mission.client_account_id is distinct from p_account_id then
      raise exception 'ACCESS_USED';
    end if;
    return query select v_mission.id, v_mission.public_ref,
      coalesce(v_claim.claimed_at, v_now);
    return;
  end if;
  if v_mission.client_account_id is not null
     and v_mission.client_account_id <> p_account_id then
    raise exception 'ACCESS_USED';
  end if;

  update public.missions set client_account_id = p_account_id where id = v_mission.id;
  update public.mission_claims
  set status = 'claimed', claimed_by_account_id = p_account_id,
      claimed_at = v_now, updated_at = v_now
  where id = v_claim.id;
  update public.mission_claims set status = 'revoked', updated_at = v_now
  where mission_claims.mission_id = v_mission.id
    and id <> v_claim.id and status::text = 'pending';

  insert into public.notifications(
    account_id, type, title, body, mission_id, audience,
    is_read, push_screen, event_key
  ) values (
    p_account_id, 'system', 'Transport ajouté',
    'Votre transport ' || v_mission.public_ref
      || ' est maintenant visible dans votre espace SECOTO.',
    v_mission.id, 'client', false, 'courses',
    'mission-phone-access:' || v_mission.id::text || ':' || p_account_id::text
  ) on conflict do nothing;

  return query select v_mission.id, v_mission.public_ref, v_now;
end;
$function$;

revoke all on function public.secoto_prepare_client_phone_access(text, text, text, text)
  from public, anon, authenticated;
revoke all on function public.secoto_complete_client_phone_access(text, text, uuid)
  from public, anon, authenticated;
grant execute on function public.secoto_prepare_client_phone_access(text, text, text, text)
  to service_role;
grant execute on function public.secoto_complete_client_phone_access(text, text, uuid)
  to service_role;

notify pgrst, 'reload schema';

commit;
