-- ============================================================================
-- SECOTO — MIGRATION 101 : MISSIONS — URGENT, PROPOSITIONS, MODIFICATIONS
-- ----------------------------------------------------------------------------
-- Demande de Nawfal du 19/10/2026 :
--   1. Une mission peut être marquée URGENTE (pastille visible par SECOTO et
--      par les transporteurs). Sans effet sur le prix : la majoration
--      historique « surcharge_urgent » reste neutralisée.
--   2. SECOTO modifie les informations du client et du trajet à tout moment,
--      même après attribution (adresses ajoutées après coup, téléphone d'un
--      client inscrit en cours de mission…). Le transporteur attribué est
--      prévenu par une notification.
--   3. TRANSPORT PAR PLATEAU UNIQUEMENT : le transporteur propose UN prix et
--      UNE date de disponibilité par mission. Il peut les modifier tant que
--      SECOTO n'a pas tranché ; SECOTO peut aussi les modifier. L'acceptation
--      directe (prix fixé par SECOTO) n'existe plus pour le plateau.
--   4. CONVOYAGE : le transporteur accepte la date renseignée (acceptation
--      directe, comme avant) ou propose une autre date de disponibilité, sans
--      toucher au prix (barème). SECOTO attribue alors depuis les candidatures.
--   5. Quand SECOTO attribue une proposition datée, la date de la mission
--      devient la date proposée.
--
-- ADDITIF : deux colonnes, trois vues complétées d'une colonne en fin de
-- liste, quatre fonctions nouvelles, une fonction existante complétée (refus
-- du plateau en acceptation directe), un déclencheur. Aucune donnée modifiée.
-- Rejouable.
-- ============================================================================

-- 1. Colonnes -----------------------------------------------------------------
alter table public.missions add column if not exists urgent boolean not null default false;
alter table public.mission_applications add column if not exists proposed_date timestamptz;

-- 2. Vues : « urgent » ajouté en dernière colonne (rien d'autre ne change) ---
do $vues$
declare
  v_vue text;
  v_def text;
begin
  foreach v_vue in array array['secoto_public_missions_v2', 'secoto_missions_admin_v2', 'secoto_missions_transporter_v2'] loop
    if to_regclass('public.' || v_vue) is null then continue; end if;
    v_def := pg_get_viewdef(('public.' || v_vue)::regclass);
    if v_def ~ '\murgent\M' then continue; end if;
    -- Premier « FROM missions m » : la requête principale (les sous-requêtes
    -- arrivent ensuite, dans le WHERE).
    v_def := regexp_replace(v_def, '\s+FROM\s+(public\.)?missions\s+m\M', ', m.urgent FROM public.missions m');
    if v_def !~ 'm\.urgent FROM public\.missions m' then
      raise exception 'Vue % : structure inattendue, migration interrompue.', v_vue;
    end if;
    execute format('create or replace view public.%I with (security_barrier = true, security_invoker = false) as %s', v_vue, v_def);
  end loop;
end
$vues$;

-- 3. Transporteur : proposer (ou modifier) sa date, et son prix en plateau ----
create or replace function public.secoto_mission_proposer(
  p_mission_id uuid,
  p_price numeric,
  p_date timestamptz,
  p_message text default null
) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_user uuid := secoto_private.assert_authenticated();
  v_account public.accounts%rowtype;
  v_mission public.missions%rowtype;
  v_application public.mission_applications%rowtype;
  v_price numeric;
  v_nouvelle boolean := false;
begin
  if not secoto_private.is_verified_transporter(v_user) then
    raise exception 'Votre compte transporteur doit être vérifié par SECOTO avant de proposer.';
  end if;
  select * into v_mission from public.missions m where m.id = p_mission_id for update;
  if not found then raise exception 'Cette mission n''existe plus.' using errcode = 'P0002'; end if;
  if v_mission.status::text <> 'published' or v_mission.assigned_transporter_id is not null then
    raise exception 'Cette mission a déjà été attribuée : SECOTO ne prend plus de proposition.';
  end if;
  if not secoto_private.transporter_matches_mission(v_user, p_mission_id) then
    raise exception 'Cette mission ne correspond pas aux capacités de transport validées sur votre compte.'
      using errcode = '42501';
  end if;
  if p_date is null then
    raise exception 'Indiquez votre date de disponibilité.';
  end if;
  if p_date < now() - interval '1 day' or p_date > now() + interval '400 days' then
    raise exception 'Date de disponibilité invalide.';
  end if;
  if v_mission.type::text = 'plateau' then
    if p_price is null or p_price <= 0 then
      raise exception 'Indiquez votre prix pour cette mission.';
    end if;
    if p_price > 1000000 then
      raise exception 'Le prix indiqué dépasse la limite autorisée.';
    end if;
    v_price := round(p_price, 2);
  else
    -- Convoyage : la rémunération reste celle du barème. Seule la date change.
    v_price := v_mission.carrier_pay;
  end if;
  if p_message is not null and length(p_message) > 2000 then
    raise exception 'Votre message est trop long (2000 caractères maximum).';
  end if;

  select * into v_application from public.mission_applications a
   where a.mission_id = p_mission_id and a.transporter_id = v_user for update;
  if found then
    if v_application.status::text <> 'pending' then
      raise exception 'Votre proposition a déjà été traitée par SECOTO.';
    end if;
    update public.mission_applications
       set proposed_price = v_price,
           proposed_date = p_date,
           message = nullif(btrim(coalesce(p_message, '')), '')
     where id = v_application.id
    returning * into v_application;
  else
    select * into v_account from public.accounts a where a.id = v_user;
    insert into public.mission_applications(
      mission_id, transporter_id, transporter_name, transporter_company,
      transporter_status, message, proposed_price, proposed_date, status
    ) values (
      p_mission_id, v_user, coalesce(v_account.full_name, 'Transporteur'), v_account.company_name,
      'verified', nullif(btrim(coalesce(p_message, '')), ''), v_price, p_date, 'pending'
    ) returning * into v_application;
    v_nouvelle := true;
  end if;

  perform secoto_private.notify_admins_event('new_request',
    case when v_nouvelle then 'Nouvelle proposition' else 'Proposition modifiée' end,
    format('%s · %s → %s · %s%s', v_mission.public_ref, v_mission.from_city, v_mission.to_city,
      to_char(p_date at time zone 'Europe/Paris', 'DD/MM/YYYY'),
      case when v_mission.type::text = 'plateau' then ' · ' || to_char(v_price, 'FM999G999D00') || ' €' else '' end),
    'applications',
    'proposition:' || v_application.id::text || ':' || floor(extract(epoch from clock_timestamp()))::bigint::text,
    p_mission_id);
  perform secoto_private.audit(
    case when v_nouvelle then 'mission_proposal_created' else 'mission_proposal_updated' end,
    'mission', p_mission_id::text,
    jsonb_build_object('application_id', v_application.id, 'price', v_price, 'date', p_date));

  return to_jsonb(v_application);
end;
$$;

-- 4. SECOTO : modifier une proposition encore en attente ---------------------
create or replace function public.secoto_admin_application_update(
  p_application_id uuid,
  p_price numeric,
  p_date timestamptz
) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_admin uuid := secoto_private.assert_admin();
  v_application public.mission_applications%rowtype;
  v_mission public.missions%rowtype;
begin
  select * into v_application from public.mission_applications a where a.id = p_application_id for update;
  if not found then raise exception 'Proposition introuvable.' using errcode = 'P0002'; end if;
  if v_application.status::text <> 'pending' then
    raise exception 'Proposition déjà traitée : modifiez directement la mission (date, montants).';
  end if;
  select * into v_mission from public.missions m where m.id = v_application.mission_id;
  if p_date is not null and (p_date < now() - interval '1 day' or p_date > now() + interval '400 days') then
    raise exception 'Date de disponibilité invalide.';
  end if;
  if v_mission.type::text = 'plateau' and p_price is not null and (p_price <= 0 or p_price > 1000000) then
    raise exception 'Prix invalide.';
  end if;
  update public.mission_applications
     set proposed_price = case when v_mission.type::text = 'plateau' and p_price is not null
                               then round(p_price, 2) else proposed_price end,
         proposed_date = coalesce(p_date, proposed_date)
   where id = p_application_id
  returning * into v_application;
  perform secoto_private.audit('mission_proposal_admin_updated', 'mission', v_mission.id::text,
    jsonb_build_object('application_id', p_application_id, 'price', v_application.proposed_price,
                       'date', v_application.proposed_date, 'admin', v_admin));
  return to_jsonb(v_application);
end;
$$;

-- 5. SECOTO : modifier les informations du client et du trajet --------------
-- Clés absentes : inchangées. Clés présentes et vides : effacées, sauf les
-- villes, la date et le véhicule, qui ne peuvent pas être vidés.
create or replace function public.secoto_admin_update_mission(p_mission_id uuid, p_patch jsonb)
returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_admin uuid := secoto_private.assert_admin();
  v_mission public.missions%rowtype;
  v_avant public.missions%rowtype;
  v_cles text[];
  v_inconnues text[];
  v_date timestamptz;
  v_km integer;
  v_changes text[] := '{}';
  v_destinataire uuid;
  v_txt text;
begin
  if p_patch is null or jsonb_typeof(p_patch) <> 'object' then
    raise exception 'Modifications invalides.';
  end if;
  select array_agg(k) into v_cles from jsonb_object_keys(p_patch) k;
  select array_agg(k) into v_inconnues from unnest(coalesce(v_cles, '{}')) k
   where k not in ('from_city', 'to_city', 'pickup_address', 'delivery_address', 'mission_date', 'vehicle',
                   'plate', 'distance_km', 'client_name', 'client_contact', 'client_phone', 'notes',
                   'urgent', 'vehicle_category');
  if v_inconnues is not null then
    raise exception 'Champ non modifiable : %', array_to_string(v_inconnues, ', ');
  end if;

  select * into v_avant from public.missions m where m.id = p_mission_id for update;
  if not found then raise exception 'Mission introuvable.' using errcode = 'P0002'; end if;
  if v_avant.status::text = 'cancelled' then
    raise exception 'Mission annulée : elle ne se modifie plus.';
  end if;

  -- Contrôles de forme (messages en clair pour l'écran d'administration).
  foreach v_txt in array array['from_city', 'to_city', 'vehicle'] loop
    if p_patch ? v_txt and nullif(btrim(coalesce(p_patch ->> v_txt, '')), '') is null then
      raise exception 'Ce champ ne peut pas être vide : %', case v_txt when 'from_city' then 'ville de départ'
        when 'to_city' then 'ville d''arrivée' else 'véhicule' end;
    end if;
  end loop;
  if p_patch ? 'mission_date' then
    begin
      v_date := nullif(p_patch ->> 'mission_date', '')::timestamptz;
    exception when others then raise exception 'Date invalide.';
    end;
    if v_date is null then raise exception 'La date ne peut pas être vide.'; end if;
  end if;
  if p_patch ? 'distance_km' and nullif(p_patch ->> 'distance_km', '') is not null then
    begin
      v_km := round((p_patch ->> 'distance_km')::numeric)::integer;
    exception when others then raise exception 'Distance invalide.';
    end;
    if v_km < 0 or v_km > 6000 then raise exception 'Distance invalide (0 à 6 000 km).'; end if;
  end if;
  if p_patch ? 'urgent' and jsonb_typeof(p_patch -> 'urgent') <> 'boolean' then
    raise exception 'Urgent : oui ou non.';
  end if;
  if p_patch ? 'vehicle_category' and coalesce(p_patch ->> 'vehicle_category', '') not in ('standard', 'luxury') then
    raise exception 'Catégorie de véhicule invalide.';
  end if;
  if length(coalesce(p_patch ->> 'notes', '')) > 4000 then
    raise exception 'Notes trop longues (4 000 caractères).';
  end if;

  update public.missions m set
    from_city        = case when p_patch ? 'from_city' then left(btrim(p_patch ->> 'from_city'), 120) else m.from_city end,
    to_city          = case when p_patch ? 'to_city' then left(btrim(p_patch ->> 'to_city'), 120) else m.to_city end,
    pickup_address   = case when p_patch ? 'pickup_address' then nullif(left(btrim(coalesce(p_patch ->> 'pickup_address', '')), 300), '') else m.pickup_address end,
    delivery_address = case when p_patch ? 'delivery_address' then nullif(left(btrim(coalesce(p_patch ->> 'delivery_address', '')), 300), '') else m.delivery_address end,
    mission_date     = case when p_patch ? 'mission_date' then v_date else m.mission_date end,
    vehicle          = case when p_patch ? 'vehicle' then left(btrim(p_patch ->> 'vehicle'), 160) else m.vehicle end,
    plate            = case when p_patch ? 'plate' then nullif(upper(left(btrim(coalesce(p_patch ->> 'plate', '')), 20)), '') else m.plate end,
    distance_km      = case when p_patch ? 'distance_km' then v_km else m.distance_km end,
    client_name      = case when p_patch ? 'client_name' then nullif(left(btrim(coalesce(p_patch ->> 'client_name', '')), 160), '') else m.client_name end,
    client_contact   = case when p_patch ? 'client_contact' then nullif(left(btrim(coalesce(p_patch ->> 'client_contact', '')), 160), '') else m.client_contact end,
    client_phone     = case when p_patch ? 'client_phone' then nullif(left(btrim(coalesce(p_patch ->> 'client_phone', '')), 40), '') else m.client_phone end,
    notes            = case when p_patch ? 'notes' then nullif(btrim(coalesce(p_patch ->> 'notes', '')), '') else m.notes end,
    urgent           = case when p_patch ? 'urgent' then (p_patch ->> 'urgent')::boolean else m.urgent end,
    vehicle_category = case when p_patch ? 'vehicle_category' then p_patch ->> 'vehicle_category' else m.vehicle_category end
  where m.id = p_mission_id
  returning * into v_mission;

  -- Ce qui a réellement changé (pour l'historique et la notification).
  if v_mission.from_city is distinct from v_avant.from_city or v_mission.to_city is distinct from v_avant.to_city
     or v_mission.pickup_address is distinct from v_avant.pickup_address
     or v_mission.delivery_address is distinct from v_avant.delivery_address then
    v_changes := array_append(v_changes, 'adresses');
  end if;
  if v_mission.mission_date is distinct from v_avant.mission_date then v_changes := array_append(v_changes, 'date'); end if;
  if v_mission.vehicle is distinct from v_avant.vehicle or v_mission.plate is distinct from v_avant.plate
     or v_mission.vehicle_category is distinct from v_avant.vehicle_category then
    v_changes := array_append(v_changes, 'véhicule');
  end if;
  if v_mission.client_name is distinct from v_avant.client_name or v_mission.client_contact is distinct from v_avant.client_contact
     or v_mission.client_phone is distinct from v_avant.client_phone then
    v_changes := array_append(v_changes, 'client');
  end if;
  if v_mission.distance_km is distinct from v_avant.distance_km then v_changes := array_append(v_changes, 'distance'); end if;
  if v_mission.notes is distinct from v_avant.notes then v_changes := array_append(v_changes, 'consignes'); end if;
  if v_mission.urgent is distinct from v_avant.urgent then v_changes := array_append(v_changes, 'urgence'); end if;

  perform secoto_private.audit('mission_admin_updated', 'mission', p_mission_id::text,
    jsonb_build_object('admin', v_admin, 'champs', v_cles, 'changements', v_changes));

  -- Transporteur attribué (et chauffeur salarié) : prévenu du changement.
  if array_length(v_changes, 1) > 0 and v_mission.status::text = 'assigned' then
    foreach v_destinataire in array array_remove(array[v_mission.assigned_transporter_id, v_mission.carrier_employee_id], null) loop
      perform secoto_private.notify_event(v_destinataire, 'order_update', 'Mission mise à jour',
        format('%s : SECOTO a modifié %s.', v_mission.public_ref, array_to_string(v_changes, ', ')),
        p_mission_id, 'assigned',
        'mission-maj:' || p_mission_id::text || ':' || v_destinataire::text || ':' || floor(extract(epoch from clock_timestamp()))::bigint::text,
        p_mission_id);
    end loop;
  end if;

  return jsonb_build_object('mission_id', p_mission_id, 'changements', to_jsonb(v_changes));
end;
$$;

-- 6. Plateau : plus d'acceptation directe (le transporteur propose son prix) --
create or replace function public.secoto_mission_accept(p_mission_id uuid, p_idempotency_key uuid)
returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_user uuid := secoto_private.assert_authenticated();
  v_existing jsonb;
  v_mission public.missions%rowtype;
  v_account public.accounts%rowtype;
begin
  if not secoto_private.flag('direct_accept') then
    raise exception 'L''acceptation directe n''est pas encore ouverte.';
  end if;
  v_existing := secoto_private.lock_operation('mission_accept', p_idempotency_key);
  if v_existing is not null then return v_existing; end if;

  select * into v_account from public.accounts a where a.id = v_user;
  if not secoto_private.is_verified_transporter(v_user) then
    raise exception 'Votre compte transporteur doit être vérifié par SECOTO.';
  end if;

  -- Verrou de ligne : une seule acceptation peut gagner.
  select * into v_mission from public.missions m where m.id = p_mission_id for update;
  if not found then raise exception 'Mission introuvable.' using errcode = 'P0002'; end if;
  if v_mission.assigned_transporter_id = v_user then
    return secoto_private.finish_operation('mission_accept', p_idempotency_key,
      jsonb_build_object('result', 'already_yours', 'mission_id', p_mission_id));
  end if;
  if v_mission.status::text <> 'published' or v_mission.assigned_transporter_id is not null then
    raise exception 'Mission déjà attribuée.' using errcode = 'P0002';
  end if;
  -- 101 : en plateau, le transporteur propose son prix et sa date.
  if v_mission.type::text = 'plateau' then
    raise exception 'Transport par plateau : proposez votre prix et votre date de disponibilité.';
  end if;
  if not secoto_private.transporter_matches_mission(v_user, p_mission_id) then
    raise exception 'Cette mission ne correspond pas à votre profil de transporteur.';
  end if;

  update public.missions
     set status = 'assigned', progress_status = 'assigned_pending',
         assigned_transporter_id = v_user,
         assigned_transporter_name = coalesce(v_account.company_name, v_account.full_name)
   where id = p_mission_id returning * into v_mission;

  perform secoto_private.notify_event(v_user, 'course_assigned', 'Mission acceptée',
    format('%s → %s · %s', v_mission.from_city, v_mission.to_city, v_mission.vehicle),
    p_mission_id, 'assigned', 'mission-accept:' || p_mission_id::text, p_mission_id);
  perform secoto_private.notify_admins_event('course_assigned', 'Mission acceptée',
    format('%s · %s', v_mission.public_ref, coalesce(v_account.company_name, v_account.full_name)),
    'requests', 'mission-accept-admin:' || p_mission_id::text, p_mission_id);
  perform secoto_private.audit('mission_accepted_direct', 'mission', p_mission_id::text,
    jsonb_build_object('partner_id', v_user, 'carrier_pay', v_mission.carrier_pay));

  return secoto_private.finish_operation('mission_accept', p_idempotency_key,
    jsonb_build_object('result', 'assigned', 'mission_id', p_mission_id));
end;
$$;

-- 7. Proposition attribuée : la mission prend la date proposée ---------------
create or replace function secoto_private.trg_application_date_attribuee()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.status::text = 'accepted' and old.status::text is distinct from 'accepted'
     and new.proposed_date is not null then
    update public.missions set mission_date = new.proposed_date
     where id = new.mission_id and mission_date is distinct from new.proposed_date;
  end if;
  return new;
end;
$$;
drop trigger if exists trg_secoto_application_date_attribuee on public.mission_applications;
create trigger trg_secoto_application_date_attribuee
  after update of status on public.mission_applications
  for each row execute function secoto_private.trg_application_date_attribuee();

-- 8. Droits ---------------------------------------------------------------------
revoke all on function public.secoto_mission_proposer(uuid, numeric, timestamptz, text) from public, anon;
revoke all on function public.secoto_admin_application_update(uuid, numeric, timestamptz) from public, anon;
revoke all on function public.secoto_admin_update_mission(uuid, jsonb) from public, anon;
revoke all on function secoto_private.trg_application_date_attribuee() from public, anon, authenticated;
grant execute on function public.secoto_mission_proposer(uuid, numeric, timestamptz, text) to authenticated;
grant execute on function public.secoto_admin_application_update(uuid, numeric, timestamptz) to authenticated;
grant execute on function public.secoto_admin_update_mission(uuid, jsonb) to authenticated;

notify pgrst, 'reload schema';
