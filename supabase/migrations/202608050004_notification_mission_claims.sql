-- SECOTO 1.1 — rattachement sécurisé des missions créées par l'admin
-- Date : 2026-08-05
-- À exécuter dans le SQL Editor Supabase (projet SECOTO).
-- Idempotent : le fichier peut être rejoué.

begin;

create extension if not exists pgcrypto with schema extensions;

create table if not exists public.mission_claims (
  id uuid primary key default gen_random_uuid(),
  mission_id uuid not null references public.missions(id) on delete cascade,
  token_hash text not null unique,
  token_hint text not null,
  status text not null default 'pending'
    check (status in ('pending', 'claimed', 'revoked', 'expired')),
  expires_at timestamptz not null,
  claimed_by_account_id uuid references public.accounts(id) on delete set null,
  claimed_at timestamptz,
  created_by uuid not null references public.accounts(id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint mission_claims_claimed_state_check check (
    (status = 'claimed' and claimed_by_account_id is not null and claimed_at is not null)
    or
    (status <> 'claimed')
  )
);

create unique index if not exists uq_mission_claims_one_pending_per_mission
  on public.mission_claims(mission_id)
  where status = 'pending';

create index if not exists idx_mission_claims_expiry
  on public.mission_claims(status, expires_at);

create index if not exists idx_mission_claims_claimed_account
  on public.mission_claims(claimed_by_account_id)
  where claimed_by_account_id is not null;

alter table public.mission_claims enable row level security;

-- Aucune écriture directe depuis l'application : tout passe par des RPC
-- SECURITY DEFINER, contrôlées et atomiques.
revoke all on table public.mission_claims from anon, authenticated;

-- L'admin génère ou renouvelle un lien à usage unique.
create or replace function public.secoto_generate_mission_claim(
  p_mission_id uuid,
  p_expires_in_days integer default 30
)
returns table (
  token text,
  mission_id uuid,
  public_ref text,
  expires_at timestamptz
)
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $function$
declare
  v_token text;
  v_token_hash text;
  v_public_ref text;
  v_client_account_id uuid;
  v_expiry timestamptz;
begin
  if auth.uid() is null or not public.secoto_is_admin() then
    raise exception 'Accès réservé à SECOTO.' using errcode = '42501';
  end if;

  if p_expires_in_days is null or p_expires_in_days < 1 or p_expires_in_days > 90 then
    raise exception 'La durée du lien doit être comprise entre 1 et 90 jours.';
  end if;

  select m.public_ref, m.client_account_id
    into v_public_ref, v_client_account_id
  from public.missions m
  where m.id = p_mission_id
  for update;

  if not found then
    raise exception 'Mission introuvable.' using errcode = 'P0002';
  end if;

  if v_client_account_id is not null then
    raise exception 'Cette mission est déjà rattachée à un compte client.';
  end if;

  update public.mission_claims
  set status = 'revoked', updated_at = now()
  where mission_claims.mission_id = p_mission_id
    and status = 'pending';

  -- 32 octets aléatoires, URL-safe. Le token brut n'est jamais stocké.
  v_token := translate(
    rtrim(encode(extensions.gen_random_bytes(32), 'base64'), '='),
    '+/',
    '-_'
  );
  v_token_hash := encode(extensions.digest(v_token, 'sha256'), 'hex');
  v_expiry := now() + make_interval(days => p_expires_in_days);

  insert into public.mission_claims (
    mission_id,
    token_hash,
    token_hint,
    status,
    expires_at,
    created_by
  ) values (
    p_mission_id,
    v_token_hash,
    right(v_token, 6),
    'pending',
    v_expiry,
    auth.uid()
  );

  return query
  select v_token, p_mission_id, v_public_ref, v_expiry;
end;
$function$;

-- Le client connecté rattache la mission à son compte avec le token secret.
create or replace function public.secoto_claim_mission(p_token text)
returns table (
  mission_id uuid,
  public_ref text,
  claimed_at timestamptz
)
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $function$
declare
  v_actor uuid := auth.uid();
  v_role text;
  v_status text;
  v_claim public.mission_claims%rowtype;
  v_public_ref text;
  v_current_client uuid;
  v_now timestamptz := now();
begin
  if v_actor is null then
    raise exception 'Connectez-vous pour rattacher la course.' using errcode = '42501';
  end if;

  select a.role, a.status
    into v_role, v_status
  from public.accounts a
  where a.id = v_actor
    and a.deleted_at is null;

  if not found or v_role <> 'client' then
    raise exception 'Un compte client est nécessaire.' using errcode = '42501';
  end if;

  if v_status = 'suspended' then
    raise exception 'Ce compte est suspendu.' using errcode = '42501';
  end if;

  p_token := trim(coalesce(p_token, ''));
  if length(p_token) < 32 or length(p_token) > 200 then
    raise exception 'Code de rattachement invalide.';
  end if;

  select mc.*
    into v_claim
  from public.mission_claims mc
  where mc.token_hash = encode(extensions.digest(p_token, 'sha256'), 'hex')
  for update;

  if not found then
    raise exception 'Lien de rattachement invalide ou déjà remplacé.' using errcode = 'P0002';
  end if;

  if v_claim.status <> 'pending' then
    raise exception 'Ce lien a déjà été utilisé ou désactivé.';
  end if;

  if v_claim.expires_at <= v_now then
    update public.mission_claims
      set status = 'expired', updated_at = v_now
    where id = v_claim.id;
    raise exception 'Ce lien a expiré. Demandez un nouveau lien à SECOTO.';
  end if;

  select m.public_ref, m.client_account_id
    into v_public_ref, v_current_client
  from public.missions m
  where m.id = v_claim.mission_id
  for update;

  if not found then
    raise exception 'Mission introuvable.' using errcode = 'P0002';
  end if;

  if v_current_client is not null and v_current_client <> v_actor then
    raise exception 'Cette mission est déjà rattachée à un autre compte.' using errcode = '42501';
  end if;

  update public.missions
  set client_account_id = v_actor
  where id = v_claim.mission_id;

  update public.mission_claims
  set status = 'claimed',
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
    'mission_claimed',
    'Transport rattaché',
    'Votre transport ' || v_public_ref || ' est maintenant visible dans votre espace SECOTO.',
    v_claim.mission_id,
    'client',
    false,
    'courses',
    'mission_claimed:' || v_claim.mission_id::text || ':' || v_actor::text
  ) on conflict do nothing;

  return query
  select v_claim.mission_id, v_public_ref, v_now;
end;
$function$;

-- L'admin peut invalider le lien courant sans supprimer la mission.
create or replace function public.secoto_revoke_mission_claim(p_mission_id uuid)
returns boolean
language plpgsql
security definer
set search_path = public, pg_temp
as $function$
declare
  v_count integer;
begin
  if auth.uid() is null or not public.secoto_is_admin() then
    raise exception 'Accès réservé à SECOTO.' using errcode = '42501';
  end if;

  update public.mission_claims
  set status = 'revoked', updated_at = now()
  where mission_claims.mission_id = p_mission_id
    and status = 'pending';

  get diagnostics v_count = row_count;
  return v_count > 0;
end;
$function$;

revoke all on function public.secoto_generate_mission_claim(uuid, integer) from public, anon;
revoke all on function public.secoto_claim_mission(text) from public, anon;
revoke all on function public.secoto_revoke_mission_claim(uuid) from public, anon;

grant execute on function public.secoto_generate_mission_claim(uuid, integer) to authenticated;
grant execute on function public.secoto_claim_mission(text) to authenticated;
grant execute on function public.secoto_revoke_mission_claim(uuid) to authenticated;

comment on table public.mission_claims is
  'Liens à usage unique permettant à un client connecté de rattacher une mission créée par SECOTO à son compte.';
comment on function public.secoto_generate_mission_claim(uuid, integer) is
  'Génère un token client aléatoire, ne stocke que son SHA-256 et invalide le précédent.';
comment on function public.secoto_claim_mission(text) is
  'Rattache atomiquement la mission au compte client authentifié puis consomme le token.';

commit;
