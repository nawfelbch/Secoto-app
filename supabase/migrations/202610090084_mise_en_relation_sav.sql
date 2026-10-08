-- ============================================================================
-- SECOTO 084 — Mise en relation directe, SAV, courses en cours verrouillées
-- ----------------------------------------------------------------------------
-- Derrière l'interrupteur « mise_en_relation_v2 » (éteint par défaut) :
--
--  1. COURSES VERROUILLÉES. Dès qu'un transporteur a accepté une course, SECOTO
--     ne peut plus la modifier depuis l'application (prix, rémunération, date,
--     adresses, transporteur, étapes). Seule reste l'annulation avec
--     remboursement intégral du client.
--  2. MISE EN RELATION. Après l'acceptation, le client voit les coordonnées de
--     son transporteur (raison sociale, SIREN, téléphone) jusqu'à 48 h après
--     la livraison.
--  3. SAV. Une table de demandes SAV : le client écrit, SECOTO rappelle. Le
--     numéro de SECOTO n'est plus affiché aux clients ayant déjà réservé.
--
-- Migration additive et rejouable. Interrupteur éteint : rien ne change.
-- ============================================================================

-- 1. INTERRUPTEURS ------------------------------------------------------------
alter table public.secoto_feature_flags drop constraint if exists secoto_feature_flags_key_check;
alter table public.secoto_feature_flags add constraint secoto_feature_flags_key_check
  check (key in ('auto_pricing', 'od_payments', 'subscriptions', 'dispatch_notifications', 'live_tracking',
                 'direct_accept', 'connect_payouts', 'plateau_paiement_direct',
                 'conditions_v2', 'commission_client',
                 'mise_en_relation_v2', 'bareme_transporteurs'));
insert into public.secoto_feature_flags(key) values ('mise_en_relation_v2') on conflict (key) do nothing;
insert into public.secoto_feature_flags(key) values ('bareme_transporteurs') on conflict (key) do nothing;

-- 2. COURSES VERROUILLÉES -------------------------------------------------------
create or replace function secoto_private.od_course_verrouillee(p_status text)
returns boolean language sql stable security definer set search_path = '' as $$
  select secoto_private.flag('mise_en_relation_v2')
     and p_status in ('partner_locked', 'partner_confirmed', 'picked_up', 'delivered');
$$;

create or replace function secoto_private.mission_course_verrouillee(m public.missions)
returns boolean language sql stable security definer set search_path = '' as $$
  -- Plateau uniquement (le convoyage reste piloté par SECOTO, prestataire), et
  -- seulement les courses réservées et acceptées dans l'application : les
  -- missions saisies par SECOTO (téléphone) restent pilotables.
  select secoto_private.flag('mise_en_relation_v2')
     and m.type = 'plateau'
     and m.assigned_transporter_id is not null
     and m.status in ('assigned', 'completed')
     and (m.groupage_order_id is not null
          or exists (select 1 from public.transport_orders o where o.mission_id = m.id));
$$;

-- Missions verrouillées (pour masquer les commandes inutiles côté admin).
create or replace function public.secoto_admin_locked_mission_ids()
returns uuid[] language plpgsql stable security definer set search_path = '' as $$
begin
  perform secoto_private.assert_admin();
  if not secoto_private.flag('mise_en_relation_v2') then return '{}'::uuid[]; end if;
  return coalesce((select array_agg(m.id) from public.missions m
                    where m.type = 'plateau' and m.status in ('assigned', 'completed')
                      and secoto_private.mission_course_verrouillee(m)), '{}'::uuid[]);
end;
$$;
revoke all on function public.secoto_admin_locked_mission_ids() from public, anon;
grant execute on function public.secoto_admin_locked_mission_ids() to authenticated;

revoke all on function secoto_private.od_course_verrouillee(text) from public, anon, authenticated;
revoke all on function secoto_private.mission_course_verrouillee(public.missions) from public, anon, authenticated;

-- Modifier les conditions (prix, rémunération, date, adresses).
select secoto_private.mig074_patch(
  'public.secoto_admin_od_update_conditions(uuid, jsonb, text)'::regprocedure,
  '  if not found then raise exception ''Commande introuvable.'' using errcode = ''P0002''; end if;',
  '  if not found then raise exception ''Commande introuvable.'' using errcode = ''P0002''; end if;
  -- 084 : une course acceptée appartient au client et à son transporteur.
  if secoto_private.od_course_verrouillee(v_order.status) then
    raise exception ''Course acceptée par le transporteur : elle ne peut plus être modifiée par SECOTO. En cas de problème, annulez-la avec remboursement intégral.'';
  end if;');

-- Remplacer le transporteur.
select secoto_private.mig074_patch(
  'public.secoto_admin_od_replace_partner(uuid, text)'::regprocedure,
  '  if v_order.status <> ''partner_confirmed'' then raise exception ''Remplacement possible uniquement avant la récupération du véhicule.''; end if;',
  '  if secoto_private.flag(''mise_en_relation_v2'') then
    raise exception ''Le transporteur a accepté la course : SECOTO ne peut plus le remplacer. En cas de problème, annulez la course avec remboursement intégral.'';
  end if;
  if v_order.status <> ''partner_confirmed'' then raise exception ''Remplacement possible uniquement avant la récupération du véhicule.''; end if;');

-- Attribuer une course à la place du transporteur.
select secoto_private.mig074_patch(
  'public.secoto_admin_od_lock_for_partner(uuid, uuid)'::regprocedure,
  '  if v_order.status <> ''searching_partner'' then raise exception ''Commande non disponible (%).'', v_order.status; end if;',
  '  if v_order.status <> ''searching_partner'' then raise exception ''Commande non disponible (%).'', v_order.status; end if;
  if secoto_private.flag(''mise_en_relation_v2'') then
    raise exception ''Attribution manuelle désactivée : ce sont les transporteurs qui acceptent les courses.'';
  end if;');

-- Annulation par SECOTO d'une course acceptée : uniquement avec remboursement.
select secoto_private.mig074_patch(
  'public.secoto_admin_od_cancel_order(uuid, text, boolean)'::regprocedure,
  '  if v_order.status in (''delivered'', ''cancelled'') then raise exception ''Commande déjà close.''; end if;',
  '  if v_order.status in (''delivered'', ''cancelled'') then raise exception ''Commande déjà close.''; end if;
  if secoto_private.od_course_verrouillee(v_order.status) and not coalesce(p_refund, false) then
    raise exception ''Une course acceptée ne peut être annulée par SECOTO qu''''avec remboursement intégral du client.'';
  end if;');

-- Missions (plateau) : tarif, attribution, étapes, réouverture d'étape.
select secoto_private.mig074_patch(
  'public.secoto_admin_set_mission_pricing(uuid, boolean, numeric, numeric, uuid)'::regprocedure,
  '  if not found then raise exception ''Mission introuvable.''; end if;',
  '  if not found then raise exception ''Mission introuvable.''; end if;
  if secoto_private.mission_course_verrouillee(v_mission) then
    raise exception ''Course acceptée par le transporteur : son tarif ne peut plus être modifié par SECOTO.'';
  end if;');

select secoto_private.mig074_patch(
  'public.secoto_admin_assign_mission_direct(uuid, uuid, boolean, numeric, numeric, uuid)'::regprocedure,
  '  if not found then raise exception ''Mission introuvable.''; end if;',
  '  if not found then raise exception ''Mission introuvable.''; end if;
  if secoto_private.mission_course_verrouillee(v_mission) then
    raise exception ''Course acceptée par le transporteur : elle ne peut plus être réattribuée par SECOTO.'';
  end if;');

select secoto_private.mig074_patch(
  'public.secoto_admin_set_mission_stage(uuid, text, text, uuid)'::regprocedure,
  '  if not found then raise exception ''Mission introuvable.''; end if;',
  '  if not found then raise exception ''Mission introuvable.''; end if;
  if secoto_private.mission_course_verrouillee(v_mission) then
    raise exception ''Course acceptée par le transporteur : ses étapes sont validées par le transporteur dans l''''application.'';
  end if;');

select secoto_private.mig074_patch(
  'public.secoto_admin_reopen_field_step(uuid, text, text, uuid)'::regprocedure,
  '  if not found then raise exception ''Mission introuvable.''; end if;',
  '  if not found then raise exception ''Mission introuvable.''; end if;
  if secoto_private.mission_course_verrouillee(v_mission) then
    raise exception ''Course acceptée par le transporteur : ses étapes sont validées par le transporteur dans l''''application.'';
  end if;');

-- Lien de paiement d'une course acceptée : montant non modifiable.
select secoto_private.mig074_patch(
  'public.secoto_admin_devis_link(uuid, integer, integer)'::regprocedure,
  '  v_link := secoto_private.devis_link(p_mission, p_amount_cents, p_validity_days, auth.uid());',
  '  if p_amount_cents is not null and exists (select 1 from public.missions m where m.id = p_mission and secoto_private.mission_course_verrouillee(m)) then
    raise exception ''Course acceptée par le transporteur : son prix ne peut plus être modifié par SECOTO.'';
  end if;
  v_link := secoto_private.devis_link(p_mission, p_amount_cents, p_validity_days, auth.uid());');

-- 3. MISE EN RELATION -----------------------------------------------------------
create or replace function secoto_private.carrier_contact_json(p_partner uuid)
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'name', coalesce(nullif(a.company_name, ''), a.full_name),
    'legal_name', nullif(a.billing_legal_name, ''),
    'siren', nullif(a.billing_siren, ''),
    'phone', nullif(a.phone, ''))
  from public.accounts a where a.id = p_partner;
$$;
revoke all on function secoto_private.carrier_contact_json(uuid) from public, anon, authenticated;

-- Transport à la demande : coordonnées du transporteur, de l'acceptation
-- jusqu'à 48 h après la livraison.
select secoto_private.mig074_patch(
  'secoto_private.order_client_json(public.transport_orders)'::regprocedure,
  '    ''partner_name'', case when o.assigned_partner_id is not null then (select coalesce(a.company_name, a.full_name) from public.accounts a where a.id = o.assigned_partner_id) end,',
  '    ''partner_name'', case when o.assigned_partner_id is not null then (select coalesce(a.company_name, a.full_name) from public.accounts a where a.id = o.assigned_partner_id) end,
    ''partner_contact'', case when secoto_private.flag(''mise_en_relation_v2'') and o.assigned_partner_id is not null
        and (o.status in (''partner_confirmed'', ''picked_up'') or (o.status = ''delivered'' and coalesce(
              (select max(e.created_at) from public.mission_tracking_events e where e.mission_id = o.mission_id and e.event_type::text = ''delivery_inspection''),
              o.updated_at) > now() - interval ''48 hours''))
      then secoto_private.carrier_contact_json(o.assigned_partner_id) end,');

-- Missions (plateau) vues par le client : même règle. La fonction vérifie
-- elle-même que la mission appartient bien à la personne connectée.
create or replace function secoto_private.mission_transporter_contact(p_mission_id uuid)
returns jsonb language sql stable security definer set search_path = '' as $$
  select case when secoto_private.flag('mise_en_relation_v2') and m.type = 'plateau'
          and m.assigned_transporter_id is not null
          and m.client_account_id = auth.uid()
          and (m.status = 'assigned' or (m.status = 'completed' and coalesce(
                (select max(e.created_at) from public.mission_tracking_events e where e.mission_id = m.id and e.event_type::text = 'delivery_inspection'),
                m.updated_at) > now() - interval '48 hours'))
      then secoto_private.carrier_contact_json(m.assigned_transporter_id) end
  from public.missions m where m.id = p_mission_id;
$$;
revoke all on function secoto_private.mission_transporter_contact(uuid) from public, anon;
grant execute on function secoto_private.mission_transporter_contact(uuid) to authenticated;

create or replace view public.secoto_missions_client_v2 with (security_barrier = true) as
 SELECT id, public_ref, type, status, progress_status, from_city, to_city, pickup_address, delivery_address,
    mission_date, vehicle, plate, distance_km, client_price, client_name, client_contact, client_phone,
    price_mode, proposed_price, payment_method, notes, created_by_role, client_account_id,
    assigned_transporter_id, assigned_transporter_name, source_request_id, created_at, vehicle_category,
    commission_amount, transport_amount, client_total_due, payment_status, commission_paid_at,
    cancelled_at, cancellation_reason, cancellation_fee,
    secoto_private.mission_transporter_contact(m.id) as transporter_contact
   FROM public.missions m
  WHERE m.client_account_id = auth.uid();

-- 4. SAV -------------------------------------------------------------------------
create table if not exists public.sav_requests (
  id uuid primary key default gen_random_uuid(),
  public_ref text not null unique default ('SAV-' || to_char(now() at time zone 'Europe/Paris', 'YYMMDD') || '-' || upper(substr(md5(gen_random_uuid()::text), 1, 5))),
  account_id uuid not null references public.accounts(id) on delete cascade,
  order_id uuid references public.transport_orders(id) on delete set null,
  mission_id uuid references public.missions(id) on delete set null,
  motif text not null check (motif in ('retard', 'dommage', 'paiement', 'annulation', 'transporteur_injoignable', 'autre')),
  message text not null check (char_length(message) between 5 and 4000),
  callback_phone text check (callback_phone is null or char_length(callback_phone) <= 30),
  status text not null default 'ouverte' check (status in ('ouverte', 'en_cours', 'resolue')),
  admin_note text check (admin_note is null or char_length(admin_note) <= 2000),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  resolved_at timestamptz
);
create index if not exists sav_requests_account_idx on public.sav_requests(account_id, created_at desc);
create index if not exists sav_requests_status_idx on public.sav_requests(status, created_at desc);

alter table public.sav_requests enable row level security;
revoke all on public.sav_requests from public, anon, authenticated;
grant select on public.sav_requests to authenticated;
drop policy if exists sav_requests_read on public.sav_requests;
create policy sav_requests_read on public.sav_requests for select to authenticated
  using (account_id = auth.uid() or secoto_private.current_is_admin());

-- Le client a-t-il déjà validé une course ? (le contact devient alors le SAV)
create or replace function public.secoto_client_has_course()
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (
      select 1 from public.transport_orders o
       where o.account_id = auth.uid()
         and (o.status in ('searching_partner', 'partner_locked', 'partner_confirmed', 'picked_up', 'delivered', 'no_partner')
              or o.confirmed_at is not null))
      or exists (select 1 from public.missions m where m.client_account_id = auth.uid());
$$;

-- Courses du client proposées dans le formulaire SAV.
create or replace function public.secoto_sav_courses()
returns jsonb language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(c order by c ->> 'date' desc), '[]'::jsonb) from (
    select jsonb_build_object('kind', 'order', 'id', o.id, 'ref', o.public_ref,
             'label', format('%s · %s → %s', o.public_ref, q.pickup ->> 'city', q.delivery ->> 'city'),
             'date', o.created_at, 'status', o.status) as c
      from public.transport_orders o join public.transport_quotes q on q.id = o.quote_id
     where o.account_id = auth.uid() and o.status <> 'awaiting_payment'
    union all
    select jsonb_build_object('kind', 'mission', 'id', m.id, 'ref', m.public_ref,
             'label', format('%s · %s → %s', m.public_ref, m.from_city, m.to_city),
             'date', m.created_at, 'status', m.status)
      from public.missions m
     where m.client_account_id = auth.uid()
       and not exists (select 1 from public.transport_orders o where o.mission_id = m.id)
  ) s;
$$;

create or replace function public.secoto_sav_create(
  p_order_id uuid, p_mission_id uuid, p_motif text, p_message text, p_callback_phone text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  v_row public.sav_requests%rowtype;
  v_ref text;
  v_recent integer;
begin
  if v_uid is null then raise exception 'Session expirée. Reconnectez-vous.'; end if;
  if p_order_id is not null and not exists (select 1 from public.transport_orders o where o.id = p_order_id and o.account_id = v_uid) then
    raise exception 'Commande introuvable.';
  end if;
  if p_mission_id is not null and not exists (select 1 from public.missions m where m.id = p_mission_id and m.client_account_id = v_uid) then
    raise exception 'Course introuvable.';
  end if;
  if char_length(btrim(coalesce(p_message, ''))) < 5 then
    raise exception 'Décrivez votre demande en quelques mots.';
  end if;
  -- Garde-fou contre les envois répétés.
  select count(*) into v_recent from public.sav_requests s where s.account_id = v_uid and s.created_at > now() - interval '1 hour';
  if v_recent >= 5 then raise exception 'Vous avez déjà envoyé plusieurs demandes : le SAV vous recontacte rapidement.'; end if;

  insert into public.sav_requests(account_id, order_id, mission_id, motif, message, callback_phone)
  values (v_uid, p_order_id, p_mission_id, coalesce(nullif(p_motif, ''), 'autre'), left(btrim(p_message), 4000),
          nullif(left(btrim(coalesce(p_callback_phone, '')), 30), ''))
  returning * into v_row;

  select coalesce(o.public_ref, m.public_ref) into v_ref
    from (select 1) x
    left join public.transport_orders o on o.id = v_row.order_id
    left join public.missions m on m.id = v_row.mission_id;

  perform secoto_private.notify_admins_event('new_request', 'Demande SAV',
    format('%s%s · %s', v_row.public_ref, case when v_ref is not null then ' · ' || v_ref else '' end, left(v_row.message, 160)),
    'requests', 'sav:' || v_row.id::text, v_row.id);
  perform secoto_private.audit('sav_created', 'sav_request', v_row.id::text, jsonb_build_object('motif', v_row.motif));

  return jsonb_build_object('id', v_row.id, 'public_ref', v_row.public_ref, 'status', v_row.status, 'created_at', v_row.created_at);
end;
$$;

create or replace function public.secoto_sav_my_requests()
returns jsonb language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', s.id, 'public_ref', s.public_ref, 'motif', s.motif, 'message', s.message, 'status', s.status,
    'created_at', s.created_at, 'updated_at', s.updated_at, 'resolved_at', s.resolved_at,
    'course_ref', coalesce(o.public_ref, m.public_ref)) order by s.created_at desc), '[]'::jsonb)
  from public.sav_requests s
  left join public.transport_orders o on o.id = s.order_id
  left join public.missions m on m.id = s.mission_id
  where s.account_id = auth.uid();
$$;

create or replace function public.secoto_admin_sav_list(p_status text default null)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  perform secoto_private.assert_admin();
  return (select coalesce(jsonb_agg(jsonb_build_object(
    'id', s.id, 'public_ref', s.public_ref, 'motif', s.motif, 'message', s.message, 'status', s.status,
    'callback_phone', coalesce(s.callback_phone, a.phone), 'client_name', coalesce(nullif(a.company_name, ''), a.full_name),
    'client_email', a.email, 'admin_note', s.admin_note, 'created_at', s.created_at, 'resolved_at', s.resolved_at,
    'course_ref', coalesce(o.public_ref, m.public_ref), 'order_id', s.order_id, 'mission_id', s.mission_id)
    order by (s.status = 'resolue'), s.created_at desc), '[]'::jsonb)
  from public.sav_requests s
  join public.accounts a on a.id = s.account_id
  left join public.transport_orders o on o.id = s.order_id
  left join public.missions m on m.id = s.mission_id
  where p_status is null or s.status = p_status);
end;
$$;

create or replace function public.secoto_admin_sav_update(p_id uuid, p_status text, p_note text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_row public.sav_requests%rowtype;
begin
  perform secoto_private.assert_admin();
  if p_status not in ('ouverte', 'en_cours', 'resolue') then raise exception 'Statut inconnu.'; end if;
  update public.sav_requests
     set status = p_status,
         admin_note = coalesce(nullif(left(btrim(coalesce(p_note, '')), 2000), ''), admin_note),
         resolved_at = case when p_status = 'resolue' then coalesce(resolved_at, now()) else null end,
         updated_at = now()
   where id = p_id
  returning * into v_row;
  if not found then raise exception 'Demande introuvable.'; end if;
  if p_status = 'resolue' then
    perform secoto_private.notify_event(v_row.account_id, 'order_update', 'SAV SECOTO',
      format('Votre demande %s est traitée. Merci de votre confiance.', v_row.public_ref),
      null, 'contact', 'sav-resolue:' || v_row.id::text, v_row.id);
  end if;
  perform secoto_private.audit('sav_updated', 'sav_request', v_row.id::text, jsonb_build_object('status', p_status));
  return jsonb_build_object('id', v_row.id, 'status', v_row.status);
end;
$$;

revoke all on function public.secoto_client_has_course() from public, anon;
revoke all on function public.secoto_sav_courses() from public, anon;
revoke all on function public.secoto_sav_create(uuid, uuid, text, text, text) from public, anon;
revoke all on function public.secoto_sav_my_requests() from public, anon;
revoke all on function public.secoto_admin_sav_list(text) from public, anon;
revoke all on function public.secoto_admin_sav_update(uuid, text, text) from public, anon;
grant execute on function public.secoto_client_has_course() to authenticated;
grant execute on function public.secoto_sav_courses() to authenticated;
grant execute on function public.secoto_sav_create(uuid, uuid, text, text, text) to authenticated;
grant execute on function public.secoto_sav_my_requests() to authenticated;
grant execute on function public.secoto_admin_sav_list(text) to authenticated;
grant execute on function public.secoto_admin_sav_update(uuid, text, text) to authenticated;

-- 5. TEXTES : le client n'est plus renvoyé vers SECOTO --------------------------
select secoto_private.mig074_patch(
  'public.secoto_od_cancel_order(uuid, uuid)'::regprocedure,
  'raise exception ''Le véhicule est déjà pris en charge : contactez SECOTO.'';',
  'raise exception ''%'', case when secoto_private.flag(''mise_en_relation_v2'')
      then ''Le véhicule est déjà pris en charge : l''''annulation n''''est plus possible. Contactez votre transporteur ou écrivez au SAV SECOTO.''
      else ''Le véhicule est déjà pris en charge : contactez SECOTO.'' end;');

-- E-mail de demande d'avis : signé sans numéro de téléphone.
select secoto_private.mig074_patch(
  'public.secoto_review_requests_tick(integer)'::regprocedure,
  '|| ''L''''équipe SECOTO'' || E''\n'' || ''07 83 27 82 31'';',
  '|| ''L''''équipe SECOTO'';');

notify pgrst, 'reload schema';
