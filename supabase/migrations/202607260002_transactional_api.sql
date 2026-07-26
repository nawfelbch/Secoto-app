-- SECOTO - 002 / API METIER TRANSACTIONNELLE ET IDEMPOTENTE
-- Date: 2026-07-26
--
-- Executer apres 202607260001_secure_foundation.sql, dans la meme fenetre de
-- maintenance. Chaque RPC SECURITY DEFINER fixe search_path a vide, verifie
-- auth.uid(), le role, la propriete des donnees et les transitions.

begin;

do $guard$
begin
  if to_regclass('public.secoto_idempotency') is null
     or to_regclass('public.device_push_tokens') is null
     or to_regclass('public.push_outbox') is null then
    raise exception 'Migration SECOTO 001 requise avant la migration 002.';
  end if;
end
$guard$;

create or replace function secoto_private.safe_mission_date(p_payload jsonb)
returns timestamptz
language plpgsql
stable
security invoker
set search_path = ''
as $function$
declare
  v_raw text := nullif(btrim(coalesce(p_payload ->> 'mission_date', '')), '');
  v_value timestamptz;
begin
  if v_raw is null then return null; end if;
  begin
    if v_raw ~ '(Z|[+-][0-9]{2}:[0-9]{2})$' then
      v_value := v_raw::timestamptz;
    else
      v_value := v_raw::timestamp at time zone 'Europe/Paris';
    end if;
  exception when datetime_field_overflow or invalid_datetime_format then
    raise exception using
      errcode = '22007',
      message = 'Date de mission invalide.';
  end;
  if v_value < now() - interval '10 years'
     or v_value > now() + interval '10 years' then
    raise exception 'Date de mission hors limites.';
  end if;
  return v_value;
end;
$function$;

-- Declarations de signatures pour permettre la validation des RPC suivantes.
-- Les corps definitifs, qui derivent le contenu, sont installes plus bas dans
-- la meme transaction avant tout COMMIT.
create or replace function secoto_private.notify_one(
  p_account_id uuid,
  p_type text,
  p_mission_id uuid,
  p_screen text,
  p_event_key text
)
returns uuid
language plpgsql
volatile
security definer
set search_path = ''
as $function$
begin
  raise exception 'Initialisation notification SECOTO incomplete.';
end;
$function$;

create or replace function secoto_private.notify_admins(
  p_type text,
  p_mission_id uuid,
  p_screen text,
  p_event_key_prefix text
)
returns void
language plpgsql
volatile
security definer
set search_path = ''
as $function$
begin
  raise exception 'Initialisation notification SECOTO incomplete.';
end;
$function$;

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
begin
  raise exception 'Initialisation notification SECOTO incomplete.';
end;
$function$;

create or replace function public.secoto_admin_set_transporter_status(
  p_transporter_id uuid,
  p_status text,
  p_is_verified boolean,
  p_docs_count integer,
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
  v_account public.accounts%rowtype;
  v_validated_docs integer;
begin
  perform secoto_private.assert_admin();
  v_existing := secoto_private.lock_operation(
    'admin_set_transporter_status',
    p_idempotency_key
  );
  if v_existing is not null then return v_existing; end if;
  if p_status not in ('pending', 'active', 'suspended') then
    raise exception 'Statut transporteur invalide.';
  end if;
  if p_is_verified and p_status <> 'active' then
    raise exception 'Un transporteur verifie doit etre actif.';
  end if;

  select count(*)::integer
  into v_validated_docs
  from public.documents d
  where d.account_id = p_transporter_id
    and d.doc_type is null
    and d.status::text = 'validated';

  update public.accounts
  set
    status = p_status,
    is_verified = coalesce(p_is_verified, false),
    docs_count = v_validated_docs
  where id = p_transporter_id
    and role::text = 'transporter'
    and deleted_at is null
  returning * into v_account;
  if not found then raise exception 'Transporteur introuvable.'; end if;

  perform secoto_private.notify_one(
    p_transporter_id,
    'transporter_status',
    null,
    'documents',
    'transporter-status:' || p_transporter_id::text || ':'
      || p_idempotency_key::text
  );

  return secoto_private.finish_operation(
    'admin_set_transporter_status',
    p_idempotency_key,
    to_jsonb(v_account)
      || jsonb_build_object('requested_docs_count_ignored', p_docs_count)
  );
end;
$function$;

create or replace function public.secoto_admin_set_document_status(
  p_document_id uuid,
  p_status text,
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
  v_document public.documents%rowtype;
  v_docs_count integer;
begin
  perform secoto_private.assert_admin();
  v_existing := secoto_private.lock_operation(
    'admin_set_document_status',
    p_idempotency_key
  );
  if v_existing is not null then return v_existing; end if;
  if p_status not in ('uploaded', 'validated', 'rejected') then
    raise exception 'Statut de document invalide.';
  end if;

  update public.documents
  set status = p_status
  where id = p_document_id
    and doc_type is null
    and coalesce(immutable, false) is false
  returning * into v_document;
  if not found then raise exception 'Piece justificative introuvable.'; end if;

  select count(*)::integer
  into v_docs_count
  from public.documents d
  where d.account_id = v_document.account_id
    and d.doc_type is null
    and d.status::text = 'validated';

  update public.accounts
  set docs_count = v_docs_count
  where id = v_document.account_id
    and role::text = 'transporter';

  perform secoto_private.notify_one(
    v_document.account_id,
    'document',
    v_document.mission_id,
    'documents',
    'document-status:' || p_document_id::text || ':'
      || p_idempotency_key::text
  );

  return secoto_private.finish_operation(
    'admin_set_document_status',
    p_idempotency_key,
    to_jsonb(v_document)
  );
end;
$function$;

create or replace function public.secoto_register_transporter_document(
  p_document_type text,
  p_file_name text,
  p_file_path text,
  p_mime_type text,
  p_size_bytes bigint,
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
  v_document public.documents%rowtype;
begin
  if secoto_private.account_role(v_user_id) <> 'transporter' then
    raise exception 'Compte transporteur requis.';
  end if;
  v_existing := secoto_private.lock_operation(
    'register_transporter_document',
    p_idempotency_key
  );
  if v_existing is not null then return v_existing; end if;

  if p_document_type not in (
    'assurance_rc_pro',
    'kbis_siren',
    'licence_transport',
    'piece_identite',
    'carte_grise',
    'autre'
  ) then
    raise exception 'Type de document invalide.';
  end if;
  if p_mime_type not in (
    'image/jpeg', 'image/png', 'image/webp', 'application/pdf'
  ) then
    raise exception 'Type MIME interdit.';
  end if;
  if p_size_bytes is null or p_size_bytes < 1
     or p_size_bytes > 12582912 then
    raise exception 'Taille de document interdite.';
  end if;
  if p_file_path is null
     or p_file_path like '/%'
     or p_file_path like '%..%'
     or split_part(p_file_path, '/', 1) <> v_user_id::text
     or split_part(p_file_path, '/', 2) <> 'account'
     or split_part(p_file_path, '/', 3) <> p_idempotency_key::text
     or length(p_file_path) > 1024 then
    raise exception 'Chemin de document invalide.';
  end if;
  if not exists (
    select 1
    from storage.objects o
    where o.bucket_id = 'documents'
      and o.name = p_file_path
      and coalesce((o.metadata ->> 'size')::bigint, p_size_bytes) = p_size_bytes
      and lower(coalesce(o.metadata ->> 'mimetype', p_mime_type))
        = lower(p_mime_type)
  ) then
    raise exception 'Objet Storage non confirme.';
  end if;

  insert into public.documents(
    account_id,
    mission_id,
    recipient_id,
    type,
    file_name,
    file_path,
    file_url,
    status,
    doc_type,
    mime_type,
    size_bytes,
    idempotency_key
  )
  values (
    v_user_id,
    null,
    null,
    p_document_type,
    left(coalesce(p_file_name, 'document'), 240),
    p_file_path,
    null,
    'uploaded',
    null,
    p_mime_type,
    p_size_bytes,
    p_idempotency_key
  )
  returning * into v_document;

  perform secoto_private.notify_admins(
    'document',
    null,
    'documents',
    'transporter-document:' || v_document.id::text
  );

  return secoto_private.finish_operation(
    'register_transporter_document',
    p_idempotency_key,
    to_jsonb(v_document)
  );
end;
$function$;

create or replace function public.secoto_finalize_tracking_event(
  p_mission_id uuid,
  p_event_type text,
  p_payload jsonb,
  p_files jsonb,
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
  v_event public.mission_tracking_events%rowtype;
  v_file jsonb;
  v_file_count integer;
  v_progress text;
  v_latitude double precision;
  v_longitude double precision;
  v_accuracy double precision;
  v_index integer := 0;
begin
  v_existing := secoto_private.lock_operation(
    'finalize_tracking_event',
    p_idempotency_key
  );
  if v_existing is not null then return v_existing; end if;
  if p_event_type not in (
    'pickup_inspection', 'road_incident', 'delivery_inspection'
  ) then
    raise exception 'Type d''evenement terrain invalide.';
  end if;
  if jsonb_typeof(coalesce(p_files, '[]'::jsonb)) <> 'array' then
    raise exception 'Liste de fichiers invalide.';
  end if;
  v_file_count := jsonb_array_length(coalesce(p_files, '[]'::jsonb));
  if v_file_count > 10 then raise exception 'Trop de photos.'; end if;
  if p_event_type in ('pickup_inspection', 'delivery_inspection')
     and not exists (
       select 1
       from jsonb_array_elements(coalesce(p_files, '[]'::jsonb)) f
       where f ->> 'mime_type' in ('image/jpeg', 'image/png', 'image/webp')
     ) then
    raise exception 'Au moins une preuve photo est obligatoire.';
  end if;

  select *
  into v_mission
  from public.missions m
  where m.id = p_mission_id
  for update;
  if not found
     or v_mission.assigned_transporter_id is distinct from v_user_id
     or v_mission.status::text <> 'assigned' then
    raise exception 'Mission terrain non autorisee.';
  end if;

  if p_event_type = 'pickup_inspection'
     and (
       coalesce(v_mission.progress_status::text, 'assigned_pending')
         <> 'assigned_pending'
       or exists (
         select 1 from public.mission_tracking_events e
         where e.mission_id = p_mission_id
           and e.event_type::text = 'pickup_inspection'
       )
     ) then
    raise exception 'Prise en charge deja finalisee ou hors sequence.';
  end if;
  if p_event_type in ('road_incident', 'delivery_inspection')
     and not exists (
       select 1 from public.mission_tracking_events e
       where e.mission_id = p_mission_id
         and e.event_type::text = 'pickup_inspection'
     ) then
    raise exception 'La prise en charge doit etre finalisee en premier.';
  end if;
  if p_event_type = 'delivery_inspection'
     and exists (
       select 1 from public.mission_tracking_events e
       where e.mission_id = p_mission_id
         and e.event_type::text = 'delivery_inspection'
     ) then
    raise exception 'Livraison deja finalisee.';
  end if;

  v_progress := case p_event_type
    when 'pickup_inspection' then 'pickup_completed'
    when 'road_incident' then 'incident_reported'
    when 'delivery_inspection' then 'delivery_completed'
  end;
  if coalesce(p_payload ->> 'expected_progress_status', v_progress)
     <> v_progress then
    raise exception 'Transition terrain incoherente.';
  end if;

  if (p_payload ->> 'latitude') is not null
     or (p_payload ->> 'longitude') is not null
     or (p_payload ->> 'location_accuracy_m') is not null then
    if (p_payload ->> 'latitude') is null
       or (p_payload ->> 'longitude') is null
       or (p_payload ->> 'location_accuracy_m') is null then
      raise exception 'Latitude, longitude et precision doivent etre fournies ensemble.';
    end if;
    v_latitude := (p_payload ->> 'latitude')::double precision;
    v_longitude := (p_payload ->> 'longitude')::double precision;
    v_accuracy := (p_payload ->> 'location_accuracy_m')::double precision;
    if v_latitude not between -90 and 90
       or v_longitude not between -180 and 180
       or v_accuracy not between 0 and 10000 then
      raise exception 'Position ponctuelle invalide.';
    end if;
  end if;

  for v_file in
    select value from jsonb_array_elements(coalesce(p_files, '[]'::jsonb))
  loop
    if v_file ->> 'mime_type' not in (
      'image/jpeg', 'image/png', 'image/webp', 'application/pdf'
    ) or (
      v_file ->> 'mime_type' = 'application/pdf'
      and p_event_type <> 'road_incident'
    ) then
      raise exception 'Type MIME photo interdit.';
    end if;
    if coalesce((v_file ->> 'size_bytes')::bigint, 0)
       not between 1 and 12582912 then
      raise exception 'Taille photo interdite.';
    end if;
    if v_file ->> 'file_path' is null
       or v_file ->> 'file_path' like '/%'
       or v_file ->> 'file_path' like '%..%'
       or split_part(v_file ->> 'file_path', '/', 1) <> v_user_id::text
       or split_part(v_file ->> 'file_path', '/', 2) <> p_mission_id::text
       or split_part(v_file ->> 'file_path', '/', 3)
         <> p_idempotency_key::text
       or not exists (
         select 1
         from storage.objects o
         where o.bucket_id = 'mission-photos'
           and o.name = v_file ->> 'file_path'
           and coalesce(
             (o.metadata ->> 'size')::bigint,
             (v_file ->> 'size_bytes')::bigint
           ) = (v_file ->> 'size_bytes')::bigint
           and lower(coalesce(
             o.metadata ->> 'mimetype',
             v_file ->> 'mime_type'
           )) = lower(v_file ->> 'mime_type')
       ) then
      raise exception 'Photo Storage non confirmee.';
    end if;
  end loop;

  insert into public.mission_tracking_events(
    mission_id,
    transporter_id,
    event_type,
    title,
    comment,
    odometer_km,
    fuel_level,
    issue_type,
    issue_severity,
    latitude,
    longitude,
    location_accuracy_m,
    location_recorded_at,
    idempotency_key
  )
  values (
    p_mission_id,
    v_user_id,
    p_event_type,
    case p_event_type
      when 'pickup_inspection' then 'Etat des lieux de depart'
      when 'road_incident' then 'Incident signale'
      else 'Etat des lieux d''arrivee'
    end,
    secoto_private.safe_text(p_payload, 'comment', 4000, false),
    secoto_private.safe_numeric(
      p_payload, 'odometer_km', 0, 5000000, null
    ),
    case
      when coalesce(p_payload ->> 'fuel_level', 'unknown')
        in ('unknown', 'reserve', '1/4', '1/2', '3/4', 'full')
      then coalesce(p_payload ->> 'fuel_level', 'unknown')
      else 'unknown'
    end,
    case when p_event_type = 'road_incident'
      then secoto_private.safe_text(p_payload, 'issue_type', 120, false)
      else null end,
    case when p_event_type = 'road_incident'
      then secoto_private.safe_text(p_payload, 'issue_severity', 40, false)
      else null end,
    v_latitude,
    v_longitude,
    v_accuracy,
    case when v_latitude is not null then now() else null end,
    p_idempotency_key
  )
  returning * into v_event;

  for v_file in
    select value from jsonb_array_elements(coalesce(p_files, '[]'::jsonb))
  loop
    insert into public.mission_tracking_photos(
      tracking_event_id,
      mission_id,
      transporter_id,
      photo_type,
      file_name,
      file_path,
      file_url,
      mime_type,
      size_bytes,
      idempotency_key
    )
    values (
      v_event.id,
      p_mission_id,
      v_user_id,
      coalesce(nullif(v_file ->> 'photo_type', ''), 'general'),
      left(coalesce(v_file ->> 'file_name', 'photo'), 240),
      v_file ->> 'file_path',
      null,
      v_file ->> 'mime_type',
      (v_file ->> 'size_bytes')::bigint,
      p_idempotency_key
    );
    v_index := v_index + 1;
  end loop;

  update public.missions
  set
    progress_status = v_progress,
    status = case
      when p_event_type = 'delivery_inspection' then 'completed'
      else status
    end
  where id = p_mission_id
  returning * into v_mission;

  perform secoto_private.notify_admins(
    case when p_event_type = 'delivery_inspection'
      then 'delivered' else 'tracking' end,
    p_mission_id,
    'assigned',
    'tracking:' || v_event.id::text
  );
  if v_mission.client_account_id is not null then
    perform secoto_private.notify_one(
      v_mission.client_account_id,
      case when p_event_type = 'delivery_inspection'
        then 'delivered' else 'tracking' end,
      p_mission_id,
      'courses',
      'tracking-client:' || v_event.id::text
    );
  end if;

  return secoto_private.finish_operation(
    'finalize_tracking_event',
    p_idempotency_key,
    to_jsonb(v_event)
      || jsonb_build_object('photos_count', v_index)
  );
end;
$function$;

create or replace function public.secoto_create_expense(
  p_mission_id uuid,
  p_type text,
  p_amount numeric,
  p_file_name text,
  p_file_path text,
  p_mime_type text,
  p_size_bytes bigint,
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
  v_expense public.frais%rowtype;
begin
  v_existing := secoto_private.lock_operation(
    'create_expense',
    p_idempotency_key
  );
  if v_existing is not null then return v_existing; end if;
  if p_type not in ('essence', 'peage') then
    raise exception 'Type de frais invalide.';
  end if;
  if p_amount is null or p_amount <= 0 or p_amount > 100000 then
    raise exception 'Montant de frais invalide.';
  end if;
  if not secoto_private.can_write_mission_file(p_mission_id) then
    raise exception 'Frais non autorise pour cette mission.';
  end if;
  if p_mime_type not in (
    'image/jpeg', 'image/png', 'image/webp', 'application/pdf'
  ) or p_size_bytes not between 1 and 12582912 then
    raise exception 'Justificatif invalide.';
  end if;
  if p_file_path is null
     or p_file_path like '/%'
     or p_file_path like '%..%'
     or split_part(p_file_path, '/', 1) <> v_user_id::text
     or split_part(p_file_path, '/', 2) <> p_mission_id::text
     or split_part(p_file_path, '/', 3) <> p_idempotency_key::text
     or not exists (
       select 1 from storage.objects o
       where o.bucket_id = 'justificatifs'
         and o.name = p_file_path
         and coalesce((o.metadata ->> 'size')::bigint, p_size_bytes)
           = p_size_bytes
         and lower(coalesce(o.metadata ->> 'mimetype', p_mime_type))
           = lower(p_mime_type)
     ) then
    raise exception 'Justificatif Storage non confirme.';
  end if;

  insert into public.frais(
    mission_id,
    transporter_id,
    type,
    montant,
    justificatif_url,
    justificatif_path,
    file_name,
    mime_type,
    size_bytes,
    statut,
    motif_refus,
    idempotency_key
  )
  values (
    p_mission_id,
    v_user_id,
    p_type::public.secoto_frais_type,
    round(p_amount, 2),
    p_file_path,
    p_file_path,
    left(coalesce(p_file_name, 'justificatif'), 240),
    p_mime_type,
    p_size_bytes,
    'en_attente'::public.secoto_frais_statut,
    null,
    p_idempotency_key
  )
  returning * into v_expense;

  perform secoto_private.notify_admins(
    'frais',
    p_mission_id,
    'frais',
    'expense:' || v_expense.id::text
  );

  return secoto_private.finish_operation(
    'create_expense',
    p_idempotency_key,
    to_jsonb(v_expense)
  );
end;
$function$;

create or replace function public.secoto_admin_review_expense(
  p_expense_id uuid,
  p_decision text,
  p_reason text,
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
  v_expense public.frais%rowtype;
begin
  v_existing := secoto_private.lock_operation(
    'admin_review_expense',
    p_idempotency_key
  );
  if v_existing is not null then return v_existing; end if;
  if p_decision not in ('valide', 'refuse') then
    raise exception 'Decision de frais invalide.';
  end if;
  if p_decision = 'refuse'
     and nullif(btrim(coalesce(p_reason, '')), '') is null then
    raise exception 'Motif de refus obligatoire.';
  end if;

  update public.frais
  set
    statut = p_decision::public.secoto_frais_statut,
    motif_refus = case when p_decision = 'refuse'
      then left(btrim(p_reason), 1000) else null end,
    validated_at = now(),
    validated_by = v_admin_id
  where id = p_expense_id
    and statut::text = 'en_attente'
  returning * into v_expense;
  if not found then raise exception 'Frais introuvable ou deja traite.'; end if;

  perform secoto_private.notify_one(
    v_expense.transporter_id,
    'frais_status',
    v_expense.mission_id,
    'frais',
    'expense-status:' || v_expense.id::text
  );

  return secoto_private.finish_operation(
    'admin_review_expense',
    p_idempotency_key,
    to_jsonb(v_expense)
  );
end;
$function$;

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
    raise exception 'Compte transporteur verifie requis.';
  end if;
  if p_proposed_price is null
     or p_proposed_price <= 0
     or p_proposed_price > 1000000 then
    raise exception 'Tarif propose invalide.';
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
  if not found or v_mission.status::text <> 'published'
     or v_mission.assigned_transporter_id is not null then
    raise exception 'Cette mission n''accepte plus de candidature.';
  end if;

  select * into v_account from public.accounts a where a.id = v_user_id;

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
      message = 'Vous avez deja candidate a cette mission.';
end;
$function$;

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
  if not found or v_mission.status::text <> 'published'
     or v_mission.assigned_transporter_id is not null then
    raise exception 'Mission deja attribuee ou indisponible.';
  end if;

  select *
  into v_application
  from public.mission_applications ma
  where ma.id = p_application_id
    and ma.mission_id = p_mission_id
  for update;
  if not found or v_application.status::text <> 'pending' then
    raise exception 'Candidature invalide ou deja traitee.';
  end if;
  if not secoto_private.is_verified_transporter(
    v_application.transporter_id
  ) then
    raise exception 'Le transporteur selectionne n''est plus verifie.';
  end if;

  v_carrier_cost := case
    when v_mission.type::text = 'convoyage'
      then round(greatest(coalesce(v_mission.distance_km, 0), 0) * 0.55, 2)
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
    status = case when id = p_application_id then 'accepted' else 'rejected' end,
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

create or replace function public.secoto_transition_mission(
  p_mission_id uuid,
  p_target_status text,
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
begin
  v_existing := secoto_private.lock_operation(
    'transition_mission',
    p_idempotency_key
  );
  if v_existing is not null then return v_existing; end if;

  select *
  into v_mission
  from public.missions m
  where m.id = p_mission_id
  for update;
  if not found then raise exception 'Mission introuvable.'; end if;

  if not (
    (v_mission.status::text = 'published'
      and p_target_status = 'cancelled')
    or
    (v_mission.status::text = 'assigned'
      and p_target_status in ('completed', 'cancelled'))
  ) then
    raise exception 'Transition de mission interdite.';
  end if;

  update public.missions
  set
    status = p_target_status,
    progress_status = case
      when p_target_status = 'completed' then 'completed'
      else progress_status
    end
  where id = p_mission_id
  returning * into v_mission;

  if p_target_status = 'completed'
     and v_mission.client_account_id is not null then
    perform secoto_private.notify_one(
      v_mission.client_account_id,
      'delivered',
      p_mission_id,
      'courses',
      'mission-completed:client:' || p_mission_id::text
    );
  end if;

  return secoto_private.finish_operation(
    'transition_mission',
    p_idempotency_key,
    to_jsonb(v_mission) || jsonb_build_object('decided_by', v_admin_id)
  );
end;
$function$;

create or replace function public.secoto_delete_unstarted_mission(
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
begin
  v_existing := secoto_private.lock_operation(
    'delete_unstarted_mission',
    p_idempotency_key
  );
  if v_existing is not null then return v_existing; end if;

  select *
  into v_mission
  from public.missions m
  where m.id = p_mission_id
  for update;
  if not found then raise exception 'Mission introuvable.'; end if;
  if v_mission.status::text <> 'published'
     or v_mission.assigned_transporter_id is not null then
    raise exception 'Une mission demarree ne peut pas etre supprimee.';
  end if;
  if not secoto_private.is_admin(v_user_id)
     and v_mission.client_account_id is distinct from v_user_id then
    raise exception 'Suppression non autorisee.';
  end if;

  -- Equivalence avec le parcours historique et compatibilite avec les bases
  -- dont la FK applications -> missions n'est pas encore ON DELETE CASCADE.
  delete from public.mission_applications
  where mission_id = p_mission_id;
  delete from public.missions where id = p_mission_id;

  return secoto_private.finish_operation(
    'delete_unstarted_mission',
    p_idempotency_key,
    jsonb_build_object('id', p_mission_id, 'deleted', true)
  );
end;
$function$;

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
    raise exception 'Demande introuvable ou deja traitee.';
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
      then round(greatest(coalesce(v_request.distance_km, 0), 0) * 0.55, 2)
    else 0
  end;

  insert into public.missions(
    public_ref,
    type,
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

create or replace function public.secoto_reject_request(
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
begin
  v_existing := secoto_private.lock_operation(
    'reject_request',
    p_idempotency_key
  );
  if v_existing is not null then return v_existing; end if;

  select *
  into v_request
  from public.mission_requests r
  where r.id = p_request_id
  for update;
  if not found or v_request.status::text <> 'pending' then
    raise exception 'Demande introuvable ou deja traitee.';
  end if;

  update public.mission_requests
  set status = 'rejected', decided_at = now(), decided_by = v_admin_id
  where id = p_request_id
  returning * into v_request;

  if v_request.requester_id is not null then
    perform secoto_private.notify_one(
      v_request.requester_id,
      'system',
      null,
      'requests',
      'request-rejected:' || p_request_id::text
    );
  end if;

  return secoto_private.finish_operation(
    'reject_request',
    p_idempotency_key,
    to_jsonb(v_request)
  );
end;
$function$;

-- Notification interne fiable. Le contenu est derive d'un type serveur et de
-- la mission ; aucun titre, texte, destinataire ou audience n'est accepte par
-- une RPC appelee depuis le telephone.
create or replace function secoto_private.notify_one(
  p_account_id uuid,
  p_type text,
  p_mission_id uuid,
  p_screen text,
  p_event_key text
)
returns uuid
language plpgsql
volatile
security definer
set search_path = ''
as $function$
declare
  v_notification_id uuid;
  v_title text;
  v_body text;
  v_audience text;
  v_mission public.missions%rowtype;
begin
  if p_account_id is null then
    return null;
  end if;
  if p_type not in (
    'new_course',
    'course_assigned',
    'tracking',
    'delivered',
    'new_request',
    'new_application',
    'frais',
    'frais_status',
    'document',
    'transporter_status',
    'system'
  ) then
    raise exception 'Type de notification serveur non autorise.';
  end if;
  if p_screen not in (
    'courses',
    'documents',
    'frais',
    'available',
    'assigned',
    'applications',
    'requests'
  ) then
    raise exception 'Ecran de notification non autorise.';
  end if;

  if p_mission_id is not null then
    select *
    into v_mission
    from public.missions m
    where m.id = p_mission_id;
  end if;

  v_title := case p_type
    when 'new_course' then 'Nouvelle course disponible'
    when 'course_assigned' then 'Mission attribuee'
    when 'tracking' then 'Mise a jour de la mission'
    when 'delivered' then 'Mission livree'
    when 'new_request' then 'Nouvelle demande'
    when 'new_application' then 'Nouvelle candidature'
    when 'frais' then 'Nouveau frais'
    when 'frais_status' then 'Statut d''un frais'
    when 'document' then 'Document disponible'
    when 'transporter_status' then 'Statut du compte mis a jour'
    else 'Information SECOTO'
  end;

  v_body := case p_type
    when 'new_course' then
      coalesce(v_mission.from_city, 'Depart')
      || ' vers '
      || coalesce(v_mission.to_city, 'Arrivee')
    when 'course_assigned' then
      'Consultez les informations autorisees de cette mission dans SECOTO.'
    when 'tracking' then
      'Une nouvelle etape terrain est disponible dans SECOTO.'
    when 'delivered' then
      'La livraison et son etat des lieux sont disponibles dans SECOTO.'
    when 'new_request' then
      'Une demande attend une decision dans SECOTO.'
    when 'new_application' then
      'Une candidature attend une decision dans SECOTO.'
    when 'frais' then
      'Un justificatif de frais attend une verification dans SECOTO.'
    when 'frais_status' then
      'La decision concernant un frais est disponible dans SECOTO.'
    when 'document' then
      'Un document est disponible dans votre espace SECOTO.'
    when 'transporter_status' then
      'Consultez votre profil SECOTO pour connaitre la decision.'
    else
      'Une information est disponible dans SECOTO.'
  end;

  select a.role::text
  into v_audience
  from public.accounts a
  where a.id = p_account_id;

  insert into public.notifications(
    account_id,
    type,
    title,
    body,
    mission_id,
    audience,
    is_read,
    push_screen,
    event_key
  )
  values (
    p_account_id,
    p_type,
    v_title,
    v_body,
    p_mission_id,
    v_audience,
    false,
    p_screen,
    p_event_key
  )
  on conflict (event_key) where event_key is not null
  do nothing
  returning id into v_notification_id;

  if v_notification_id is null and p_event_key is not null then
    select n.id
    into v_notification_id
    from public.notifications n
    where n.event_key = p_event_key;
  end if;
  return v_notification_id;
end;
$function$;

create or replace function secoto_private.notify_admins(
  p_type text,
  p_mission_id uuid,
  p_screen text,
  p_event_key_prefix text
)
returns void
language plpgsql
volatile
security definer
set search_path = ''
as $function$
declare
  v_admin record;
begin
  for v_admin in
    select a.id
    from public.accounts a
    where a.role::text = 'admin'
      and a.status::text <> 'suspended'
      and a.deleted_at is null
  loop
    perform secoto_private.notify_one(
      v_admin.id,
      p_type,
      p_mission_id,
      p_screen,
      p_event_key_prefix || ':' || v_admin.id::text
    );
  end loop;
end;
$function$;

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
    where a.role::text = 'transporter'
      and a.status::text = 'active'
      and coalesce(a.is_verified, false)
      and a.deleted_at is null
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

-- Formulaire public sans compte. Le serveur impose le role guest, le statut,
-- la reference et la liste exacte de champs acceptes.
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
  v_distance numeric;
begin
  if auth.uid() is not null then
    raise exception 'Le formulaire public est reserve aux visiteurs non connectes.';
  end if;
  if p_payload is null or pg_column_size(p_payload) > 20000 then
    raise exception 'Donnees de demande invalides.';
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

  if length(regexp_replace(coalesce(v_request.client_phone, ''), '\D', '', 'g')) < 6 then
    raise exception 'Numero de telephone invalide.';
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

-- Creation admin. Le serveur fixe le statut et calcule le cout convoyage.
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
  v_admin_id uuid;
  v_existing jsonb;
  v_mission public.missions%rowtype;
  v_type text;
  v_distance numeric;
  v_carrier_cost numeric;
  v_payment text;
begin
  v_admin_id := secoto_private.assert_admin();
  v_existing := secoto_private.lock_operation(
    'create_mission',
    p_idempotency_key
  );
  if v_existing is not null then return v_existing; end if;

  v_type := coalesce(p_payload ->> 'type', 'convoyage');
  if v_type not in ('convoyage', 'plateau') then
    raise exception 'Type de mission invalide.';
  end if;
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
    raise exception 'Mode de reglement invalide.';
  end if;

  insert into public.missions(
    public_ref,
    type,
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

-- Creation client. Identite, compte proprietaire et privilege sont derives du
-- JWT et de accounts. Le client ne fournit aucun cout transporteur.
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
  v_distance := secoto_private.safe_numeric(
    p_payload, 'distance_km', 0, 10000, 0
  );
  v_carrier_cost := case
    when v_type = 'convoyage' then round(v_distance * 0.55, 2)
    else 0
  end;
  v_payment := coalesce(p_payload ->> 'payment_method', 'virement');
  if v_payment not in ('virement', 'especes') then
    raise exception 'Mode de reglement invalide.';
  end if;

  insert into public.missions(
    public_ref,
    type,
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
      - array['carrier_cost', 'carrier_pay', 'margin', 'assigned_application_id']
  );
end;
$function$;

-- Demande d'un transporteur verifie, sans possibilite d'usurper son identite.
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
begin
  if not secoto_private.is_verified_transporter(v_user_id) then
    raise exception 'Compte transporteur verifie requis.';
  end if;
  select * into v_account from public.accounts a where a.id = v_user_id;

  v_existing := secoto_private.lock_operation(
    'create_transporter_request',
    p_idempotency_key
  );
  if v_existing is not null then return v_existing; end if;

  v_type := coalesce(p_payload ->> 'type', 'convoyage');
  if v_type not in ('convoyage', 'plateau') then
    raise exception 'Type de mission invalide.';
  end if;

  insert into public.mission_requests(
    public_ref,
    status,
    requester_id,
    requester_name,
    requester_company,
    type,
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

create or replace function public.secoto_register_push_device(
  p_platform text,
  p_provider text,
  p_token text,
  p_installation_id text,
  p_device_label text
)
returns void
language plpgsql
volatile
security definer
set search_path = ''
as $function$
declare
  v_user_id uuid := secoto_private.assert_authenticated();
begin
  if (p_platform, p_provider) not in (('android', 'fcm'), ('ios', 'apns')) then
    raise exception 'Plateforme ou fournisseur push invalide.';
  end if;
  if p_token is null or length(p_token) not between 20 and 4096 then
    raise exception 'Token push invalide.';
  end if;
  if p_installation_id is null
     or length(p_installation_id) not between 16 and 200
     or p_installation_id !~ '^[A-Za-z0-9_-]+$' then
    raise exception 'Installation invalide.';
  end if;

  insert into public.device_push_tokens(
    account_id,
    platform,
    provider,
    token,
    installation_id,
    device_label,
    is_active,
    last_used_at
  )
  values (
    v_user_id,
    p_platform,
    p_provider,
    p_token,
    p_installation_id,
    left(coalesce(p_device_label, ''), 240),
    true,
    now()
  )
  on conflict (account_id, provider, installation_id)
  do update set
    platform = excluded.platform,
    token = excluded.token,
    device_label = excluded.device_label,
    is_active = true,
    updated_at = now(),
    last_used_at = now();
end;
$function$;

create or replace function public.secoto_register_web_push(
  p_endpoint text,
  p_p256dh text,
  p_auth text,
  p_installation_id text,
  p_device_label text
)
returns void
language plpgsql
volatile
security definer
set search_path = ''
as $function$
declare
  v_user_id uuid := secoto_private.assert_authenticated();
begin
  if p_endpoint is null
     or length(p_endpoint) not between 20 and 4096
     or p_endpoint !~ '^https://' then
    raise exception 'Endpoint Web Push invalide.';
  end if;
  if length(coalesce(p_p256dh, '')) not between 20 and 4096
     or length(coalesce(p_auth, '')) not between 8 and 4096 then
    raise exception 'Cles Web Push invalides.';
  end if;
  if p_installation_id is null
     or length(p_installation_id) not between 16 and 200
     or p_installation_id !~ '^[A-Za-z0-9_-]+$' then
    raise exception 'Installation invalide.';
  end if;

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
    last_used_at
  )
  values (
    v_user_id,
    'web',
    'webpush',
    p_endpoint,
    p_p256dh,
    p_auth,
    p_installation_id,
    left(coalesce(p_device_label, ''), 240),
    true,
    now()
  )
  on conflict (account_id, provider, installation_id)
  do update set
    endpoint = excluded.endpoint,
    p256dh = excluded.p256dh,
    auth_secret = excluded.auth_secret,
    device_label = excluded.device_label,
    is_active = true,
    updated_at = now(),
    last_used_at = now();
end;
$function$;

create or replace function public.secoto_deactivate_push_device(
  p_installation_id text
)
returns void
language plpgsql
volatile
security definer
set search_path = ''
as $function$
declare
  v_user_id uuid := secoto_private.assert_authenticated();
begin
  update public.device_push_tokens
  set is_active = false, updated_at = now()
  where account_id = v_user_id
    and installation_id = p_installation_id;
end;
$function$;

create or replace function public.secoto_emit_business_event(
  p_event_type text,
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
begin
  v_existing := secoto_private.lock_operation(
    'emit_business_event',
    p_idempotency_key
  );
  if v_existing is not null then return v_existing; end if;
  if p_event_type not in ('tracking', 'document', 'frais_status') then
    raise exception 'Evenement client non autorise.';
  end if;

  select * into v_mission
  from public.missions m
  where m.id = p_mission_id;
  if not found or not (
    secoto_private.is_admin(v_user_id)
    or v_mission.client_account_id = v_user_id
    or v_mission.assigned_transporter_id = v_user_id
  ) then
    raise exception 'Evenement non autorise pour cette mission.';
  end if;

  -- Aucun broadcast transporteur. Seuls les autres participants connus de la
  -- mission recoivent un message derive par le serveur.
  if v_mission.client_account_id is not null
     and v_mission.client_account_id <> v_user_id then
    perform secoto_private.notify_one(
      v_mission.client_account_id,
      p_event_type,
      p_mission_id,
      case when p_event_type = 'document' then 'documents'
        when p_event_type = 'frais_status' then 'frais'
        else 'courses' end,
      'business:' || p_idempotency_key::text || ':client'
    );
  end if;
  if v_mission.assigned_transporter_id is not null
     and v_mission.assigned_transporter_id <> v_user_id then
    perform secoto_private.notify_one(
      v_mission.assigned_transporter_id,
      p_event_type,
      p_mission_id,
      case when p_event_type = 'document' then 'documents'
        when p_event_type = 'frais_status' then 'frais'
        else 'assigned' end,
      'business:' || p_idempotency_key::text || ':transporter'
    );
  end if;

  return secoto_private.finish_operation(
    'emit_business_event',
    p_idempotency_key,
    jsonb_build_object('accepted', true, 'mission_id', p_mission_id)
  );
end;
$function$;

-- Ces deux RPC ne sont accordees qu'au role service_role dans la migration 003.
create or replace function public.secoto_claim_push_outbox(p_outbox_id uuid)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $function$
declare
  v_outbox public.push_outbox%rowtype;
begin
  select *
  into v_outbox
  from public.push_outbox o
  where o.id = p_outbox_id
    and o.attempts < o.max_attempts
    and (
      (o.status in ('pending', 'failed') and o.available_at <= now())
      or (o.status = 'processing' and o.locked_at < now() - interval '10 minutes')
    )
  for update skip locked;
  if not found then return '{}'::jsonb; end if;

  update public.push_outbox
  set
    status = 'processing',
    attempts = attempts + 1,
    locked_at = now(),
    updated_at = now(),
    last_error = null
  where id = p_outbox_id
  returning * into v_outbox;

  return jsonb_build_object(
    'id', v_outbox.id,
    'notification_id', v_outbox.notification_id,
    'attempt', v_outbox.attempts
  );
end;
$function$;

create or replace function public.secoto_complete_push_outbox(
  p_outbox_id uuid,
  p_success boolean,
  p_error text
)
returns void
language plpgsql
volatile
security definer
set search_path = ''
as $function$
begin
  update public.push_outbox
  set
    status = case
      when p_success then 'sent'
      when attempts >= max_attempts then 'failed'
      else 'pending'
    end,
    sent_at = case when p_success then now() else sent_at end,
    available_at = case when p_success then available_at
      else now() + make_interval(
        secs => least(3600, (power(2, greatest(attempts, 1)) * 15)::integer)
      )
    end,
    locked_at = null,
    last_error = case when p_success then null
      else left(coalesce(p_error, 'push_failed'), 500) end,
    updated_at = now()
  where id = p_outbox_id
    and status = 'processing';
end;
$function$;

create or replace function public.secoto_prepare_account_deletion(
  p_user_id uuid,
  p_idempotency_key uuid
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $function$
declare
  v_request public.account_deletion_requests%rowtype;
  v_objects jsonb;
begin
  if p_user_id is null or p_idempotency_key is null then
    raise exception 'Demande de suppression invalide.';
  end if;
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(
      'account-deletion:' || p_user_id::text || ':' || p_idempotency_key::text,
      0
    )
  );

  select * into v_request
  from public.account_deletion_requests r
  where r.user_id = p_user_id
    and r.idempotency_key = p_idempotency_key;
  if found and v_request.status in ('completed', 'auth_pending') then
    return jsonb_build_object(
      'status', v_request.status,
      'request_id', v_request.id,
      'storage_objects', v_request.storage_objects
    );
  end if;

  -- Une anonymisation deja effectuee reste reprenable jusqu'a la suppression
  -- Auth ; elle ne doit jamais etre remise a zero par une nouvelle tentative.
  if found
     and v_request.status in ('processing', 'failed')
     and exists (
       select 1 from public.accounts a
       where a.id = p_user_id and a.deleted_at is not null
     ) then
    update public.account_deletion_requests
    set status = 'auth_pending', updated_at = now(), last_error = null
    where id = v_request.id
    returning * into v_request;
    return jsonb_build_object(
      'status', 'auth_pending',
      'request_id', v_request.id,
      'storage_objects', v_request.storage_objects
    );
  end if;

  if not exists (
    select 1 from public.accounts a
    where a.id = p_user_id and a.deleted_at is null
  ) then
    raise exception 'Compte deja supprime ou introuvable.';
  end if;
  if exists (
    select 1
    from public.missions m
    where (
      m.client_account_id = p_user_id
      or m.assigned_transporter_id = p_user_id
    )
      and m.status::text in ('published', 'assigned')
  ) then
    raise exception 'Une mission active doit etre terminee ou annulee avant la suppression.';
  end if;

  select coalesce(jsonb_agg(
    jsonb_build_object('bucket', q.bucket, 'path', q.path)
    order by q.bucket, q.path
  ), '[]'::jsonb)
  into v_objects
  from (
    select 'documents'::text as bucket, d.file_path as path
    from public.documents d
    where d.account_id = p_user_id
      and d.doc_type is null
      and coalesce(d.immutable, false) is false
      and d.file_path is not null
    union
    select 'justificatifs', f.justificatif_path
    from public.frais f
    where f.transporter_id = p_user_id
      and f.statut::text <> 'valide'
      and f.justificatif_path is not null
    union
    select 'mission-photos', p.file_path
    from public.mission_tracking_photos p
    join public.missions m on m.id = p.mission_id
    where p.transporter_id = p_user_id
      and m.status::text <> 'completed'
      and p.file_path is not null
  ) q;

  insert into public.account_deletion_requests(
    user_id,
    idempotency_key,
    status,
    storage_objects,
    last_error,
    updated_at
  )
  values (
    p_user_id,
    p_idempotency_key,
    'prepared',
    v_objects,
    null,
    now()
  )
  on conflict (user_id, idempotency_key)
  do update set
    status = 'prepared',
    storage_objects = excluded.storage_objects,
    last_error = null,
    updated_at = now(),
    completed_at = null
  returning * into v_request;

  return jsonb_build_object(
    'status', v_request.status,
    'request_id', v_request.id,
    'storage_objects', v_request.storage_objects
  );
end;
$function$;

create or replace function public.secoto_finalize_account_deletion(
  p_user_id uuid,
  p_request_id uuid
)
returns void
language plpgsql
volatile
security definer
set search_path = ''
as $function$
declare
  v_request public.account_deletion_requests%rowtype;
  v_path text;
begin
  select *
  into v_request
  from public.account_deletion_requests r
  where r.id = p_request_id
    and r.user_id = p_user_id
  for update;
  if not found or v_request.status not in ('prepared', 'failed', 'processing') then
    if v_request.status = 'auth_pending' then return; end if;
    raise exception 'Etat de suppression invalide.';
  end if;

  update public.account_deletion_requests
  set status = 'processing', updated_at = now(), last_error = null
  where id = p_request_id;

  delete from public.documents d
  where d.account_id = p_user_id
    and d.doc_type is null
    and coalesce(d.immutable, false) is false
    and exists (
      select 1
      from jsonb_array_elements(v_request.storage_objects) o
      where o ->> 'bucket' = 'documents'
        and o ->> 'path' = d.file_path
    );

  delete from public.frais f
  where f.transporter_id = p_user_id
    and f.statut::text <> 'valide'
    and exists (
      select 1
      from jsonb_array_elements(v_request.storage_objects) o
      where o ->> 'bucket' = 'justificatifs'
        and o ->> 'path' = f.justificatif_path
    );

  delete from public.mission_tracking_photos p
  where p.transporter_id = p_user_id
    and exists (
      select 1
      from jsonb_array_elements(v_request.storage_objects) o
      where o ->> 'bucket' = 'mission-photos'
        and o ->> 'path' = p.file_path
    );

  update public.mission_applications
  set
    transporter_name = 'Compte supprime',
    transporter_company = null,
    message = null,
    price_note = null
  where transporter_id = p_user_id;

  update public.mission_requests
  set
    requester_name = 'Compte supprime',
    requester_company = null,
    client_contact = null,
    client_phone = null
  where requester_id = p_user_id;

  update public.missions
  set
    client_name = case when client_account_id = p_user_id
      then 'Compte supprime' else client_name end,
    client_contact = case when client_account_id = p_user_id
      then null else client_contact end,
    client_phone = case when client_account_id = p_user_id
      then null else client_phone end,
    assigned_transporter_name = case
      when assigned_transporter_id = p_user_id
      then 'Compte supprime'
      else assigned_transporter_name
    end
  where client_account_id = p_user_id
     or assigned_transporter_id = p_user_id;

  update public.device_push_tokens
  set is_active = false, updated_at = now()
  where account_id = p_user_id;
  delete from public.push_subscriptions where account_id = p_user_id;
  delete from public.notifications where account_id = p_user_id;

  update public.accounts
  set
    full_name = 'Compte supprime',
    company_name = null,
    email = 'deleted+' || p_user_id::text || '@invalid.secoto',
    phone = null,
    city = null,
    status = 'suspended',
    docs_count = 0,
    is_verified = false,
    transporter_type = null,
    client_type = null,
    deleted_at = now()
  where id = p_user_id;

  update public.account_deletion_requests
  set status = 'auth_pending', updated_at = now(), last_error = null
  where id = p_request_id;
end;
$function$;

create or replace function public.secoto_complete_account_deletion(
  p_request_id uuid
)
returns void
language plpgsql
volatile
security definer
set search_path = ''
as $function$
begin
  update public.account_deletion_requests
  set
    status = 'completed',
    updated_at = now(),
    completed_at = now(),
    last_error = null
  where id = p_request_id
    and status in ('auth_pending', 'completed');
  if not found then raise exception 'Suppression non finalisable.'; end if;
end;
$function$;

create or replace function public.secoto_fail_account_deletion(
  p_request_id uuid,
  p_error text
)
returns void
language plpgsql
volatile
security definer
set search_path = ''
as $function$
begin
  update public.account_deletion_requests
  set
    status = 'failed',
    updated_at = now(),
    completed_at = null,
    last_error = left(coalesce(p_error, 'deletion_failed'), 500)
  where id = p_request_id
    and status in ('prepared', 'processing', 'failed');
end;
$function$;

-- Vues a colonnes explicites. Elles filtrent par auth.uid() et constituent
-- l'unique acces aux missions depuis PostgREST.
create or replace view public.secoto_missions_admin_v2
with (security_barrier = true, security_invoker = false)
as
select
  m.id, m.public_ref, m.type, m.status, m.progress_status,
  m.from_city, m.to_city, m.pickup_address, m.delivery_address,
  m.mission_date, m.vehicle, m.plate, m.distance_km, m.carrier_cost,
  m.client_price, m.carrier_pay, m.margin, m.client_name,
  m.client_contact, m.client_phone, m.price_mode, m.proposed_price,
  m.payment_method, m.notes, m.created_by_role, m.client_account_id,
  m.assigned_transporter_id, m.assigned_transporter_name,
  m.source_request_id, m.created_at
from public.missions m
where secoto_private.is_admin(auth.uid());

create or replace view public.secoto_missions_client_v2
with (security_barrier = true, security_invoker = false)
as
select
  m.id, m.public_ref, m.type, m.status, m.progress_status,
  m.from_city, m.to_city, m.pickup_address, m.delivery_address,
  m.mission_date, m.vehicle, m.plate, m.distance_km, m.client_price,
  m.client_name, m.client_contact, m.client_phone, m.price_mode,
  m.proposed_price, m.payment_method, m.notes, m.created_by_role,
  m.client_account_id, m.assigned_transporter_id,
  m.assigned_transporter_name, m.source_request_id, m.created_at
from public.missions m
where m.client_account_id = auth.uid();

create or replace view public.secoto_missions_transporter_v2
with (security_barrier = true, security_invoker = false)
as
select
  m.id, m.public_ref, m.type, m.status, m.progress_status,
  m.from_city, m.to_city, m.pickup_address, m.delivery_address,
  m.mission_date, m.vehicle, m.plate, m.distance_km, m.carrier_cost,
  m.carrier_pay, m.client_name, m.client_contact, m.client_phone,
  m.payment_method, m.notes, m.assigned_transporter_id,
  m.assigned_transporter_name, m.created_at
from public.missions m
where m.assigned_transporter_id = auth.uid();

create or replace view public.secoto_public_missions_v2
with (security_barrier = true, security_invoker = false)
as
select
  m.id, m.public_ref, m.type, m.status, m.progress_status,
  m.from_city, m.to_city, m.vehicle, m.distance_km, m.created_at
from public.missions m
where m.status::text = 'published'
  and (
    exists (
      select 1
      from public.accounts a
      where a.id = auth.uid()
        and a.role::text = 'transporter'
        and a.status::text <> 'suspended'
        and a.deleted_at is null
    )
    or secoto_private.is_admin(auth.uid())
  );

revoke all on all functions in schema secoto_private
  from public, anon, authenticated;

do $revoke_api$
declare
  v_function record;
  v_names constant text[] := array[
    'secoto_create_public_request',
    'secoto_create_mission',
    'secoto_create_client_mission',
    'secoto_create_transporter_request',
    'secoto_apply_to_mission',
    'secoto_assign_mission',
    'secoto_transition_mission',
    'secoto_delete_unstarted_mission',
    'secoto_approve_request',
    'secoto_reject_request',
    'secoto_admin_set_transporter_status',
    'secoto_admin_set_document_status',
    'secoto_register_transporter_document',
    'secoto_finalize_tracking_event',
    'secoto_create_expense',
    'secoto_admin_review_expense',
    'secoto_register_push_device',
    'secoto_register_web_push',
    'secoto_deactivate_push_device',
    'secoto_emit_business_event',
    'secoto_claim_push_outbox',
    'secoto_complete_push_outbox',
    'secoto_prepare_account_deletion',
    'secoto_finalize_account_deletion',
    'secoto_complete_account_deletion',
    'secoto_fail_account_deletion'
  ];
begin
  for v_function in
    select p.oid::regprocedure as signature
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname = any(v_names)
  loop
    execute format(
      'revoke all on function %s from public, anon, authenticated',
      v_function.signature
    );
  end loop;
end
$revoke_api$;

revoke all on public.secoto_missions_admin_v2
  from public, anon, authenticated;
revoke all on public.secoto_missions_client_v2
  from public, anon, authenticated;
revoke all on public.secoto_missions_transporter_v2
  from public, anon, authenticated;
revoke all on public.secoto_public_missions_v2
  from public, anon, authenticated;

notify pgrst, 'reload schema';
commit;
