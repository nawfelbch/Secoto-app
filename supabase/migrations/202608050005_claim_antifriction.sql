-- SECOTO 1.1 — parcours client anti-friction et rattachement sécurisé v2
-- Date : 2026-08-05
-- À exécuter après 202608050004_notification_mission_claims.sql.
-- Additif et rejouable.

begin;

create extension if not exists pgcrypto with schema extensions;

alter table public.mission_claims
  add column if not exists access_code_hash text,
  add column if not exists access_code_hint text;

create unique index if not exists uq_mission_claims_access_code_hash
  on public.mission_claims(access_code_hash)
  where access_code_hash is not null;

create or replace function secoto_private.normalize_claim_email(p_value text)
returns text
language sql
immutable
security invoker
set search_path = ''
as $function$
  select case
    when nullif(btrim(coalesce(p_value, '')), '') is null then null
    when position('@' in btrim(p_value)) < 2 then null
    else lower(btrim(p_value))
  end;
$function$;

create or replace function secoto_private.normalize_claim_phone(p_value text)
returns text
language sql
immutable
security invoker
set search_path = ''
as $function$
  select case
    when length(regexp_replace(coalesce(p_value, ''), '\D', '', 'g')) < 8
      then null
    else regexp_replace(coalesce(p_value, ''), '\D', '', 'g')
  end;
$function$;

create or replace function secoto_private.claim_phone_matches(
  p_expected text,
  p_actual text
)
returns boolean
language sql
immutable
security invoker
set search_path = ''
as $function$
  select
    secoto_private.normalize_claim_phone(p_expected) is not null
    and secoto_private.normalize_claim_phone(p_actual) is not null
    and right(secoto_private.normalize_claim_phone(p_expected), 9)
      = right(secoto_private.normalize_claim_phone(p_actual), 9);
$function$;

create or replace function public.secoto_generate_mission_claim_v2(
  p_mission_id uuid,
  p_expires_in_days integer default 30
)
returns table (
  token text,
  access_code text,
  mission_id uuid,
  public_ref text,
  expires_at timestamptz
)
language plpgsql
volatile
security definer
set search_path = ''
as $function$
declare
  v_token text;
  v_token_hash text;
  v_raw_code text;
  v_access_code text;
  v_code_hash text;
  v_public_ref text;
  v_client_account_id uuid;
  v_client_contact text;
  v_client_phone text;
  v_expected_email text;
  v_expected_phone text;
  v_expiry timestamptz;
begin
  perform secoto_private.assert_admin();

  if p_expires_in_days is null
     or p_expires_in_days < 1
     or p_expires_in_days > 90 then
    raise exception 'La durée du lien doit être comprise entre 1 et 90 jours.';
  end if;

  select
    m.public_ref,
    m.client_account_id,
    m.client_contact,
    m.client_phone
  into
    v_public_ref,
    v_client_account_id,
    v_client_contact,
    v_client_phone
  from public.missions m
  where m.id = p_mission_id
  for update;

  if not found then
    raise exception 'Mission introuvable.' using errcode = 'P0002';
  end if;

  if v_client_account_id is not null then
    raise exception 'Cette mission est déjà rattachée à un compte client.';
  end if;

  v_expected_email :=
    secoto_private.normalize_claim_email(v_client_contact);
  v_expected_phone := coalesce(
    secoto_private.normalize_claim_phone(v_client_phone),
    secoto_private.normalize_claim_phone(v_client_contact)
  );

  if v_expected_email is null and v_expected_phone is null then
    raise exception
      'Renseignez l''e-mail ou le téléphone du client avant de générer son accès.';
  end if;

  update public.mission_claims
  set status = 'revoked', updated_at = now()
  where mission_claims.mission_id = p_mission_id
    and status = 'pending';

  v_token := translate(
    rtrim(encode(extensions.gen_random_bytes(32), 'base64'), '='),
    '+/',
    '-_'
  );
  v_token_hash :=
    encode(extensions.digest(v_token, 'sha256'), 'hex');
  v_expiry := now() + make_interval(days => p_expires_in_days);

  loop
    v_raw_code := upper(encode(extensions.gen_random_bytes(5), 'hex'));
    v_access_code :=
      substr(v_raw_code, 1, 4)
      || '-'
      || substr(v_raw_code, 5, 4)
      || '-'
      || substr(v_raw_code, 9, 2);
    v_code_hash := encode(
      extensions.digest(v_raw_code, 'sha256'),
      'hex'
    );

    begin
      insert into public.mission_claims (
        mission_id,
        token_hash,
        token_hint,
        access_code_hash,
        access_code_hint,
        status,
        expires_at,
        created_by
      ) values (
        p_mission_id,
        v_token_hash,
        right(v_token, 6),
        v_code_hash,
        right(v_raw_code, 4),
        'pending',
        v_expiry,
        auth.uid()
      );
      exit;
    exception
      when unique_violation then
        -- Collision extrêmement improbable : on régénère uniquement le code.
        continue;
    end;
  end loop;

  return query
  select
    v_token,
    v_access_code,
    p_mission_id,
    v_public_ref,
    v_expiry;
end;
$function$;

create or replace function public.secoto_claim_mission_v2(
  p_token text default null,
  p_code text default null
)
returns table (
  mission_id uuid,
  public_ref text,
  claimed_at timestamptz
)
language plpgsql
volatile
security definer
set search_path = ''
as $function$
declare
  v_actor uuid := auth.uid();
  v_account public.accounts%rowtype;
  v_claim public.mission_claims%rowtype;
  v_public_ref text;
  v_current_client uuid;
  v_client_contact text;
  v_client_phone text;
  v_expected_email text;
  v_expected_phone text;
  v_actual_email text;
  v_actual_phone text;
  v_clean_token text;
  v_clean_code text;
  v_now timestamptz := now();
  v_identity_matches boolean := false;
begin
  if v_actor is null then
    raise exception 'Connectez-vous pour retrouver votre transport.'
      using errcode = '42501';
  end if;

  select *
  into v_account
  from public.accounts a
  where a.id = v_actor
    and a.role::text = 'client'
    and a.status::text = 'active'
    and a.deleted_at is null;

  if not found then
    raise exception 'Un compte client actif est nécessaire.'
      using errcode = '42501';
  end if;

  v_clean_token := nullif(btrim(coalesce(p_token, '')), '');
  v_clean_code := upper(
    regexp_replace(coalesce(p_code, ''), '[^A-Za-z0-9]', '', 'g')
  );
  v_clean_code := nullif(v_clean_code, '');

  if v_clean_token is null and v_clean_code is null then
    raise exception 'Lien ou code SECOTO manquant.';
  end if;

  if v_clean_token is not null then
    if length(v_clean_token) < 32 or length(v_clean_token) > 200 then
      raise exception 'Lien de rattachement invalide.';
    end if;

    select mc.*
    into v_claim
    from public.mission_claims mc
    where mc.token_hash = encode(
      extensions.digest(v_clean_token, 'sha256'),
      'hex'
    )
    for update;
  else
    if length(v_clean_code) <> 10 then
      raise exception 'Le code SECOTO doit contenir 10 caractères.';
    end if;

    select mc.*
    into v_claim
    from public.mission_claims mc
    where mc.access_code_hash = encode(
      extensions.digest(v_clean_code, 'sha256'),
      'hex'
    )
    for update;
  end if;

  if not found then
    raise exception 'Lien ou code SECOTO invalide ou déjà remplacé.'
      using errcode = 'P0002';
  end if;

  if v_claim.status <> 'pending' then
    raise exception 'Cet accès a déjà été utilisé ou désactivé.';
  end if;

  if v_claim.expires_at <= v_now then
    update public.mission_claims
    set status = 'expired', updated_at = v_now
    where id = v_claim.id;

    raise exception
      'Cet accès a expiré. Demandez un nouveau lien à SECOTO.';
  end if;

  select
    m.public_ref,
    m.client_account_id,
    m.client_contact,
    m.client_phone
  into
    v_public_ref,
    v_current_client,
    v_client_contact,
    v_client_phone
  from public.missions m
  where m.id = v_claim.mission_id
  for update;

  if not found then
    raise exception 'Mission introuvable.' using errcode = 'P0002';
  end if;

  if v_current_client is not null
     and v_current_client <> v_actor then
    raise exception 'Cette mission est déjà rattachée à un autre compte.'
      using errcode = '42501';
  end if;

  v_expected_email :=
    secoto_private.normalize_claim_email(v_client_contact);
  v_expected_phone := coalesce(
    secoto_private.normalize_claim_phone(v_client_phone),
    secoto_private.normalize_claim_phone(v_client_contact)
  );
  v_actual_email :=
    secoto_private.normalize_claim_email(v_account.email);
  v_actual_phone :=
    secoto_private.normalize_claim_phone(v_account.phone);

  v_identity_matches :=
    (
      v_expected_email is not null
      and v_actual_email is not null
      and v_expected_email = v_actual_email
    )
    or secoto_private.claim_phone_matches(
      v_expected_phone,
      v_actual_phone
    );

  if not v_identity_matches then
    raise exception
      'Utilisez le même e-mail ou téléphone que celui communiqué à SECOTO.'
      using errcode = '42501';
  end if;

  update public.missions
  set client_account_id = v_actor
  where id = v_claim.mission_id;

  update public.mission_claims
  set
    status = 'claimed',
    claimed_by_account_id = v_actor,
    claimed_at = v_now,
    updated_at = v_now
  where id = v_claim.id;

  update public.mission_claims
  set status = 'revoked', updated_at = v_now
  where mission_claims.mission_id = v_claim.mission_id
    and id <> v_claim.id
    and status = 'pending';

  insert into public.notifications (
    account_id,
    type,
    title,
    body,
    mission_id,
    audience,
    is_read,
    push_screen,
    event_key
  ) values (
    v_actor,
    'system',
    'Transport ajouté',
    'Votre transport '
      || v_public_ref
      || ' est maintenant visible dans votre espace SECOTO.',
    v_claim.mission_id,
    'client',
    false,
    'courses',
    'mission-claimed-v2:'
      || v_claim.mission_id::text
      || ':'
      || v_actor::text
  )
  on conflict do nothing;

  return query
  select v_claim.mission_id, v_public_ref, v_now;
end;
$function$;

revoke all on function
  public.secoto_generate_mission_claim_v2(uuid, integer)
  from public, anon;
revoke all on function
  public.secoto_claim_mission_v2(text, text)
  from public, anon;

grant execute on function
  public.secoto_generate_mission_claim_v2(uuid, integer)
  to authenticated;
grant execute on function
  public.secoto_claim_mission_v2(text, text)
  to authenticated;

comment on function
  public.secoto_generate_mission_claim_v2(uuid, integer)
is
  'Génère un lien à usage unique et un code de secours, sans stocker leurs valeurs brutes.';

comment on function
  public.secoto_claim_mission_v2(text, text)
is
  'Rattache une mission uniquement à un compte client dont l''e-mail ou le téléphone correspond à la commande.';

notify pgrst, 'reload schema';

commit;
