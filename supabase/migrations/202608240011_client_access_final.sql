-- SECOTO 1.3 — accès client téléphone + code, tarification simplifiée,
-- textes légaux corrigés. Additif et rejouable.

begin;

create extension if not exists pgcrypto with schema extensions;

-- Les valeurs historiques restent lisibles, mais ces deux suppléments ne
-- participent plus à aucun nouveau calcul.
create or replace function public.secoto_surcharge_coefficient(
  p_urgent boolean,
  p_weekend boolean,
  p_oversize_pct numeric
)
returns numeric
language sql
immutable
security invoker
set search_path = ''
as $function$
  select case when coalesce(p_urgent, false) then 1.30 else 1 end;
$function$;

create or replace function secoto_private.neutralize_removed_surcharges()
returns trigger
language plpgsql
volatile
security definer
set search_path = ''
as $function$
begin
  new.surcharge_weekend := false;
  new.surcharge_oversize_pct := 0;
  return new;
end;
$function$;

drop trigger if exists trg_missions_neutralize_removed_surcharges_insert on public.missions;
create trigger trg_missions_neutralize_removed_surcharges_insert
before insert on public.missions
for each row execute function secoto_private.neutralize_removed_surcharges();

drop trigger if exists trg_missions_neutralize_removed_surcharges_update on public.missions;
create trigger trg_missions_neutralize_removed_surcharges_update
before update of surcharge_weekend, surcharge_oversize_pct on public.missions
for each row execute function secoto_private.neutralize_removed_surcharges();

-- Journal minimal et pseudonymisé pour limiter les essais de codes.
create table if not exists public.client_access_attempts (
  id bigint generated always as identity primary key,
  ip_hash text not null check (length(ip_hash) = 64),
  phone_hash text not null check (length(phone_hash) = 64),
  succeeded boolean not null default false,
  attempted_at timestamptz not null default now()
);

create index if not exists idx_client_access_attempts_ip_recent
  on public.client_access_attempts(ip_hash, attempted_at desc);
create index if not exists idx_client_access_attempts_phone_recent
  on public.client_access_attempts(phone_hash, attempted_at desc);

alter table public.client_access_attempts enable row level security;
revoke all on table public.client_access_attempts from public, anon, authenticated;
grant select, insert, delete on table public.client_access_attempts to service_role;
grant usage, select on sequence public.client_access_attempts_id_seq to service_role;

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
      where a.ip_hash = p_ip_hash
        and not a.succeeded
        and a.attempted_at > now() - interval '15 minutes') >= 12
     or (select count(*) from public.client_access_attempts a
         where a.phone_hash = p_phone_hash
           and not a.succeeded
           and a.attempted_at > now() - interval '15 minutes') >= 6 then
    raise exception 'ACCESS_RATE_LIMITED';
  end if;

  v_phone := secoto_private.normalize_claim_phone(p_phone);
  v_code := upper(regexp_replace(coalesce(p_code, ''), '[^A-Za-z0-9]', '', 'g'));
  if v_phone is null or length(v_code) <> 10 then
    raise exception 'ACCESS_INVALID';
  end if;

  select mc.* into v_claim
  from public.mission_claims mc
  where mc.access_code_hash = encode(extensions.digest(v_code, 'sha256'), 'hex');
  if not found then raise exception 'ACCESS_INVALID'; end if;
  if v_claim.status <> 'pending' then raise exception 'ACCESS_USED'; end if;
  if v_claim.expires_at <= now() then raise exception 'ACCESS_EXPIRED'; end if;

  select m.* into v_mission
  from public.missions m
  where m.id = v_claim.mission_id;
  if not found then raise exception 'ACCESS_INVALID'; end if;

  v_expected_phone := coalesce(
    secoto_private.normalize_claim_phone(v_mission.client_phone),
    secoto_private.normalize_claim_phone(v_mission.client_contact)
  );
  if not secoto_private.claim_phone_matches(v_expected_phone, v_phone) then
    raise exception 'ACCESS_INVALID';
  end if;

  select count(*)
    into v_account_count
  from public.accounts a
  where a.role::text = 'client'
    and a.status::text = 'active'
    and a.deleted_at is null
    and secoto_private.claim_phone_matches(a.phone, v_phone);
  if v_account_count > 1 then raise exception 'ACCESS_INVALID'; end if;
  if v_account_count = 1 then
    select a.id into v_account_id
    from public.accounts a
    where a.role::text = 'client'
      and a.status::text = 'active'
      and a.deleted_at is null
      and secoto_private.claim_phone_matches(a.phone, v_phone)
    limit 1;
  end if;

  return query select
    v_mission.id,
    v_mission.public_ref,
    v_mission.client_name,
    v_phone,
    v_account_id;
end;
$function$;

create or replace function public.secoto_complete_client_phone_access(
  p_phone text,
  p_code text,
  p_account_id uuid
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

  select mc.* into v_claim
  from public.mission_claims mc
  where mc.access_code_hash = encode(extensions.digest(v_code, 'sha256'), 'hex')
  for update;
  if not found then raise exception 'ACCESS_INVALID'; end if;
  if v_claim.status <> 'pending' then raise exception 'ACCESS_USED'; end if;
  if v_claim.expires_at <= v_now then
    update public.mission_claims set status = 'expired', updated_at = v_now
    where id = v_claim.id;
    raise exception 'ACCESS_EXPIRED';
  end if;

  select * into v_account from public.accounts a
  where a.id = p_account_id
    and a.role::text = 'client'
    and a.status::text = 'active'
    and a.deleted_at is null
  for update;
  if not found or not secoto_private.claim_phone_matches(v_account.phone, v_phone) then
    raise exception 'ACCESS_INVALID';
  end if;

  select * into v_mission from public.missions m
  where m.id = v_claim.mission_id
  for update;
  if not found then raise exception 'ACCESS_INVALID'; end if;
  v_expected_phone := coalesce(
    secoto_private.normalize_claim_phone(v_mission.client_phone),
    secoto_private.normalize_claim_phone(v_mission.client_contact)
  );
  if not secoto_private.claim_phone_matches(v_expected_phone, v_phone) then
    raise exception 'ACCESS_INVALID';
  end if;
  if v_mission.client_account_id is not null
     and v_mission.client_account_id <> p_account_id then
    raise exception 'ACCESS_USED';
  end if;

  update public.missions set client_account_id = p_account_id
  where id = v_mission.id;
  update public.mission_claims
  set status = 'claimed', claimed_by_account_id = p_account_id,
      claimed_at = v_now, updated_at = v_now
  where id = v_claim.id;
  update public.mission_claims set status = 'revoked', updated_at = v_now
  where mission_claims.mission_id = v_mission.id
    and id <> v_claim.id and status = 'pending';

  insert into public.notifications (
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

insert into public.app_settings (key, value)
values ('legal_texts', jsonb_build_object(
  'version', '2026-08-24',
  'commission_label', 'Réservation de votre créneau',
  'commission_notice',
    'Ce montant règle la mise en relation et bloque votre créneau auprès du '
    'transporteur. Il rémunère SECOTO et n’est pas déduit du prix du transport.',
  'transport_notice',
    'Le prix du transport est réglé directement au transporteur. Ce montant '
    'n’est pas encaissé par SECOTO.',
  'waiver_execution',
    'Je demande expressément que la prestation de mise en relation commence '
    'avant la fin du délai de rétractation.',
  'waiver_withdrawal',
    'Je reconnais qu’une fois la prestation intégralement exécutée, je perdrai '
    'mon droit de rétractation.',
  'refund_policy',
    'Après l’exécution complète de la mise en relation, les frais de réservation '
    'ne sont pas remboursables en cas d’annulation par le client. Ils sont '
    'intégralement remboursés si le transporteur se désiste.',
  'carrier_pricing_notice',
    'Vous fixez librement votre tarif. SECOTO prélève une commission de 20 % '
    'sur le montant de la mission.'
))
on conflict (key) do update set value = excluded.value;

notify pgrst, 'reload schema';

commit;
