-- ============================================================================
-- SECOTO — migration 024 : réparation des candidatures, du parcours terrain
-- et du pilotage administrateur.
-- ----------------------------------------------------------------------------
-- INCIDENT TRAITÉ (05/09/2026, capture transporteur) :
--   « Could not find the function public.secoto_apply_to_mission(
--      p_idempotency_key, p_message, p_mission_id, p_proposed_price)
--      in schema cache »
--
-- CAUSE RACINE : la migration 013 a ajouté 5 paramètres à
-- `secoto_apply_to_mission` SANS DEFAULT, et la 015 a supprimé toutes les
-- autres surcharges. La signature exposée exige donc 9 arguments nommés.
-- Toute application déjà installée (web en cache, iOS 1.2/1.3, Android non
-- mis à jour) n'en envoie que 4 : PostgREST ne trouve AUCUNE fonction
-- correspondante et la candidature échoue — définitivement, sans recours,
-- pour tout transporteur qui n'a pas la toute dernière version.
--
-- RÈGLE ADOPTÉE DÉFINITIVEMENT : toute fonction exposée via PostgREST doit
-- rester appelable par les versions PRÉCÉDENTES de l'application :
--   1. on n'insère jamais un paramètre au milieu ;
--   2. tout paramètre ajouté après la première mise en production porte un
--      DEFAULT ;
--   3. une seule signature par nom de fonction (sinon PostgREST refuse de
--      choisir : incident du 25/08/2026).
-- Les gardes finales de cette migration vérifient 2 et 3 automatiquement.
--
-- AUTRES RÉPARATIONS
--   · Le pilotage manuel (021) laissait l'administrateur écrire `status` et
--     `progress_status` sans créer d'évènement de suivi. La séquence stricte
--     de `secoto_finalize_tracking_event` devenait alors impossible à
--     satisfaire : le transporteur ne pouvait plus ni envoyer son état des
--     lieux (403 au dépôt Storage) ni valider sa livraison. Impasse totale.
--   · Aucun moyen pour l'administrateur de RENDRE LA MAIN au transporteur
--     après une fausse manœuvre ou un état des lieux à refaire.
--   · Messages d'erreur SQL sans accents et incompréhensibles sur le terrain.
--   · Aucune vue des missions bloquées côté direction.
--
-- Transactionnelle, idempotente, rejouable. Aucune donnée supprimée.
-- ============================================================================

begin;

-- ----------------------------------------------------------------------------
-- 0. GARDES D'ENTRÉE
-- ----------------------------------------------------------------------------
do $guard$
begin
  if to_regclass('public.missions') is null
     or to_regclass('public.mission_applications') is null
     or to_regclass('public.mission_tracking_events') is null then
    raise exception 'Socle SECOTO absent : appliquez les migrations 0001 a 0021 avant celle-ci.';
  end if;
end
$guard$;

-- ----------------------------------------------------------------------------
-- 1. CANDIDATURE TRANSPORTEUR — signature compatible avec TOUTES les versions
-- ----------------------------------------------------------------------------
-- Suppression de toutes les surcharges avant recréation : `create or replace`
-- ne remplace pas une fonction dont le nombre de paramètres change, il en
-- AJOUTE une, et PostgREST refuse alors de choisir.
do $dedupe$
declare
  v_fn record;
begin
  for v_fn in
    select p.oid::regprocedure as signature
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname = 'secoto_apply_to_mission'
  loop
    execute format('drop function %s', v_fn.signature);
  end loop;
end
$dedupe$;

-- Les cinq derniers paramètres portent un DEFAULT : une application ancienne
-- qui n'envoie que (mission, tarif, message, clé) est de nouveau acceptée.
-- Les disponibilités deviennent facultatives ; quand elles sont fournies,
-- elles doivent l'être ENTIÈREMENT et rester cohérentes.
create or replace function public.secoto_apply_to_mission(
  p_mission_id uuid,
  p_proposed_price numeric,
  p_message text,
  p_idempotency_key uuid,
  p_pickup_earliest_at timestamptz default null,
  p_pickup_latest_at timestamptz default null,
  p_delivery_earliest_at timestamptz default null,
  p_delivery_latest_at timestamptz default null,
  p_proposed_price_grouped numeric default null
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
  v_windows integer;
begin
  if not secoto_private.is_verified_transporter(v_user_id) then
    raise exception 'Votre compte transporteur doit être vérifié par SECOTO avant de candidater.';
  end if;

  if p_proposed_price is null or p_proposed_price <= 0 then
    raise exception 'Indiquez le tarif que vous demandez pour cette mission.';
  end if;
  if p_proposed_price > 1000000 then
    raise exception 'Le tarif demandé dépasse la limite autorisée.';
  end if;
  if p_proposed_price_grouped is not null
     and (p_proposed_price_grouped <= 0 or p_proposed_price_grouped > 1000000) then
    raise exception 'Le tarif groupé indiqué est invalide.';
  end if;

  -- Disponibilités : tout ou rien. Zéro = « je m''adapte », accepté.
  v_windows :=
      (case when p_pickup_earliest_at   is not null then 1 else 0 end)
    + (case when p_pickup_latest_at     is not null then 1 else 0 end)
    + (case when p_delivery_earliest_at is not null then 1 else 0 end)
    + (case when p_delivery_latest_at   is not null then 1 else 0 end);
  if v_windows not in (0, 4) then
    raise exception 'Renseignez les quatre dates de disponibilité, ou aucune.';
  end if;
  if v_windows = 4 then
    if p_pickup_earliest_at > p_pickup_latest_at then
      raise exception 'La fin de votre disponibilité d''enlèvement doit suivre son début.';
    end if;
    if p_delivery_earliest_at > p_delivery_latest_at then
      raise exception 'La fin de votre disponibilité de livraison doit suivre son début.';
    end if;
    if p_delivery_latest_at < p_pickup_earliest_at then
      raise exception 'La livraison ne peut pas être proposée avant l''enlèvement.';
    end if;
  end if;

  if p_message is not null and length(p_message) > 2000 then
    raise exception 'Votre message est trop long (2000 caractères maximum).';
  end if;

  v_existing := secoto_private.lock_operation('apply_to_mission', p_idempotency_key);
  if v_existing is not null then return v_existing; end if;

  select * into v_mission from public.missions m where m.id = p_mission_id for update;
  if not found then
    raise exception 'Cette mission n''existe plus.';
  end if;
  if v_mission.status::text <> 'published' or v_mission.assigned_transporter_id is not null then
    raise exception 'Cette mission n''accepte plus de candidature : elle a été attribuée ou retirée.';
  end if;
  if not secoto_private.transporter_matches_mission(v_user_id, p_mission_id) then
    raise exception 'Cette mission ne correspond pas aux capacités de transport validées sur votre compte.'
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

-- ----------------------------------------------------------------------------
-- 2. PRÉFÉRENCES DE NOTIFICATION — même traitement de compatibilité
-- ----------------------------------------------------------------------------
do $dedupe_prefs$
declare
  v_fn record;
begin
  for v_fn in
    select p.oid::regprocedure as signature
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname = 'secoto_update_notification_preferences'
  loop
    execute format('drop function %s', v_fn.signature);
  end loop;
end
$dedupe_prefs$;

-- Tous les paramètres portent un DEFAULT : un écran ancien qui n'envoie que
-- cinq préférences fonctionne, et un paramètre omis conserve sa valeur.
create or replace function public.secoto_update_notification_preferences(
  p_push_enabled boolean default null,
  p_email_enabled boolean default null,
  p_mute_missions boolean default null,
  p_mute_documents boolean default null,
  p_mute_frais boolean default null,
  p_cash_sound_enabled boolean default null
)
returns public.notification_preferences
language plpgsql
volatile
security definer
set search_path = ''
as $function$
declare
  v_user_id uuid := secoto_private.assert_authenticated();
  v_row public.notification_preferences%rowtype;
begin
  insert into public.notification_preferences as np (
    account_id, push_enabled, email_enabled,
    mute_missions, mute_documents, mute_frais,
    cash_sound_enabled, updated_at
  )
  values (
    v_user_id, coalesce(p_push_enabled, true), coalesce(p_email_enabled, true),
    coalesce(p_mute_missions, false), coalesce(p_mute_documents, false),
    coalesce(p_mute_frais, false), coalesce(p_cash_sound_enabled, true), now()
  )
  on conflict (account_id) do update set
    push_enabled       = coalesce(p_push_enabled, np.push_enabled),
    email_enabled      = coalesce(p_email_enabled, np.email_enabled),
    mute_missions      = coalesce(p_mute_missions, np.mute_missions),
    mute_documents     = coalesce(p_mute_documents, np.mute_documents),
    mute_frais         = coalesce(p_mute_frais, np.mute_frais),
    cash_sound_enabled = coalesce(p_cash_sound_enabled, np.cash_sound_enabled),
    updated_at         = now()
  returning * into v_row;
  return v_row;
end;
$function$;

revoke all on function public.secoto_update_notification_preferences(
  boolean, boolean, boolean, boolean, boolean, boolean) from public, anon;
grant execute on function public.secoto_update_notification_preferences(
  boolean, boolean, boolean, boolean, boolean, boolean) to authenticated;

-- ----------------------------------------------------------------------------
-- 3. TRAÇABILITÉ DES ÉTAPES : origine et réouverture
-- ----------------------------------------------------------------------------
-- `source` distingue ce que le transporteur a constaté sur le terrain de ce
-- que la direction a saisi à la main. `superseded_at` permet à SECOTO de
-- DEMANDER UN NOUVEL ÉTAT DES LIEUX sans jamais effacer la preuve précédente.
alter table public.mission_tracking_events
  add column if not exists source text not null default 'transporter',
  add column if not exists superseded_at timestamptz,
  add column if not exists superseded_by uuid,
  add column if not exists supersede_reason text;

do $c$
begin
  if not exists (
    select 1 from pg_constraint where conname = 'mission_tracking_events_source_check'
  ) then
    alter table public.mission_tracking_events
      add constraint mission_tracking_events_source_check
      check (source in ('transporter', 'admin'));
  end if;
end
$c$;

create index if not exists idx_secoto_tracking_events_mission_live
  on public.mission_tracking_events(mission_id, event_type)
  where superseded_at is null;

comment on column public.mission_tracking_events.source is
  'transporter = constate sur le terrain ; admin = saisi par la direction SECOTO.';
comment on column public.mission_tracking_events.superseded_at is
  'Etape rouverte par SECOTO : la preuve reste, mais elle ne bloque plus la sequence.';

-- ----------------------------------------------------------------------------
-- 4. DÉPÔT DES PHOTOS — la garde Storage ne doit plus dépendre d'un seul statut
-- ----------------------------------------------------------------------------
-- Avant : `status = 'assigned'` strictement. Dès que la direction clôturait la
-- mission, le dépôt renvoyait 403 sans explication et l'état des lieux était
-- perdu. Désormais le transporteur assigné peut aussi terminer, pendant 48 h
-- après clôture, un envoi commencé hors ligne.
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
      and m.status::text in ('assigned', 'completed')
      and (
        m.status::text = 'assigned'
        or coalesce(m.updated_at, m.created_at, now()) > now() - interval '48 hours'
      )
  );
$function$;

-- ----------------------------------------------------------------------------
-- 5. PARCOURS TERRAIN — séquence tolérante et messages en français
-- ----------------------------------------------------------------------------
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
  v_current text;
  v_pickup_done boolean;
  v_delivery_done boolean;
  v_latitude double precision;
  v_longitude double precision;
  v_accuracy double precision;
  v_index integer := 0;
begin
  v_existing := secoto_private.lock_operation('finalize_tracking_event', p_idempotency_key);
  if v_existing is not null then return v_existing; end if;

  if p_event_type not in ('pickup_inspection', 'road_incident', 'delivery_inspection') then
    raise exception 'Étape de mission inconnue.';
  end if;
  if jsonb_typeof(coalesce(p_files, '[]'::jsonb)) <> 'array' then
    raise exception 'La liste des photos est illisible. Reprenez l''envoi.';
  end if;
  v_file_count := jsonb_array_length(coalesce(p_files, '[]'::jsonb));
  if v_file_count > 10 then
    raise exception '10 photos maximum par étape.';
  end if;
  if p_event_type in ('pickup_inspection', 'delivery_inspection')
     and not exists (
       select 1 from jsonb_array_elements(coalesce(p_files, '[]'::jsonb)) f
       where f ->> 'mime_type' in ('image/jpeg', 'image/png', 'image/webp')
     ) then
    raise exception 'Ajoutez au moins une photo : elle fait office d''état des lieux.';
  end if;

  select * into v_mission from public.missions m where m.id = p_mission_id for update;
  if not found then
    raise exception 'Cette mission n''existe plus.';
  end if;
  if v_mission.assigned_transporter_id is distinct from v_user_id then
    raise exception 'Cette mission ne vous est pas attribuée.';
  end if;
  if v_mission.status::text not in ('assigned', 'completed') then
    raise exception 'Cette mission n''est plus en cours (statut « % »). Contactez SECOTO pour la rouvrir.',
      v_mission.status;
  end if;

  v_current := coalesce(nullif(v_mission.progress_status, ''), 'assigned_pending');

  -- Une étape est « faite » si le terrain l'a transmise (évènement vivant) OU
  -- si la direction a fait avancer la mission à la main.
  v_pickup_done := exists (
      select 1 from public.mission_tracking_events e
      where e.mission_id = p_mission_id
        and e.event_type::text = 'pickup_inspection'
        and e.superseded_at is null
    ) or v_current in (
      'pickup_completed', 'in_transit', 'incident_reported',
      'delivery_started', 'delivery_completed', 'completed'
    );

  v_delivery_done := exists (
      select 1 from public.mission_tracking_events e
      where e.mission_id = p_mission_id
        and e.event_type::text = 'delivery_inspection'
        and e.superseded_at is null
    ) or v_current in ('delivery_completed', 'completed');

  if p_event_type = 'pickup_inspection' and v_pickup_done then
    raise exception 'La prise en charge de cette mission a déjà été enregistrée. Demandez à SECOTO de la rouvrir si vous devez la refaire.';
  end if;
  if p_event_type in ('road_incident', 'delivery_inspection') and not v_pickup_done then
    raise exception 'Transmettez d''abord l''état des lieux de départ.';
  end if;
  if p_event_type = 'delivery_inspection' and v_delivery_done then
    raise exception 'La livraison de cette mission a déjà été validée.';
  end if;

  v_progress := case p_event_type
    when 'pickup_inspection' then 'pickup_completed'
    when 'road_incident' then 'incident_reported'
    when 'delivery_inspection' then 'delivery_completed'
  end;
  if coalesce(p_payload ->> 'expected_progress_status', v_progress) <> v_progress then
    raise exception 'L''application et le serveur ne sont pas d''accord sur l''étape. Actualisez la page puis réessayez.';
  end if;

  -- Un incident ne doit jamais faire reculer une mission déjà livrée.
  if p_event_type = 'road_incident' and v_delivery_done then
    v_progress := v_current;
  end if;

  if (p_payload ->> 'latitude') is not null
     or (p_payload ->> 'longitude') is not null
     or (p_payload ->> 'location_accuracy_m') is not null then
    if (p_payload ->> 'latitude') is null
       or (p_payload ->> 'longitude') is null
       or (p_payload ->> 'location_accuracy_m') is null then
      raise exception 'La position transmise est incomplète. Réessayez, ou continuez sans position.';
    end if;
    v_latitude := (p_payload ->> 'latitude')::double precision;
    v_longitude := (p_payload ->> 'longitude')::double precision;
    v_accuracy := (p_payload ->> 'location_accuracy_m')::double precision;
    if v_latitude not between -90 and 90
       or v_longitude not between -180 and 180
       or v_accuracy not between 0 and 10000 then
      raise exception 'La position transmise est invalide. Continuez sans position si le GPS n''accroche pas.';
    end if;
  end if;

  for v_file in select value from jsonb_array_elements(coalesce(p_files, '[]'::jsonb))
  loop
    if v_file ->> 'mime_type' not in ('image/jpeg', 'image/png', 'image/webp', 'application/pdf')
       or (v_file ->> 'mime_type' = 'application/pdf' and p_event_type <> 'road_incident') then
      raise exception 'Format de fichier refusé : envoyez des photos (JPG, PNG ou WebP).';
    end if;
    if coalesce((v_file ->> 'size_bytes')::bigint, 0) not between 1 and 12582912 then
      raise exception 'Une photo dépasse 12 Mo ou n''a pas pu être lue.';
    end if;
    if v_file ->> 'file_path' is null
       or v_file ->> 'file_path' like '/%'
       or v_file ->> 'file_path' like '%..%'
       or split_part(v_file ->> 'file_path', '/', 1) <> v_user_id::text
       or split_part(v_file ->> 'file_path', '/', 2) <> p_mission_id::text
       or split_part(v_file ->> 'file_path', '/', 3) <> p_idempotency_key::text
       or not exists (
         select 1 from storage.objects o
         where o.bucket_id = 'mission-photos'
           and o.name = v_file ->> 'file_path'
           and coalesce((o.metadata ->> 'size')::bigint, (v_file ->> 'size_bytes')::bigint)
               = (v_file ->> 'size_bytes')::bigint
           and lower(coalesce(o.metadata ->> 'mimetype', v_file ->> 'mime_type'))
               = lower(v_file ->> 'mime_type')
       ) then
      raise exception 'Une photo n''est pas arrivée jusqu''au serveur. Relancez l''envoi de cette étape.';
    end if;
  end loop;

  insert into public.mission_tracking_events(
    mission_id, transporter_id, event_type, title, comment,
    odometer_km, fuel_level, issue_type, issue_severity,
    latitude, longitude, location_accuracy_m, location_recorded_at,
    idempotency_key, source
  )
  values (
    p_mission_id, v_user_id, p_event_type,
    case p_event_type
      when 'pickup_inspection' then 'État des lieux de départ'
      when 'road_incident' then 'Incident signalé'
      else 'État des lieux d''arrivée'
    end,
    secoto_private.safe_text(p_payload, 'comment', 4000, false),
    secoto_private.safe_numeric(p_payload, 'odometer_km', 0, 5000000, null),
    case when coalesce(p_payload ->> 'fuel_level', 'unknown')
           in ('unknown', 'reserve', '1/4', '1/2', '3/4', 'full')
         then coalesce(p_payload ->> 'fuel_level', 'unknown')
         else 'unknown' end,
    case when p_event_type = 'road_incident'
         then secoto_private.safe_text(p_payload, 'issue_type', 120, false) else null end,
    case when p_event_type = 'road_incident'
         then secoto_private.safe_text(p_payload, 'issue_severity', 40, false) else null end,
    v_latitude, v_longitude, v_accuracy,
    case when v_latitude is not null then now() else null end,
    p_idempotency_key, 'transporter'
  )
  returning * into v_event;

  for v_file in select value from jsonb_array_elements(coalesce(p_files, '[]'::jsonb))
  loop
    insert into public.mission_tracking_photos(
      tracking_event_id, mission_id, transporter_id,
      photo_type, file_name, file_path, file_url,
      mime_type, size_bytes, idempotency_key
    ) values (
      v_event.id, p_mission_id, v_user_id,
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

  -- Comportement inchangé : la validation de la livraison clôture la mission.
  update public.missions
     set progress_status = v_progress,
         status = case when p_event_type = 'delivery_inspection'
                       then 'completed' else status end
   where id = p_mission_id
  returning * into v_mission;

  perform secoto_private.notify_admins(
    case when p_event_type = 'delivery_inspection' then 'delivered' else 'tracking' end,
    p_mission_id, 'assigned',
    'tracking:' || v_event.id::text
  );

  if v_mission.client_account_id is not null then
    perform secoto_private.notify_one(
      v_mission.client_account_id,
      case when p_event_type = 'delivery_inspection' then 'delivered' else 'tracking' end,
      p_mission_id, 'courses',
      'tracking-client:' || v_event.id::text
    );
  end if;

  return secoto_private.finish_operation(
    'finalize_tracking_event', p_idempotency_key,
    to_jsonb(v_event) || jsonb_build_object('photos_count', v_index)
  );
end;
$function$;

-- ----------------------------------------------------------------------------
-- 6. PILOTAGE MANUEL — l'administrateur ne casse plus le terrain
-- ----------------------------------------------------------------------------
-- Quand la direction fait avancer une mission à la main jusqu'à une étape qui
-- suppose la prise en charge faite, un évènement `source = 'admin'` est créé.
-- La séquence terrain reste donc cohérente, et la timeline dit clairement que
-- l'étape a été saisie par SECOTO et non constatée sur place.
create or replace function public.secoto_admin_set_mission_stage(
  p_mission_id uuid,
  p_status text,
  p_progress_status text,
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
  v_mission  public.missions%rowtype;
  v_status   text;
  v_progress text;
  v_needs_pickup boolean;
begin
  v_existing := secoto_private.lock_operation('admin_set_stage', p_idempotency_key);
  if v_existing is not null then return v_existing; end if;

  select * into v_mission from public.missions m where m.id = p_mission_id for update;
  if not found then raise exception 'Mission introuvable.'; end if;

  v_status   := coalesce(nullif(p_status, ''), v_mission.status::text);
  v_progress := coalesce(nullif(p_progress_status, ''), nullif(v_mission.progress_status, ''), 'assigned_pending');

  if v_status not in ('published', 'assigned', 'completed', 'cancelled') then
    raise exception 'Statut de mission inconnu : %.', v_status;
  end if;
  if v_progress not in (
    'assigned_pending', 'pickup_started', 'pickup_completed', 'in_transit',
    'incident_reported', 'delivery_started', 'delivery_completed', 'completed'
  ) then
    raise exception 'Étape de mission inconnue : %.', v_progress;
  end if;
  if v_status in ('assigned', 'completed') and v_mission.assigned_transporter_id is null then
    raise exception 'Attribuez d''abord un transporteur à cette mission.';
  end if;

  -- L'étape visée suppose-t-elle une prise en charge déjà faite ?
  v_needs_pickup := v_progress in (
    'pickup_completed', 'in_transit', 'incident_reported',
    'delivery_started', 'delivery_completed', 'completed'
  );

  if v_needs_pickup
     and v_mission.assigned_transporter_id is not null
     and not exists (
       select 1 from public.mission_tracking_events e
       where e.mission_id = p_mission_id
         and e.event_type::text = 'pickup_inspection'
         and e.superseded_at is null
     ) then
    insert into public.mission_tracking_events(
      mission_id, transporter_id, event_type, title, comment,
      fuel_level, idempotency_key, source
    ) values (
      p_mission_id, v_mission.assigned_transporter_id, 'pickup_inspection',
      'Prise en charge enregistrée par SECOTO',
      'Étape saisie manuellement par la direction : aucun état des lieux photo n''a été transmis par le transporteur.',
      'unknown', p_idempotency_key, 'admin'
    );
  end if;

  update public.missions
     set status          = v_status,
         progress_status = v_progress
   where id = p_mission_id
  returning * into v_mission;

  return secoto_private.finish_operation(
    'admin_set_stage', p_idempotency_key, to_jsonb(v_mission));
end;
$function$;

revoke all on function public.secoto_admin_set_mission_stage(uuid, text, text, uuid)
  from public, anon;
grant execute on function public.secoto_admin_set_mission_stage(uuid, text, text, uuid)
  to authenticated;

-- ----------------------------------------------------------------------------
-- 7. NOUVEAU — « rendre la main au transporteur »
-- ----------------------------------------------------------------------------
-- Un seul geste pour l'administrateur : rouvrir une étape (ou toute la
-- mission) quand l'état des lieux est raté, incomplet, ou quand une fausse
-- manœuvre a mis la mission dans une impasse. Les preuves déjà transmises ne
-- sont JAMAIS supprimées : elles sont marquées « remplacées » et restent
-- consultables et opposables.
create or replace function public.secoto_admin_reopen_field_step(
  p_mission_id uuid,
  p_step text,
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
  v_mission  public.missions%rowtype;
  v_step     text := lower(coalesce(nullif(btrim(p_step), ''), 'all'));
  v_progress text;
  v_touched  integer := 0;
begin
  v_existing := secoto_private.lock_operation('admin_reopen_step', p_idempotency_key);
  if v_existing is not null then return v_existing; end if;

  if v_step not in ('pickup', 'delivery', 'all') then
    raise exception 'Étape à rouvrir inconnue : %.', v_step;
  end if;

  select * into v_mission from public.missions m where m.id = p_mission_id for update;
  if not found then raise exception 'Mission introuvable.'; end if;
  if v_mission.assigned_transporter_id is null then
    raise exception 'Cette mission n''a pas de transporteur : attribuez-la d''abord.';
  end if;

  update public.mission_tracking_events e
     set superseded_at    = now(),
         superseded_by    = v_admin_id,
         supersede_reason = left(coalesce(p_reason, 'Étape rouverte par SECOTO.'), 500)
   where e.mission_id = p_mission_id
     and e.superseded_at is null
     and (
       (v_step = 'pickup'   and e.event_type::text = 'pickup_inspection')
       or (v_step = 'delivery' and e.event_type::text = 'delivery_inspection')
       or (v_step = 'all'      and e.event_type::text in ('pickup_inspection', 'delivery_inspection'))
     );
  get diagnostics v_touched = row_count;

  v_progress := case v_step
    when 'delivery' then 'in_transit'
    else 'assigned_pending'
  end;

  update public.missions
     set status          = 'assigned',
         progress_status = v_progress
   where id = p_mission_id
  returning * into v_mission;

  perform secoto_private.notify_one(
    v_mission.assigned_transporter_id, 'course_assigned', p_mission_id, 'assigned',
    'reopen:' || p_mission_id::text || ':' || p_idempotency_key::text);

  return secoto_private.finish_operation(
    'admin_reopen_step', p_idempotency_key,
    jsonb_build_object(
      'mission', to_jsonb(v_mission),
      'superseded_events', v_touched,
      'step', v_step));
end;
$function$;

revoke all on function public.secoto_admin_reopen_field_step(uuid, text, text, uuid)
  from public, anon;
grant execute on function public.secoto_admin_reopen_field_step(uuid, text, text, uuid)
  to authenticated;

-- ----------------------------------------------------------------------------
-- 8. NOUVEAU — vue « ce qui est bloqué », réservée à la direction
-- ----------------------------------------------------------------------------
-- Répond à la seule question qui compte le matin : qu'est-ce qui n'avancera
-- pas tout seul aujourd'hui ?
create or replace view public.secoto_admin_alertes_v1
with (security_barrier = true, security_invoker = false)
as
select
  m.id as mission_id,
  m.public_ref,
  m.status::text as status,
  coalesce(nullif(m.progress_status, ''), 'assigned_pending') as progress_status,
  m.from_city,
  m.to_city,
  m.mission_date,
  m.assigned_transporter_id,
  m.assigned_transporter_name,
  m.created_at,
  case
    when m.status::text = 'published'
     and m.created_at < now() - interval '48 hours'
     and not exists (
       select 1 from public.mission_applications a
       where a.mission_id = m.id and a.status::text = 'pending')
      then 'sans_candidature'
    when m.status::text = 'published'
     and exists (
       select 1 from public.mission_applications a
       where a.mission_id = m.id and a.status::text = 'pending'
         and a.created_at < now() - interval '24 hours')
      then 'candidature_en_attente'
    when m.status::text = 'assigned'
     and coalesce(nullif(m.progress_status, ''), 'assigned_pending') = 'assigned_pending'
     and m.created_at < now() - interval '24 hours'
      then 'prise_en_charge_en_retard'
    when m.status::text = 'assigned'
     and coalesce(nullif(m.progress_status, ''), 'assigned_pending')
         in ('pickup_completed', 'in_transit', 'delivery_started')
     and coalesce(
           (select max(e.created_at) from public.mission_tracking_events e
             where e.mission_id = m.id and e.superseded_at is null),
           m.created_at) < now() - interval '24 hours'
      then 'livraison_en_retard'
    when coalesce(nullif(m.progress_status, ''), '') = 'incident_reported'
      then 'incident_ouvert'
    else null
  end as alerte,
  (select max(e.created_at) from public.mission_tracking_events e
    where e.mission_id = m.id and e.superseded_at is null) as dernier_suivi_at,
  (select count(*) from public.mission_applications a
    where a.mission_id = m.id and a.status::text = 'pending') as candidatures_en_attente
from public.missions m
where public.secoto_is_admin()
  and m.status::text in ('published', 'assigned');

revoke all on table public.secoto_admin_alertes_v1 from anon;
grant select on table public.secoto_admin_alertes_v1 to authenticated;

comment on view public.secoto_admin_alertes_v1 is
  'Missions qui n''avanceront pas seules : sans candidature, candidature en attente, '
  'prise en charge ou livraison en retard, incident ouvert. Reserve a l''administrateur.';

-- ----------------------------------------------------------------------------
-- 9. GARDES DE DÉPLOIEMENT
-- ----------------------------------------------------------------------------
do $guard_final$
declare
  v_dup text;
begin
  select string_agg(proname, ', ')
    into v_dup
  from (
    select p.proname
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname like 'secoto\_%'
    group by p.proname
    having count(*) > 1
  ) d;
  if v_dup is not null then
    raise exception
      'Surcharges detectees (PostgREST ne pourra pas choisir) : %.',
      v_dup;
  end if;
end
$guard_final$;

do $guard_defaults$
declare
  v_n integer;
begin
  select pronargdefaults into v_n
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname = 'secoto_apply_to_mission';
  if coalesce(v_n, 0) < 5 then
    raise exception 'secoto_apply_to_mission doit exposer 5 parametres a DEFAULT (compatibilite des versions installees).';
  end if;

  select pronargdefaults into v_n
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname = 'secoto_update_notification_preferences';
  if coalesce(v_n, 0) < 6 then
    raise exception 'secoto_update_notification_preferences doit exposer 6 parametres a DEFAULT.';
  end if;
end
$guard_defaults$;

notify pgrst, 'reload schema';

commit;
