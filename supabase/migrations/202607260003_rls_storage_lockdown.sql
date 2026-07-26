-- SECOTO - 003 / RLS, STORAGE PRIVE, AUTH ET GRANTS
-- Date: 2026-07-26
--
-- Executer immediatement apres 001 puis 002. Cette transaction remplace les
-- policies permissives et les anciens triggers push, sans supprimer de donnee.

begin;

do $guard$
begin
  if to_regprocedure(
    'public.secoto_create_client_mission(jsonb,uuid)'
  ) is null then
    raise exception 'Migration SECOTO 002 requise avant la migration 003.';
  end if;
end
$guard$;

revoke create on schema public from public, anon, authenticated;

-- Bucket prives et limites serveur. Aucun objet existant n'est supprime.
insert into storage.buckets(id, name, public, file_size_limit, allowed_mime_types)
values
  (
    'documents',
    'documents',
    false,
    12582912,
    array['image/jpeg','image/png','image/webp','application/pdf']
  ),
  (
    'mission-photos',
    'mission-photos',
    false,
    12582912,
    array['image/jpeg','image/png','image/webp','application/pdf']
  ),
  (
    'justificatifs',
    'justificatifs',
    false,
    12582912,
    array['image/jpeg','image/png','image/webp','application/pdf']
  ),
  (
    'documents-pdf',
    'documents-pdf',
    false,
    12582912,
    array['application/pdf','text/html']
  )
on conflict (id) do update set
  public = false,
  file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

-- Conservation non destructive des abonnements Web historiques.
insert into public.device_push_tokens(
  account_id,
  platform,
  provider,
  endpoint,
  p256dh,
  auth_secret,
  installation_id,
  device_label,
  is_active,
  created_at,
  updated_at,
  last_used_at
)
select
  p.account_id,
  'web',
  'webpush',
  p.endpoint,
  p.p256dh,
  p.auth,
  'legacy-' || substr(
    encode(
      extensions.digest(p.account_id::text || ':' || p.endpoint, 'sha256'),
      'hex'
    ),
    1,
    40
  ),
  left(coalesce(p.user_agent, 'Abonnement Web historique'), 240),
  true,
  p.created_at,
  now(),
  now()
from public.push_subscriptions p
on conflict (account_id, provider, installation_id)
do update set
  endpoint = excluded.endpoint,
  p256dh = excluded.p256dh,
  auth_secret = excluded.auth_secret,
  device_label = excluded.device_label,
  is_active = true,
  updated_at = now();

-- Suppression des automatisations historiques concurrentes ou non securisees.
drop trigger if exists trg_secoto_notification_push on public.notifications;
drop trigger if exists trg_secoto_notifications_legacy on public.notifications;
drop trigger if exists trg_secoto_application_notify on public.mission_applications;
drop trigger if exists trg_secoto_frais_notify on public.frais;
drop trigger if exists trg_secoto_frais_status_notify on public.frais;
drop trigger if exists trg_secoto_request_notify on public.mission_requests;
drop trigger if exists trg_secoto_mission_published_notify on public.missions;
drop trigger if exists trg_secoto_tracking_notify on public.mission_tracking_events;
drop trigger if exists trg_secoto_tracking_apply on public.mission_tracking_events;

create or replace function secoto_private.prepare_notification()
returns trigger
language plpgsql
volatile
security definer
set search_path = ''
as $function$
begin
  new.push_screen := case
    when new.push_screen in (
      'courses','documents','frais','available','assigned',
      'applications','requests'
    ) then new.push_screen
    when new.type = 'document' then 'documents'
    when new.type in ('frais','frais_status') then 'frais'
    when new.type = 'new_application' then 'applications'
    when new.type = 'new_request' then 'requests'
    when new.type = 'new_course' then 'available'
    when new.type in ('tracking','delivered','course_assigned') then 'courses'
    else 'courses'
  end;
  new.event_key := coalesce(
    new.event_key,
    'notification:' || new.id::text
  );
  return new;
end;
$function$;

create or replace function secoto_private.enqueue_push_outbox()
returns trigger
language plpgsql
volatile
security definer
set search_path = ''
as $function$
begin
  insert into public.push_outbox(
    notification_id,
    event_key,
    status,
    available_at
  )
  values (
    new.id,
    'push:' || new.event_key,
    'pending',
    now()
  )
  on conflict (event_key) do nothing;
  return new;
end;
$function$;

create trigger trg_secoto_notification_prepare
  before insert on public.notifications
  for each row execute function secoto_private.prepare_notification();

create trigger trg_secoto_notification_outbox
  after insert on public.notifications
  for each row execute function secoto_private.enqueue_push_outbox();

-- Une politique dediee distingue les preuves terrain des frais post-livraison.
create or replace function secoto_private.can_upload_tracking_file(
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
    from public.missions m
    where m.id = p_mission_id
      and m.assigned_transporter_id = auth.uid()
      and m.status::text = 'assigned'
  );
$function$;

create or replace function secoto_private.current_role()
returns text
language sql
stable
security definer
set search_path = ''
as $function$
  select secoto_private.account_role(auth.uid());
$function$;

create or replace function secoto_private.current_is_admin()
returns boolean
language sql
stable
security definer
set search_path = ''
as $function$
  select secoto_private.is_admin(auth.uid());
$function$;

-- Inscription: seuls client et transporter sont acceptes depuis les metadata.
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
    client_type
  )
  values (
    new.id,
    new.email,
    v_role,
    left(coalesce(
      nullif(btrim(new.raw_user_meta_data ->> 'full_name'), ''),
      split_part(coalesce(new.email, 'utilisateur'), '@', 1)
    ), 160),
    left(nullif(btrim(new.raw_user_meta_data ->> 'company_name'), ''), 200),
    left(nullif(btrim(new.raw_user_meta_data ->> 'phone'), ''), 40),
    left(nullif(btrim(new.raw_user_meta_data ->> 'city'), ''), 160),
    case when v_role = 'transporter' then 'pending' else 'active' end,
    0,
    false,
    v_transporter_type,
    v_client_type
  )
  on conflict (id) do nothing;
  return new;
end;
$function$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

create table if not exists public.doc_counters (
  prefix text not null,
  period text not null,
  last_num integer not null default 0,
  primary key(prefix, period)
);

create or replace function public.secoto_next_doc_number(
  p_type public.secoto_doc_type
)
returns text
language plpgsql
volatile
security definer
set search_path = ''
as $function$
declare
  v_prefix text;
  v_period text := to_char(now(), 'YYYYMM');
  v_number integer;
begin
  perform secoto_private.assert_admin();
  v_prefix := case p_type::text
    when 'devis' then 'DEV'
    when 'bon_de_mission' then 'BM'
    when 'facture' then 'FAC'
    else null
  end;
  if v_prefix is null then raise exception 'Type de document invalide.'; end if;

  insert into public.doc_counters(prefix, period, last_num)
  values (v_prefix, v_period, 1)
  on conflict (prefix, period)
  do update set last_num = public.doc_counters.last_num + 1
  returning last_num into v_number;

  return format(
    '%s-%s-%s',
    v_prefix,
    v_period,
    lpad(v_number::text, 3, '0')
  );
end;
$function$;

create or replace function public.secoto_sign_document(
  p_doc uuid,
  p_signature jsonb
)
returns public.documents
language plpgsql
volatile
security definer
set search_path = ''
as $function$
declare
  v_document public.documents%rowtype;
  v_data_url text := p_signature ->> 'data_url';
  v_signer text := nullif(btrim(p_signature ->> 'signer_name'), '');
  v_safe_signature jsonb;
begin
  perform secoto_private.assert_authenticated();
  select * into v_document
  from public.documents d
  where d.id = p_doc
  for update;
  if not found then raise exception 'Document introuvable.'; end if;
  if v_document.recipient_id is distinct from auth.uid() then
    raise exception 'Ce document ne vous est pas destine.';
  end if;
  if v_document.statut::text not in ('envoye') then
    raise exception 'Document non disponible ou deja signe.';
  end if;
  if v_signer is null or length(v_signer) > 160 then
    raise exception 'Nom du signataire invalide.';
  end if;
  if v_data_url is null
     or length(v_data_url) > 600000
     or v_data_url !~ '^data:image/png;base64,[A-Za-z0-9+/]+={0,2}$' then
    raise exception 'Signature PNG invalide ou trop volumineuse.';
  end if;

  v_safe_signature := jsonb_build_object(
    'data_url', v_data_url,
    'signer_name', v_signer,
    'signed_at', now()
  );

  update public.documents
  set
    signature_client = case
      when doc_type::text = 'bon_de_mission'
        then signature_client
      else v_safe_signature
    end,
    signature_transporteur = case
      when doc_type::text = 'bon_de_mission'
        then v_safe_signature
      else signature_transporteur
    end,
    statut = 'signe'::public.secoto_doc_statut,
    signed_at = now()
  where id = p_doc
  returning * into v_document;
  return v_document;
end;
$function$;

-- Chaque table exposee est fermee puis recoit une policy explicite.
do $drop_public_policies$
declare
  v_policy record;
  v_tables constant text[] := array[
    'accounts','missions','mission_requests','mission_applications',
    'documents','mission_tracking_events','mission_tracking_photos',
    'frais','notifications','push_subscriptions','device_push_tokens',
    'push_outbox','push_deliveries','secoto_idempotency',
    'account_deletion_requests'
  ];
begin
  for v_policy in
    select schemaname, tablename, policyname
    from pg_policies
    where schemaname = 'public'
      and tablename = any(v_tables)
  loop
    execute format(
      'drop policy if exists %I on %I.%I',
      v_policy.policyname,
      v_policy.schemaname,
      v_policy.tablename
    );
  end loop;
end
$drop_public_policies$;

alter table public.accounts enable row level security;
alter table public.missions enable row level security;
alter table public.mission_requests enable row level security;
alter table public.mission_applications enable row level security;
alter table public.documents enable row level security;
alter table public.mission_tracking_events enable row level security;
alter table public.mission_tracking_photos enable row level security;
alter table public.frais enable row level security;
alter table public.notifications enable row level security;
alter table public.push_subscriptions enable row level security;
alter table public.device_push_tokens enable row level security;
alter table public.push_outbox enable row level security;
alter table public.push_deliveries enable row level security;
alter table public.secoto_idempotency enable row level security;
alter table public.account_deletion_requests enable row level security;

create policy accounts_read_authorized on public.accounts
for select to authenticated
using (id = auth.uid() or secoto_private.current_is_admin());

create policy missions_rows_authorized on public.missions
for select to authenticated
using (
  secoto_private.current_is_admin()
  or client_account_id = auth.uid()
  or assigned_transporter_id = auth.uid()
);

create policy requests_read_authorized on public.mission_requests
for select to authenticated
using (
  secoto_private.current_is_admin()
  or requester_id = auth.uid()
);

create policy applications_read_authorized on public.mission_applications
for select to authenticated
using (
  secoto_private.current_is_admin()
  or transporter_id = auth.uid()
);

create policy documents_read_authorized on public.documents
for select to authenticated
using (
  secoto_private.current_is_admin()
  or (doc_type is null and account_id = auth.uid())
  or (
    recipient_id = auth.uid()
    and statut::text <> 'brouillon'
  )
  or (
    mission_id is not null
    and secoto_private.can_read_mission(mission_id)
    and (
      (secoto_private.current_role() = 'client'
        and doc_type::text in ('devis', 'facture'))
      or
      (secoto_private.current_role() = 'transporter'
        and doc_type::text = 'bon_de_mission'
        and statut::text <> 'brouillon')
    )
  )
);

create policy tracking_events_read_authorized
on public.mission_tracking_events
for select to authenticated
using (secoto_private.can_read_mission(mission_id));

create policy tracking_photos_read_authorized
on public.mission_tracking_photos
for select to authenticated
using (secoto_private.can_read_mission(mission_id));

create policy expenses_read_authorized on public.frais
for select to authenticated
using (
  secoto_private.current_is_admin()
  or transporter_id = auth.uid()
);

create policy notifications_read_own on public.notifications
for select to authenticated
using (account_id = auth.uid());

create policy notifications_mark_read_own on public.notifications
for update to authenticated
using (account_id = auth.uid())
with check (account_id = auth.uid());

-- Aucun acces direct aux missions financieres ni aux tables techniques.
revoke all on table public.accounts from anon, authenticated;
revoke all on table public.missions from anon, authenticated;
revoke all on table public.mission_requests from anon, authenticated;
revoke all on table public.mission_applications from anon, authenticated;
revoke all on table public.documents from anon, authenticated;
revoke all on table public.mission_tracking_events from anon, authenticated;
revoke all on table public.mission_tracking_photos from anon, authenticated;
revoke all on table public.frais from anon, authenticated;
revoke all on table public.notifications from anon, authenticated;
revoke all on table public.push_subscriptions from anon, authenticated;
revoke all on table public.device_push_tokens from anon, authenticated;
revoke all on table public.push_outbox from anon, authenticated;
revoke all on table public.push_deliveries from anon, authenticated;
revoke all on table public.secoto_idempotency from anon, authenticated;
revoke all on table public.account_deletion_requests from anon, authenticated;

grant select on table public.accounts to authenticated;
grant select on table public.mission_requests to authenticated;
grant select on table public.mission_applications to authenticated;
grant select on table public.documents to authenticated;
grant select on table public.mission_tracking_events to authenticated;
grant select on table public.mission_tracking_photos to authenticated;
grant select on table public.frais to authenticated;
grant select on table public.notifications to authenticated;
grant update(is_read) on table public.notifications to authenticated;

grant select on table public.secoto_missions_admin_v2 to authenticated;
grant select on table public.secoto_missions_client_v2 to authenticated;
grant select on table public.secoto_missions_transporter_v2 to authenticated;
grant select on table public.secoto_public_missions_v2 to authenticated;

-- Par defaut, aucune SECURITY DEFINER du schema public n'est appelable. La
-- whitelist utile est reaccordee explicitement ci-dessous.
do $revoke_all_definers$
declare
  v_function record;
begin
  for v_function in
    select p.oid::regprocedure as signature
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.prosecdef
  loop
    execute format(
      'revoke all on function %s from public, anon, authenticated',
      v_function.signature
    );
  end loop;
end
$revoke_all_definers$;

-- API anonyme minimale.
grant execute on function public.secoto_create_public_request(jsonb, uuid)
  to anon;

-- API authentifiee. Les fonctions verifient ensuite le role et la propriete.
grant execute on function public.secoto_create_mission(jsonb, uuid)
  to authenticated;
grant execute on function public.secoto_create_client_mission(jsonb, uuid)
  to authenticated;
grant execute on function public.secoto_create_transporter_request(jsonb, uuid)
  to authenticated;
grant execute on function public.secoto_apply_to_mission(uuid, numeric, text, uuid)
  to authenticated;
grant execute on function public.secoto_assign_mission(uuid, uuid, uuid)
  to authenticated;
grant execute on function public.secoto_transition_mission(uuid, text, uuid)
  to authenticated;
grant execute on function public.secoto_delete_unstarted_mission(uuid, uuid)
  to authenticated;
grant execute on function public.secoto_approve_request(uuid, uuid)
  to authenticated;
grant execute on function public.secoto_reject_request(uuid, uuid)
  to authenticated;
grant execute on function public.secoto_admin_set_transporter_status(
  uuid, text, boolean, integer, uuid
) to authenticated;
grant execute on function public.secoto_admin_set_document_status(
  uuid, text, uuid
) to authenticated;
grant execute on function public.secoto_register_transporter_document(
  text, text, text, text, bigint, uuid
) to authenticated;
grant execute on function public.secoto_finalize_tracking_event(
  uuid, text, jsonb, jsonb, uuid
) to authenticated;
grant execute on function public.secoto_create_expense(
  uuid, text, numeric, text, text, text, bigint, uuid
) to authenticated;
grant execute on function public.secoto_admin_review_expense(
  uuid, text, text, uuid
) to authenticated;
grant execute on function public.secoto_register_push_device(
  text, text, text, text, text
) to authenticated;
grant execute on function public.secoto_register_web_push(
  text, text, text, text, text
) to authenticated;
grant execute on function public.secoto_deactivate_push_device(text)
  to authenticated;
grant execute on function public.secoto_emit_business_event(
  text, uuid, uuid
) to authenticated;

-- RPC serveur uniquement.
grant execute on function public.secoto_claim_push_outbox(uuid)
  to service_role;
grant execute on function public.secoto_complete_push_outbox(
  uuid, boolean, text
) to service_role;
grant execute on function public.secoto_prepare_account_deletion(uuid, uuid)
  to service_role;
grant execute on function public.secoto_finalize_account_deletion(uuid, uuid)
  to service_role;
grant execute on function public.secoto_complete_account_deletion(uuid)
  to service_role;
grant execute on function public.secoto_fail_account_deletion(uuid, text)
  to service_role;

-- Circuit de documents historique preserve, avec ses controles internes.
do $grant_document_api$
declare
  v_function record;
begin
  for v_function in
    select p.oid::regprocedure as signature
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname in (
        'secoto_next_doc_number',
        'secoto_save_doc_template',
        'secoto_emit_mission_documents',
        'secoto_emit_facture',
        'secoto_sign_document'
      )
  loop
    execute format(
      'grant execute on function %s to authenticated',
      v_function.signature
    );
  end loop;
end
$grant_document_api$;

-- Les anciens endpoints destructifs/forgeables restent presents uniquement
-- pour audit mais ne sont plus executables par un client.
do $revoke_legacy$
declare
  v_function record;
begin
  for v_function in
    select p.oid::regprocedure as signature
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname in (
        'secoto_delete_account',
        'secoto_notify_one',
        'secoto_notify_admins',
        'secoto_release_document',
        'secoto_issue_mission_docs',
        'secoto_emit_document',
        'secoto_render_document'
      )
  loop
    execute format(
      'revoke all on function %s from public, anon, authenticated',
      v_function.signature
    );
  end loop;
end
$revoke_legacy$;

-- Policies Storage des quatre buckets sensibles. Toute ancienne policy
-- mentionnant ces buckets est retiree pour eviter l'addition OR des policies
-- permissives.
do $drop_storage_policies$
declare
  v_policy record;
begin
  for v_policy in
    select policyname
    from pg_policies
    where schemaname = 'storage'
      and tablename = 'objects'
      and (
        coalesce(qual, '') || ' ' || coalesce(with_check, '')
      ) ~ '(documents-pdf|mission-photos|justificatifs|documents)'
  loop
    execute format(
      'drop policy if exists %I on storage.objects',
      v_policy.policyname
    );
  end loop;
end
$drop_storage_policies$;

grant usage on schema secoto_private to authenticated;
grant execute on function secoto_private.can_read_mission(uuid)
  to authenticated;
grant execute on function secoto_private.can_write_mission_file(uuid)
  to authenticated;
grant execute on function secoto_private.can_upload_tracking_file(uuid)
  to authenticated;
grant execute on function secoto_private.can_read_document_path(text, boolean)
  to authenticated;
grant execute on function secoto_private.current_role()
  to authenticated;
grant execute on function secoto_private.current_is_admin()
  to authenticated;

create policy secoto_documents_insert_own
on storage.objects for insert to authenticated
with check (
  bucket_id = 'documents'
  and (storage.foldername(name))[1] = auth.uid()::text
  and (storage.foldername(name))[2] = 'account'
  and secoto_private.current_role() = 'transporter'
);

create policy secoto_documents_read_authorized
on storage.objects for select to authenticated
using (
  bucket_id = 'documents'
  and (
    secoto_private.can_read_document_path(name, false)
    or (
      (storage.foldername(name))[1] = auth.uid()::text
      and (storage.foldername(name))[2] = 'account'
      and secoto_private.current_role() = 'transporter'
    )
  )
);

create policy secoto_tracking_insert_assigned
on storage.objects for insert to authenticated
with check (
  bucket_id = 'mission-photos'
  and (storage.foldername(name))[1] = auth.uid()::text
  and secoto_private.can_upload_tracking_file(
    ((storage.foldername(name))[2])::uuid
  )
);

create policy secoto_tracking_read_authorized
on storage.objects for select to authenticated
using (
  bucket_id = 'mission-photos'
  and (
    exists (
      select 1
      from public.mission_tracking_photos p
      where p.file_path = name
        and secoto_private.can_read_mission(p.mission_id)
    )
    or (
      (storage.foldername(name))[1] = auth.uid()::text
      and secoto_private.can_upload_tracking_file(
        ((storage.foldername(name))[2])::uuid
      )
    )
  )
);

create policy secoto_expense_insert_assigned
on storage.objects for insert to authenticated
with check (
  bucket_id = 'justificatifs'
  and (storage.foldername(name))[1] = auth.uid()::text
  and secoto_private.can_write_mission_file(
    ((storage.foldername(name))[2])::uuid
  )
);

create policy secoto_expense_read_authorized
on storage.objects for select to authenticated
using (
  bucket_id = 'justificatifs'
  and (
    secoto_private.current_is_admin()
    or (
      (storage.foldername(name))[1] = auth.uid()::text
      and secoto_private.can_write_mission_file(
        ((storage.foldername(name))[2])::uuid
      )
    )
  )
);

create policy secoto_generated_documents_read
on storage.objects for select to authenticated
using (
  bucket_id = 'documents-pdf'
  and secoto_private.can_read_document_path(name, true)
);

create policy secoto_generated_documents_admin_insert
on storage.objects for insert to authenticated
with check (
  bucket_id = 'documents-pdf'
  and secoto_private.current_is_admin()
);

-- Barriere restrictive: meme une ancienne policy generique permissive ne peut
-- contourner ces conditions, car les policies RESTRICTIVE sont combinees en
-- AND avec toutes les policies permissives.
create policy secoto_sensitive_read_barrier
on storage.objects as restrictive for select to authenticated
using (
  bucket_id not in (
    'documents','mission-photos','justificatifs','documents-pdf'
  )
  or (
    bucket_id = 'documents'
    and (
      secoto_private.can_read_document_path(name, false)
      or (
        (storage.foldername(name))[1] = auth.uid()::text
        and (storage.foldername(name))[2] = 'account'
        and secoto_private.current_role() = 'transporter'
      )
    )
  )
  or (
    bucket_id = 'mission-photos'
    and (
      exists (
        select 1
        from public.mission_tracking_photos p
        where p.file_path = name
          and secoto_private.can_read_mission(p.mission_id)
      )
      or (
        (storage.foldername(name))[1] = auth.uid()::text
        and secoto_private.can_upload_tracking_file(
          ((storage.foldername(name))[2])::uuid
        )
      )
    )
  )
  or (
    bucket_id = 'justificatifs'
    and (
      secoto_private.current_is_admin()
      or exists (
        select 1
        from public.frais f
        where coalesce(f.justificatif_path, f.justificatif_url) = name
          and f.transporter_id = auth.uid()
      )
      or (
        (storage.foldername(name))[1] = auth.uid()::text
        and secoto_private.can_write_mission_file(
          ((storage.foldername(name))[2])::uuid
        )
      )
    )
  )
  or (
    bucket_id = 'documents-pdf'
    and secoto_private.can_read_document_path(name, true)
  )
);

create policy secoto_sensitive_insert_barrier
on storage.objects as restrictive for insert to authenticated
with check (
  bucket_id not in (
    'documents','mission-photos','justificatifs','documents-pdf'
  )
  or (
    bucket_id = 'documents'
    and (storage.foldername(name))[1] = auth.uid()::text
    and (storage.foldername(name))[2] = 'account'
    and secoto_private.current_role() = 'transporter'
  )
  or (
    bucket_id = 'mission-photos'
    and (storage.foldername(name))[1] = auth.uid()::text
    and secoto_private.can_upload_tracking_file(
      ((storage.foldername(name))[2])::uuid
    )
  )
  or (
    bucket_id = 'justificatifs'
    and (storage.foldername(name))[1] = auth.uid()::text
    and secoto_private.can_write_mission_file(
      ((storage.foldername(name))[2])::uuid
    )
  )
  or (
    bucket_id = 'documents-pdf'
    and secoto_private.current_is_admin()
  )
);

create policy secoto_sensitive_update_barrier
on storage.objects as restrictive for update to authenticated
using (
  bucket_id not in (
    'documents','mission-photos','justificatifs','documents-pdf'
  )
)
with check (
  bucket_id not in (
    'documents','mission-photos','justificatifs','documents-pdf'
  )
);

create policy secoto_sensitive_delete_barrier
on storage.objects as restrictive for delete to authenticated
using (
  bucket_id not in (
    'documents','mission-photos','justificatifs','documents-pdf'
  )
);

-- Les anciennes vues restent physiquement disponibles pour comparaison, mais
-- ne sont plus exposees a anon/authenticated.
do $revoke_legacy_views$
declare
  v_view text;
begin
  foreach v_view in array array[
    'public_missions',
    'v_missions_admin',
    'v_missions_client',
    'v_missions_transporter'
  ] loop
    if to_regclass('public.' || v_view) is not null then
      execute format(
        'revoke all on table public.%I from public, anon, authenticated',
        v_view
      );
    end if;
  end loop;
end
$revoke_legacy_views$;

-- Realtime: notifications et lignes soumises a RLS uniquement. La table
-- missions brute est retiree pour ne jamais diffuser ses colonnes financieres.
do $realtime$
declare
  v_table text;
begin
  begin
    alter publication supabase_realtime drop table public.missions;
  exception when undefined_object then null;
  end;
  foreach v_table in array array[
    'notifications',
    'mission_requests',
    'mission_applications',
    'documents',
    'mission_tracking_events',
    'mission_tracking_photos',
    'frais'
  ] loop
    begin
      execute format(
        'alter publication supabase_realtime add table public.%I',
        v_table
      );
    exception when duplicate_object then null;
    end;
  end loop;
end
$realtime$;

notify pgrst, 'reload schema';
commit;
