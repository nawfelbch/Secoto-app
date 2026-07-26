-- SECOTO - 001 / FONDATIONS SECURISEES
-- Date: 2026-07-26
--
-- AVERTISSEMENT SAUVEGARDE OBLIGATOIRE
-- Executer uniquement apres le preflight 20260726 et apres avoir conserve :
--   * un dump logique du schema public, auth et storage ;
--   * une sauvegarde PITR restaurable ;
--   * les resultats complets du preflight.
--
-- Cette migration est additive et ne supprime aucune ligne ni aucun objet
-- Storage. Elle preserve les anciennes URL pour audit et ajoute file_path
-- comme reference privee. Toute incompatibilite de schema annule la transaction.

begin;

create extension if not exists pgcrypto with schema extensions;

do $guard$
declare
  v_relation text;
  v_required_relations constant text[] := array[
    'public.accounts',
    'public.missions',
    'public.mission_requests',
    'public.mission_applications',
    'public.documents',
    'public.mission_tracking_events',
    'public.mission_tracking_photos',
    'public.frais',
    'public.notifications'
  ];
begin
  foreach v_relation in array v_required_relations loop
    if to_regclass(v_relation) is null then
      raise exception 'SECOTO preflight bloque: relation requise absente: %', v_relation;
    end if;
  end loop;
end
$guard$;

do $guard_columns$
declare
  v_item text;
  v_table text;
  v_column text;
  v_required constant text[] := array[
    'accounts.id', 'accounts.role', 'accounts.full_name', 'accounts.company_name',
    'accounts.email', 'accounts.phone', 'accounts.city', 'accounts.status',
    'accounts.docs_count', 'accounts.is_verified', 'accounts.transporter_type',
    'accounts.client_type', 'accounts.created_at',
    'missions.id', 'missions.public_ref', 'missions.type', 'missions.status',
    'missions.progress_status', 'missions.from_city', 'missions.to_city',
    'missions.pickup_address', 'missions.delivery_address', 'missions.mission_date',
    'missions.vehicle', 'missions.plate', 'missions.distance_km',
    'missions.carrier_cost', 'missions.client_price', 'missions.carrier_pay',
    'missions.margin', 'missions.client_name', 'missions.client_contact',
    'missions.client_phone', 'missions.price_mode', 'missions.proposed_price',
    'missions.payment_method', 'missions.notes', 'missions.created_by_role',
    'missions.client_account_id', 'missions.assigned_transporter_id',
    'missions.assigned_transporter_name', 'missions.source_request_id',
    'missions.created_at',
    'mission_requests.id', 'mission_requests.public_ref',
    'mission_requests.status', 'mission_requests.requester_id',
    'mission_requests.requester_name', 'mission_requests.requester_company',
    'mission_requests.type', 'mission_requests.from_city',
    'mission_requests.to_city', 'mission_requests.pickup_address',
    'mission_requests.delivery_address', 'mission_requests.mission_date',
    'mission_requests.vehicle', 'mission_requests.plate',
    'mission_requests.distance_km', 'mission_requests.client_name',
    'mission_requests.client_contact', 'mission_requests.client_phone',
    'mission_requests.price_mode', 'mission_requests.proposed_price',
    'mission_requests.notes', 'mission_requests.created_by_role',
    'mission_requests.approved_mission_id', 'mission_requests.created_at',
    'mission_applications.id', 'mission_applications.mission_id',
    'mission_applications.transporter_id',
    'mission_applications.transporter_name',
    'mission_applications.transporter_company',
    'mission_applications.transporter_status',
    'mission_applications.message', 'mission_applications.proposed_price',
    'mission_applications.price_note', 'mission_applications.status',
    'mission_applications.created_at',
    'documents.id', 'documents.mission_id', 'documents.account_id',
    'documents.recipient_id', 'documents.type', 'documents.file_name',
    'documents.file_path', 'documents.file_url', 'documents.status',
    'documents.doc_type', 'documents.numero', 'documents.statut',
    'documents.needs_signature', 'documents.signed_at',
    'documents.emitted_at', 'documents.created_at',
    'mission_tracking_events.id', 'mission_tracking_events.mission_id',
    'mission_tracking_events.transporter_id',
    'mission_tracking_events.event_type', 'mission_tracking_events.title',
    'mission_tracking_events.comment', 'mission_tracking_events.odometer_km',
    'mission_tracking_events.fuel_level', 'mission_tracking_events.issue_type',
    'mission_tracking_events.issue_severity',
    'mission_tracking_events.created_at',
    'mission_tracking_photos.id',
    'mission_tracking_photos.tracking_event_id',
    'mission_tracking_photos.mission_id',
    'mission_tracking_photos.transporter_id',
    'mission_tracking_photos.photo_type',
    'mission_tracking_photos.file_name',
    'mission_tracking_photos.file_path',
    'mission_tracking_photos.file_url',
    'mission_tracking_photos.created_at',
    'frais.id', 'frais.mission_id', 'frais.transporter_id',
    'frais.type', 'frais.montant', 'frais.justificatif_url',
    'frais.statut', 'frais.motif_refus', 'frais.date',
    'frais.created_at', 'frais.validated_at', 'frais.validated_by',
    'notifications.id', 'notifications.account_id', 'notifications.type',
    'notifications.title', 'notifications.body', 'notifications.mission_id',
    'notifications.audience', 'notifications.is_read',
    'notifications.created_at'
  ];
begin
  foreach v_item in array v_required loop
    v_table := split_part(v_item, '.', 1);
    v_column := split_part(v_item, '.', 2);
    if not exists (
      select 1
      from information_schema.columns c
      where c.table_schema = 'public'
        and c.table_name = v_table
        and c.column_name = v_column
    ) then
      raise exception 'SECOTO preflight bloque: colonne requise absente: public.%', v_item;
    end if;
  end loop;
end
$guard_columns$;

-- Donnees et references necessaires aux nouveaux parcours.
alter table public.accounts
  add column if not exists deleted_at timestamptz;

alter table public.missions
  add column if not exists assigned_application_id uuid
    references public.mission_applications(id) on delete set null;

alter table public.mission_requests
  add column if not exists decided_at timestamptz,
  add column if not exists decided_by uuid
    references public.accounts(id) on delete set null;

alter table public.mission_applications
  add column if not exists decided_at timestamptz,
  add column if not exists decided_by uuid
    references public.accounts(id) on delete set null;

alter table public.documents
  add column if not exists pdf_url text,
  add column if not exists mime_type text,
  add column if not exists size_bytes bigint,
  add column if not exists idempotency_key uuid;

alter table public.mission_tracking_events
  add column if not exists latitude double precision,
  add column if not exists longitude double precision,
  add column if not exists location_accuracy_m double precision,
  add column if not exists location_recorded_at timestamptz,
  add column if not exists idempotency_key uuid;

alter table public.mission_tracking_photos
  add column if not exists mime_type text,
  add column if not exists size_bytes bigint,
  add column if not exists idempotency_key uuid;

alter table public.frais
  add column if not exists justificatif_path text,
  add column if not exists file_name text,
  add column if not exists mime_type text,
  add column if not exists size_bytes bigint,
  add column if not exists idempotency_key uuid;

alter table public.notifications
  add column if not exists push_screen text,
  add column if not exists event_key text;

-- Les URL historiques sont conservees. On derive uniquement un chemin lorsque
-- son format est reconnu ; aucun objet Storage n'est deplace ou supprime.
update public.documents
set file_path = regexp_replace(
  file_url,
  '^https?://[^/]+/storage/v1/object/public/documents/',
  ''
)
where file_path is null
  and file_url ~* '^https?://[^/]+/storage/v1/object/public/documents/.+';

update public.mission_tracking_photos
set file_path = regexp_replace(
  file_url,
  '^https?://[^/]+/storage/v1/object/public/mission-photos/',
  ''
)
where file_path is null
  and file_url ~* '^https?://[^/]+/storage/v1/object/public/mission-photos/.+';

update public.frais
set justificatif_path = case
  when justificatif_url ~* '^https?://[^/]+/storage/v1/object/public/justificatifs/.+'
    then regexp_replace(
      justificatif_url,
      '^https?://[^/]+/storage/v1/object/public/justificatifs/',
      ''
    )
  when justificatif_url !~* '^https?://' then justificatif_url
  else null
end
where justificatif_path is null
  and justificatif_url is not null;

-- Tarification: regles historiques exactes, calculees en base.
create or replace function public.secoto_compute_client_price(
  p_type text,
  p_distance_km numeric,
  p_carrier_cost numeric
)
returns numeric
language sql
immutable
set search_path = ''
as $function$
  select round(
    case p_type
      when 'plateau' then greatest(coalesce(p_carrier_cost, 0), 0) * 1.20
      when 'convoyage' then greatest(coalesce(p_distance_km, 0), 0) * 1.00
      else 0
    end,
    2
  );
$function$;

create or replace function public.secoto_compute_carrier_pay(
  p_type text,
  p_distance_km numeric,
  p_carrier_cost numeric
)
returns numeric
language sql
immutable
set search_path = ''
as $function$
  select round(
    case p_type
      when 'plateau' then greatest(coalesce(p_carrier_cost, 0), 0)
      when 'convoyage' then greatest(coalesce(p_distance_km, 0), 0) * 0.55
      else 0
    end,
    2
  );
$function$;

create or replace function public.secoto_compute_margin(
  p_type text,
  p_distance_km numeric,
  p_carrier_cost numeric
)
returns numeric
language sql
immutable
set search_path = ''
as $function$
  select round(
    public.secoto_compute_client_price(p_type, p_distance_km, p_carrier_cost)
    - public.secoto_compute_carrier_pay(p_type, p_distance_km, p_carrier_cost),
    2
  );
$function$;

-- Infrastructure de tokens par appareil.
create table if not exists public.device_push_tokens (
  id uuid primary key default gen_random_uuid(),
  account_id uuid not null references public.accounts(id) on delete cascade,
  platform text not null check (platform in ('web', 'android', 'ios')),
  provider text not null check (provider in ('webpush', 'fcm', 'apns')),
  token text,
  endpoint text,
  p256dh text,
  auth_secret text,
  installation_id text not null,
  device_label text,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  last_used_at timestamptz not null default now(),
  constraint device_push_tokens_provider_payload_check check (
    (provider = 'webpush'
      and endpoint is not null
      and p256dh is not null
      and auth_secret is not null
      and token is null)
    or
    (provider in ('fcm', 'apns')
      and token is not null
      and endpoint is null
      and p256dh is null
      and auth_secret is null)
  ),
  constraint device_push_tokens_platform_provider_check check (
    (platform = 'web' and provider = 'webpush')
    or (platform = 'android' and provider = 'fcm')
    or (platform = 'ios' and provider = 'apns')
  ),
  constraint device_push_tokens_installation_length check (
    length(installation_id) between 16 and 200
  )
);

create unique index if not exists uq_device_push_account_installation
  on public.device_push_tokens(account_id, provider, installation_id);
create index if not exists idx_device_push_active_account
  on public.device_push_tokens(account_id, is_active)
  where is_active;
create index if not exists idx_device_push_native_token
  on public.device_push_tokens(provider, token)
  where token is not null;
create index if not exists idx_device_push_web_endpoint
  on public.device_push_tokens(endpoint)
  where endpoint is not null;

-- Compatibilite non destructive avec les abonnements Web Push historiques.
-- Les lignes sont migrees vers device_push_tokens par la migration 003.
create table if not exists public.push_subscriptions (
  id uuid primary key default gen_random_uuid(),
  account_id uuid not null references public.accounts(id) on delete cascade,
  role text,
  endpoint text not null,
  p256dh text not null,
  auth text not null,
  user_agent text,
  created_at timestamptz not null default now()
);

-- Transactional outbox: la notification interne est creee dans la meme
-- transaction que l'evenement metier. Le transport APNs/FCM/Web Push est repris
-- de facon idempotente par la fonction serveur.
create table if not exists public.push_outbox (
  id uuid primary key default gen_random_uuid(),
  notification_id uuid not null references public.notifications(id) on delete cascade,
  event_key text not null,
  status text not null default 'pending'
    check (status in ('pending', 'processing', 'sent', 'failed')),
  attempts integer not null default 0 check (attempts >= 0),
  max_attempts integer not null default 8 check (max_attempts between 1 and 20),
  available_at timestamptz not null default now(),
  locked_at timestamptz,
  sent_at timestamptz,
  last_error text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create unique index if not exists uq_push_outbox_event_key
  on public.push_outbox(event_key);
create index if not exists idx_push_outbox_dispatch
  on public.push_outbox(status, available_at, created_at);

-- Etat par appareil : un succès partiel ne masque jamais l'échec d'un autre
-- appareil et une reprise n'envoie pas deux fois aux appareils déjà servis.
create table if not exists public.push_deliveries (
  id uuid primary key default gen_random_uuid(),
  outbox_id uuid not null
    references public.push_outbox(id) on delete cascade,
  device_token_id uuid not null
    references public.device_push_tokens(id) on delete cascade,
  status text not null default 'pending'
    check (status in ('pending', 'processing', 'sent', 'skipped', 'failed')),
  attempts integer not null default 0 check (attempts >= 0),
  max_attempts integer not null default 5 check (max_attempts between 1 and 20),
  available_at timestamptz not null default now(),
  last_error text,
  sent_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(outbox_id, device_token_id)
);

create index if not exists idx_push_deliveries_retry
  on public.push_deliveries(outbox_id, status, available_at);

-- Registre commun d'idempotence. actor_key vaut l'UUID du compte ou "anon"
-- pour le formulaire public ; un verrou transactionnel ferme les courses.
create table if not exists public.secoto_idempotency (
  actor_key text not null,
  operation text not null,
  idempotency_key uuid not null,
  response jsonb not null,
  created_at timestamptz not null default now(),
  primary key (actor_key, operation, idempotency_key)
);

create index if not exists idx_secoto_idempotency_created
  on public.secoto_idempotency(created_at);

create table if not exists public.account_deletion_requests (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null,
  idempotency_key uuid not null,
  status text not null default 'prepared'
    check (status in (
      'prepared', 'processing', 'auth_pending', 'failed', 'completed'
    )),
  storage_objects jsonb not null default '[]'::jsonb,
  last_error text,
  requested_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  completed_at timestamptz,
  unique(user_id, idempotency_key)
);

alter table public.account_deletion_requests
  drop constraint if exists account_deletion_requests_status_check;
alter table public.account_deletion_requests
  add constraint account_deletion_requests_status_check
  check (status in (
    'prepared', 'processing', 'auth_pending', 'failed', 'completed'
  ));

create index if not exists idx_account_deletion_user_status
  on public.account_deletion_requests(user_id, status, requested_at desc);

-- Index critiques. Si des doublons historiques existent, la transaction
-- s'annule ; ils doivent etre examines manuellement a partir du preflight.
create unique index if not exists uq_mission_application_actor
  on public.mission_applications(mission_id, transporter_id);
create unique index if not exists uq_tracking_event_idempotency
  on public.mission_tracking_events(transporter_id, idempotency_key)
  where idempotency_key is not null;
create unique index if not exists uq_tracking_photo_idempotency
  on public.mission_tracking_photos(transporter_id, idempotency_key, file_path)
  where idempotency_key is not null;
create unique index if not exists uq_document_idempotency
  on public.documents(account_id, idempotency_key)
  where idempotency_key is not null and doc_type is null;
create unique index if not exists uq_frais_idempotency
  on public.frais(transporter_id, idempotency_key)
  where idempotency_key is not null;
create unique index if not exists uq_notification_event_key
  on public.notifications(event_key)
  where event_key is not null;

create index if not exists idx_missions_client_created
  on public.missions(client_account_id, created_at desc);
create index if not exists idx_missions_transporter_created
  on public.missions(assigned_transporter_id, created_at desc);
create index if not exists idx_missions_public_feed
  on public.missions(status, created_at desc);
create index if not exists idx_requests_requester_created
  on public.mission_requests(requester_id, created_at desc);
create index if not exists idx_applications_transporter_created
  on public.mission_applications(transporter_id, created_at desc);
create index if not exists idx_tracking_events_mission_created
  on public.mission_tracking_events(mission_id, created_at desc);
create index if not exists idx_tracking_photos_mission_created
  on public.mission_tracking_photos(mission_id, created_at desc);
create index if not exists idx_documents_account_created
  on public.documents(account_id, created_at desc);
create index if not exists idx_frais_mission_created
  on public.frais(mission_id, created_at desc);

-- Helpers non exposes par l'API.
create schema if not exists secoto_private;
revoke all on schema secoto_private from public, anon, authenticated;

create or replace function secoto_private.actor_key()
returns text
language sql
stable
security invoker
set search_path = ''
as $function$
  select coalesce(auth.uid()::text, 'anon');
$function$;

create or replace function secoto_private.account_role(p_user_id uuid default auth.uid())
returns text
language sql
stable
security definer
set search_path = ''
as $function$
  select a.role::text
  from public.accounts a
  where a.id = p_user_id
    and a.deleted_at is null;
$function$;

create or replace function secoto_private.is_admin(p_user_id uuid default auth.uid())
returns boolean
language sql
stable
security definer
set search_path = ''
as $function$
  select coalesce(secoto_private.account_role(p_user_id) = 'admin', false);
$function$;

create or replace function secoto_private.is_verified_transporter(
  p_user_id uuid default auth.uid()
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
    where a.id = p_user_id
      and a.role::text = 'transporter'
      and a.status::text = 'active'
      and coalesce(a.is_verified, false)
      and a.deleted_at is null
  );
$function$;

create or replace function secoto_private.assert_authenticated()
returns uuid
language plpgsql
stable
security invoker
set search_path = ''
as $function$
declare
  v_user_id uuid := auth.uid();
begin
  if v_user_id is null then
    raise exception using
      errcode = '42501',
      message = 'Authentification requise.';
  end if;
  return v_user_id;
end;
$function$;

create or replace function secoto_private.assert_admin()
returns uuid
language plpgsql
stable
security definer
set search_path = ''
as $function$
declare
  v_user_id uuid := auth.uid();
begin
  if v_user_id is null or not secoto_private.is_admin(v_user_id) then
    raise exception using
      errcode = '42501',
      message = 'Operation reservee a un administrateur SECOTO.';
  end if;
  return v_user_id;
end;
$function$;

create or replace function secoto_private.lock_operation(
  p_operation text,
  p_idempotency_key uuid
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $function$
declare
  v_actor text := secoto_private.actor_key();
  v_response jsonb;
begin
  if p_idempotency_key is null then
    raise exception using
      errcode = '22023',
      message = 'Identifiant d''idempotence obligatoire.';
  end if;
  if p_operation is null or length(p_operation) not between 1 and 100 then
    raise exception using
      errcode = '22023',
      message = 'Operation d''idempotence invalide.';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(
      v_actor || ':' || p_operation || ':' || p_idempotency_key::text,
      0
    )
  );

  select i.response
  into v_response
  from public.secoto_idempotency i
  where i.actor_key = v_actor
    and i.operation = p_operation
    and i.idempotency_key = p_idempotency_key;

  return v_response;
end;
$function$;

create or replace function secoto_private.finish_operation(
  p_operation text,
  p_idempotency_key uuid,
  p_response jsonb
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $function$
begin
  if p_response is null then
    raise exception 'Une reponse idempotente non nulle est obligatoire.';
  end if;

  insert into public.secoto_idempotency(
    actor_key,
    operation,
    idempotency_key,
    response
  )
  values (
    secoto_private.actor_key(),
    p_operation,
    p_idempotency_key,
    p_response
  )
  on conflict (actor_key, operation, idempotency_key)
  do update set response = public.secoto_idempotency.response;

  return p_response;
end;
$function$;

create or replace function secoto_private.safe_text(
  p_payload jsonb,
  p_key text,
  p_max_length integer,
  p_required boolean default false
)
returns text
language plpgsql
immutable
security invoker
set search_path = ''
as $function$
declare
  v_value text := nullif(btrim(coalesce(p_payload ->> p_key, '')), '');
begin
  if p_required and v_value is null then
    raise exception using
      errcode = '22023',
      message = format('Champ obligatoire absent: %s.', p_key);
  end if;
  if v_value is not null and length(v_value) > p_max_length then
    raise exception using
      errcode = '22023',
      message = format('Champ trop long: %s.', p_key);
  end if;
  return v_value;
end;
$function$;

create or replace function secoto_private.safe_numeric(
  p_payload jsonb,
  p_key text,
  p_min numeric,
  p_max numeric,
  p_default numeric default null
)
returns numeric
language plpgsql
immutable
security invoker
set search_path = ''
as $function$
declare
  v_raw text := nullif(btrim(coalesce(p_payload ->> p_key, '')), '');
  v_value numeric;
begin
  if v_raw is null then
    return p_default;
  end if;
  begin
    v_value := v_raw::numeric;
  exception when invalid_text_representation or numeric_value_out_of_range then
    raise exception using
      errcode = '22023',
      message = format('Montant ou nombre invalide: %s.', p_key);
  end;
  if v_value < p_min or v_value > p_max then
    raise exception using
      errcode = '22023',
      message = format('Valeur hors limites: %s.', p_key);
  end if;
  return v_value;
end;
$function$;

create or replace function secoto_private.new_public_ref(p_prefix text)
returns text
language plpgsql
volatile
security definer
set search_path = ''
as $function$
declare
  v_ref text;
begin
  if p_prefix not in ('MIS', 'REQ') then
    raise exception 'Prefixe de reference invalide.';
  end if;
  loop
    v_ref := p_prefix || '-' || to_char(now(), 'YYYY') || '-'
      || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 8));
    exit when
      not exists (select 1 from public.missions m where m.public_ref = v_ref)
      and not exists (
        select 1 from public.mission_requests r where r.public_ref = v_ref
      );
  end loop;
  return v_ref;
end;
$function$;

create or replace function secoto_private.can_read_mission(p_mission_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $function$
  select exists (
    select 1
    from public.missions m
    where m.id = p_mission_id
      and (
        secoto_private.is_admin(auth.uid())
        or m.client_account_id = auth.uid()
        or m.assigned_transporter_id = auth.uid()
      )
  );
$function$;

create or replace function secoto_private.can_write_mission_file(p_mission_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $function$
  select exists (
    select 1
    from public.missions m
    where m.id = p_mission_id
      and m.assigned_transporter_id = auth.uid()
      and m.status::text in ('assigned', 'completed')
  );
$function$;

create or replace function secoto_private.can_read_document_path(
  p_path text,
  p_generated boolean
)
returns boolean
language sql
stable
security definer
set search_path = ''
as $function$
  select exists (
    select 1
    from public.documents d
    where coalesce(d.file_path, d.pdf_url) = p_path
      and (
        secoto_private.is_admin(auth.uid())
        or (not p_generated and d.account_id = auth.uid())
        or (
          p_generated
          and d.recipient_id = auth.uid()
          and d.statut::text <> 'brouillon'
        )
        or (
          d.mission_id is not null
          and secoto_private.can_read_mission(d.mission_id)
          and (
            (secoto_private.account_role(auth.uid()) = 'client'
              and d.doc_type::text in ('devis', 'facture'))
            or
            (secoto_private.account_role(auth.uid()) = 'transporter'
              and d.doc_type::text = 'bon_de_mission')
          )
        )
      )
  );
$function$;

create or replace function public.secoto_is_admin()
returns boolean
language sql
stable
security definer
set search_path = ''
as $function$
  select secoto_private.is_admin(auth.uid());
$function$;

revoke all on all tables in schema secoto_private from public, anon, authenticated;
revoke all on all sequences in schema secoto_private from public, anon, authenticated;
revoke all on all functions in schema secoto_private from public, anon, authenticated;
revoke all on function public.secoto_is_admin() from public, anon, authenticated;

alter table public.device_push_tokens enable row level security;
alter table public.push_outbox enable row level security;
alter table public.push_deliveries enable row level security;
alter table public.secoto_idempotency enable row level security;
alter table public.account_deletion_requests enable row level security;

comment on table public.device_push_tokens is
  'Tokens Web Push, FCM et APNs rattaches a un compte et une installation.';
comment on table public.push_outbox is
  'Outbox transactionnelle des notifications systeme, sans contenu sensible.';
comment on table public.secoto_idempotency is
  'Reponses des operations metier protegees contre les doubles appels.';
comment on table public.account_deletion_requests is
  'Journal technique des demandes de suppression et de leur reprise.';

notify pgrst, 'reload schema';
commit;
