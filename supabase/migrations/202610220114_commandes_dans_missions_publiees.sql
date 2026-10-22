-- ============================================================================
-- SECOTO — MIGRATION 114 : CHAQUE COMMANDE VALIDÉE APPARAÎT AUSSI DANS
--                          « MISSIONS PUBLIÉES »
-- ----------------------------------------------------------------------------
-- Demande de Nawfal du 22/10/2026 : un transporteur dont l'application est
-- ancienne (ou qui ne regarde que « Missions disponibles ») ne voyait pas les
-- commandes à la demande : elles ne vivaient que dans « transport_offers ».
-- Désormais, dès qu'une commande cherche un transporteur, une mission
-- « vitrine » publiée la représente (missions.od_order_id). Elle est visible
-- par tous les transporteurs de la bonne catégorie (même règle que les autres
-- missions publiées) et dans l'admin.
--
-- SÉCURITÉ ARGENT : la vitrine n'est JAMAIS attribuée elle-même. L'accepter
-- (bouton Accepter, proposition au prix affiché, ou attribution admin
-- directe) attribue la COMMANDE, par le même chemin qu'une offre acceptée
-- (od_try_accept puis secoto_reglement_confirmer) : la vraie mission est créée,
-- la vitrine disparaît, le client paie à la livraison. Aucune opération
-- Stripe. Seules les commandes en règlement à la livraison, déjà payées ou
-- au forfait ont une vitrine (aucun débit à déclencher à l'acceptation).
-- La vitrine disparaît aussi si la commande est annulée ou sans transporteur.
-- Rejouable.
-- ============================================================================

alter table public.missions add column if not exists od_order_id uuid references public.transport_orders(id) on delete cascade;
create unique index if not exists missions_od_order_vitrine_uidx on public.missions (od_order_id) where od_order_id is not null;

-- Publie la vitrine d'une commande (rien si elle existe ou si la commande ne s'y prête pas).
create or replace function secoto_private.od_vitrine_publier(p_order_id uuid)
returns uuid language plpgsql security definer set search_path = ''
as $f$
declare
  v_order public.transport_orders%rowtype;
  v_quote public.transport_quotes%rowtype;
  v_payment public.payments%rowtype;
  v_id uuid;
begin
  select * into v_order from public.transport_orders o where o.id = p_order_id;
  if v_order.id is null or v_order.status <> 'searching_partner' or coalesce(v_order.is_test, false) then return null; end if;
  select m.id into v_id from public.missions m where m.od_order_id = p_order_id;
  if v_id is not null then return v_id; end if;
  select * into v_payment from public.payments p where p.id = v_order.payment_id;
  if not (v_order.funding = 'subscription' or v_payment.status = 'paid'
          or (coalesce(v_payment.debit_a_livraison, false) and v_payment.status = 'requires_capture')) then
    return null;
  end if;
  select * into v_quote from public.transport_quotes q where q.id = v_order.quote_id;

  insert into public.missions(public_ref, type, status, from_city, to_city, pickup_address, delivery_address,
    mission_date, vehicle, distance_km, client_name, notes, created_by_role, vehicle_category,
    manual_pricing, manual_carrier_pay, manual_margin, payment_status, payment_method, od_order_id)
  select secoto_private.new_public_ref('MIS'), v_order.mode, 'published',
    v_quote.pickup ->> 'city', v_quote.delivery ->> 'city', v_quote.pickup ->> 'label', v_quote.delivery ->> 'label',
    v_order.pickup_at,
    left(case when jsonb_typeof(v_quote.vehicles) = 'array' and jsonb_array_length(v_quote.vehicles) > 1
              then jsonb_array_length(v_quote.vehicles) || ' véhicules · ' || coalesce(v_quote.vehicle ->> 'model', '')
              else v_quote.vehicle ->> 'model' end, 120),
    (v_quote.route ->> 'distance_km')::numeric,
    (select coalesce(a.company_name, a.full_name) from public.accounts a where a.id = v_order.account_id),
    left(concat_ws(' · ', 'Commande ' || v_order.public_ref || ' (à accepter au prix affiché)',
      'Créneau ' || (v_quote.schedule ->> 'slot'),
      case when (v_quote.schedule ->> 'flexibility_days')::int > 0 then 'Souplesse ' || (v_quote.schedule ->> 'flexibility_days') || ' j' end,
      case when not coalesce((v_quote.vehicle ->> 'rolling')::boolean, true) then 'NON ROULANT' end,
      nullif(v_quote.vehicle ->> 'notes', '')), 2000),
    'admin', coalesce(v_quote.vehicle ->> 'category', 'standard'),
    true, v_order.partner_pay_cents / 100.0, (v_order.client_price_cents - v_order.partner_pay_cents) / 100.0,
    'awaiting_payment', v_order.mode_reglement, v_order.id
  on conflict do nothing
  returning id into v_id;
  return v_id;
end;
$f$;

-- La vitrine suit la commande : publiée tant qu'elle cherche, retirée sinon.
create or replace function secoto_private.trg_od_vitrine()
returns trigger language plpgsql security definer set search_path = ''
as $f$
begin
  if new.status = 'searching_partner' then
    perform secoto_private.od_vitrine_publier(new.id);
  elsif new.status <> 'partner_locked' then
    delete from public.missions m
     where m.od_order_id = new.id and m.status::text = 'published' and m.assigned_transporter_id is null;
  end if;
  return new;
exception when others then
  return new;  -- la vitrine ne bloque jamais une commande
end;
$f$;
drop trigger if exists trg_secoto_od_vitrine on public.transport_orders;
create trigger trg_secoto_od_vitrine
  after update of status on public.transport_orders
  for each row execute function secoto_private.trg_od_vitrine();

-- Une vitrine n'est jamais attribuée directement (sinon la commande et le
-- paiement du client resteraient en suspens).
create or replace function secoto_private.trg_vitrine_non_attribuable()
returns trigger language plpgsql security definer set search_path = ''
as $f$
begin
  if old.od_order_id is not null and new.assigned_transporter_id is not null and old.assigned_transporter_id is null then
    raise exception 'Mission liée à une commande : utilisez « Attribuer » (attribution directe) ou laissez le transporteur l''accepter.';
  end if;
  return new;
end;
$f$;
drop trigger if exists trg_secoto_vitrine_non_attribuable on public.missions;
create trigger trg_secoto_vitrine_non_attribuable
  before update of assigned_transporter_id on public.missions
  for each row execute function secoto_private.trg_vitrine_non_attribuable();

-- Accepter une vitrine = accepter la commande pour ce transporteur.
-- Renvoie null si la mission n'est pas une vitrine.
create or replace function secoto_private.vitrine_accepter(p_mission_id uuid, p_partner uuid)
returns jsonb language plpgsql security definer set search_path = ''
as $f$
declare
  v_order_id uuid;
  v_order public.transport_orders%rowtype;
  v_offer_id uuid;
  v_payment public.payments%rowtype;
  r jsonb;
begin
  select m.od_order_id into v_order_id from public.missions m where m.id = p_mission_id;
  if v_order_id is null then return null; end if;
  select * into v_order from public.transport_orders o where o.id = v_order_id;
  if v_order.status in ('partner_confirmed', 'picked_up', 'delivered') and v_order.assigned_partner_id = p_partner then
    return jsonb_build_object('result', 'assigned', 'mission_id', v_order.mission_id, 'order_id', v_order.id);
  end if;
  if v_order.status <> 'searching_partner' then
    raise exception 'Cette course vient d''être prise par un autre transporteur.' using errcode = 'P0002';
  end if;
  if not secoto_private.od_partner_eligible(p_partner, v_order.id) then
    raise exception 'Cette course ne correspond pas à votre profil (compte validé, documents en règle, bon type de véhicule).' using errcode = '42501';
  end if;
  select x.id into v_offer_id from public.transport_offers x
   where x.order_id = v_order.id and x.partner_id = p_partner and x.round = v_order.dispatch_round
     and x.status = 'sent' and x.expires_at > now()
   limit 1;
  if v_offer_id is null then
    insert into public.transport_offers(order_id, partner_id, round, partner_pay_cents, expires_at)
    values (v_order.id, p_partner, v_order.dispatch_round, v_order.partner_pay_cents,
            greatest(coalesce(v_order.offers_expire_at, now() + interval '1 hour'), now() + interval '10 minutes'))
    on conflict (order_id, partner_id, round) do update set status = 'sent', expires_at = excluded.expires_at
    returning id into v_offer_id;
  end if;

  r := secoto_private.od_try_accept(v_order.id, v_offer_id, p_partner);
  if r ->> 'result' = 'pending_capture' then
    select * into v_payment from public.payments p where p.id = v_order.payment_id;
    if coalesce(v_payment.debit_a_livraison, false) then
      r := public.secoto_reglement_confirmer(v_order.id);
    end if;
  end if;
  if r ->> 'result' = 'confirmed' then
    return jsonb_build_object('result', 'assigned', 'mission_id', r ->> 'mission_id', 'order_id', v_order.id);
  end if;
  if r ->> 'result' = 'pending_capture' then
    return jsonb_build_object('result', 'pending_capture', 'order_id', v_order.id);
  end if;
  raise exception '%', case r ->> 'result'
    when 'already_assigned' then 'Cette course vient d''être prise par un autre transporteur.'
    when 'not_eligible' then 'Cette course ne correspond pas à votre profil.'
    when 'expired' then 'Cette proposition a expiré.'
    else 'Cette course n''est plus disponible.' end;
end;
$f$;
revoke all on function secoto_private.vitrine_accepter(uuid, uuid) from public, anon, authenticated;

-- Bouton « Accepter » (toutes catégories pour une vitrine, prix fixe).
select secoto_private.mig074_patch('public.secoto_mission_accept(uuid,uuid)'::regprocedure,
  '  if not secoto_private.flag(''direct_accept'') then',
  '  -- 114 : mission liée à une commande -> la commande est attribuée.
  if exists (select 1 from public.missions vm where vm.id = p_mission_id and vm.od_order_id is not null) then
    return secoto_private.vitrine_accepter(p_mission_id, v_user);
  end if;
  if not secoto_private.flag(''direct_accept'') then');

-- Proposition au prix affiché (ou moins) sur une vitrine = acceptation.
select secoto_private.mig074_patch('public.secoto_mission_proposer(uuid,numeric,timestamp with time zone,text)'::regprocedure,
  '  if p_date is null then',
  '  -- 114 : course à prix fixe (commande) : proposer le prix affiché = l''accepter.
  if v_mission.od_order_id is not null then
    if v_mission.type::text = ''plateau'' and p_price is not null and p_price > coalesce(v_mission.carrier_pay, 0) + 0.5 then
      raise exception ''Course à prix fixe : % € pour vous. Proposez ce prix pour la prendre tout de suite.'',
        to_char(coalesce(v_mission.carrier_pay, 0), ''FM999G990D00'');
    end if;
    return secoto_private.vitrine_accepter(p_mission_id, v_user);
  end if;
  if p_date is null then');

-- Attribution directe par l'admin d'une vitrine = attribution de la commande.
select secoto_private.mig074_patch('public.secoto_admin_assign_mission_direct(uuid,uuid,boolean,numeric,numeric,uuid)'::regprocedure,
  '  if not found then raise exception ''Mission introuvable.''; end if;',
  '  if not found then raise exception ''Mission introuvable.''; end if;
  -- 114 : mission liée à une commande -> la commande est attribuée à ce transporteur.
  if v_mission.od_order_id is not null then
    return secoto_private.finish_operation(''admin_assign_direct'', p_idempotency_key,
      secoto_private.vitrine_accepter(p_mission_id, p_transporter_id));
  end if;');

-- Les applications savent qu'une mission est une commande à prix fixe.
create or replace view public.secoto_public_missions_v2 with (security_barrier = true) as
 select id, public_ref, type, status, progress_status, from_city, to_city, vehicle, distance_km, created_at,
        vehicle_category, capacity_units, window_start, window_end, mission_date,
        coalesce(vehicle_rolling, true) as vehicle_rolling, carrier_pay, urgent,
        (od_order_id is not null) as commande
   from public.missions m
  where public.secoto_current_transporter_matches_mission(id)
    and not exists (select 1 from public.mission_declines d where d.mission_id = m.id and d.partner_id = auth.uid());

-- Commandes qui cherchent déjà un transporteur : vitrine tout de suite.
select secoto_private.od_vitrine_publier(o.id) from public.transport_orders o where o.status = 'searching_partner';

notify pgrst, 'reload schema';
