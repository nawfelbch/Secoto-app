-- ============================================================================
-- SECOTO — MIGRATION 035 : PARCOURS DE COMMANDE DÉFINITIF
-- ----------------------------------------------------------------------------
-- Décisions Nawfal Bouchaib (SECOTO) du 18/09/2026 :
--
--  1. Le client commande comme une course VTC : adresses, véhicule, prix
--     affiché immédiatement, paiement (Apple Pay, Google Pay, carte).
--  2. Le paiement est ENCAISSÉ tout de suite et gardé en réserve 48 heures,
--     le temps qu'un transporteur accepte. C'est écrit à l'écran.
--  3. La demande part à TOUS les transporteurs vérifiés compatibles, sans
--     qu'ils aient à régler quoi que ce soit au préalable. Un seul tour,
--     48 heures. Ils voient : modèle, ville de départ, ville d'arrivée, état
--     roulant ou non roulant, et leur rémunération. Accepter ou refuser.
--  4. Si personne n'accepte dans les 48 heures : remboursement intégral,
--     demandé automatiquement et exécuté sous 24 heures.
--  5. Plus de candidature avec prix proposé : partout, le transporteur voit sa
--     rémunération et accepte ou refuse.
--  6. Annulation client : remboursement intégral jusqu'à 24 heures avant la
--     prise en charge, même si un transporteur a confirmé ; au-delà, 50 % sont
--     retenus.
--  7. Le transporteur est réglé dans les 48 heures suivant la livraison.
--  8. L'administrateur peut modifier toutes les conditions d'un transport à
--     tout moment, même en cours de mission.
--  9. Facture client automatique dès l'encaissement, avec récapitulatif.
-- 10. TVA non applicable, article 293 B du CGI (franchise en base).
--
-- Additive et rejouable. Aucune donnée supprimée.
-- ============================================================================

begin;

do $guard$
begin
  if to_regprocedure('public.secoto_od_book_quote(uuid,boolean,uuid)') is null then
    raise exception 'Migration 030 requise avant la 035.';
  end if;
  if to_regclass('public.pricing_grids') is null
     or not exists (select 1 from public.pricing_grids g where g.status = 'active' and g.params ->> 'pricing_method' = 'per_class') then
    raise exception 'Migration 034 requise avant la 035.';
  end if;
end
$guard$;

-- ----------------------------------------------------------------------------
-- 1. INTERRUPTEURS ET POLITIQUE OPÉRATIONNELLE
-- ----------------------------------------------------------------------------
alter table public.secoto_feature_flags drop constraint if exists secoto_feature_flags_key_check;
alter table public.secoto_feature_flags add constraint secoto_feature_flags_key_check
  check (key in ('auto_pricing', 'od_payments', 'subscriptions',
                 'dispatch_notifications', 'live_tracking', 'direct_accept'));
insert into public.secoto_feature_flags(key) values ('direct_accept') on conflict (key) do nothing;

-- Une seule source de vérité pour les délais. Modifiable sans redéploiement.
update public.app_settings
   set value = value || jsonb_build_object(
     'offer_ttl_minutes', 2880,              -- 48 h laissées aux transporteurs
     'max_rounds', 1,                        -- un seul tour, pas de relance
     'authorization_window_hours', 0,        -- encaissement immédiat systématique
     'no_partner_refund_hours', 24,          -- remboursement exécuté sous 24 h
     'payout_delay_hours', 48,               -- transporteur réglé sous 48 h
     'free_cancel_hours_before_pickup', 24,  -- annulation gratuite jusqu'à J-24 h
     'late_cancel_retained_pct', 50,         -- au-delà : 50 % retenus
     'sous_traitance_totale_since', to_char(now(), 'YYYY-MM-DD"T"HH24:MI:SSOF'))
 where key = 'dispatch_policy';

insert into public.app_settings(key, value) values ('legal_mentions', jsonb_build_object(
  'tva', 'TVA non applicable, article 293 B du CGI.',
  'entity', 'SECOTO'
)) on conflict (key) do update set value = public.app_settings.value || excluded.value;

create or replace function secoto_private.policy_text(p_key text, p_default text)
returns text language sql stable security definer set search_path = ''
as $f$
  select coalesce((select s.value ->> p_key from public.app_settings s where s.key = 'legal_mentions'), p_default);
$f$;

-- ----------------------------------------------------------------------------
-- 2. COLONNES AJOUTÉES (aucune suppression)
-- ----------------------------------------------------------------------------
alter table public.payments add column if not exists refund_requested_cents integer;
comment on column public.payments.refund_requested_cents is
  'Montant à rembourser demandé (remboursement partiel : annulation tardive). NULL = remboursement du solde intégral.';

alter table public.payments drop constraint if exists payments_purpose_check;
alter table public.payments add constraint payments_purpose_check
  check (purpose in ('commission_plateau', 'convoyage_livraison', 'od_convoyage',
                     'od_plateau_commission', 'od_plateau', 'subscription_extension'));

alter table public.missions add column if not exists vehicle_rolling boolean;
comment on column public.missions.vehicle_rolling is
  'false = véhicule non roulant (treuil nécessaire). NULL = non renseigné, traité comme roulant.';

alter table public.partner_payouts add column if not exists due_at timestamptz;
alter table public.partner_payouts add column if not exists mode text;
comment on column public.partner_payouts.due_at is 'Échéance de règlement du transporteur : livraison + 48 h.';

alter table public.transport_orders add column if not exists invoice_number text;
alter table public.transport_orders add column if not exists invoiced_at timestamptz;
alter table public.transport_orders add column if not exists refund_due_at timestamptz;
alter table public.transport_orders add column if not exists conditions_updated_at timestamptz;
comment on column public.transport_orders.refund_due_at is
  'Échéance affichée au client quand aucun transporteur n''a accepté : constat + 24 h.';

-- Refus d'une mission publiée (hors commande) : le transporteur ne la revoit plus.
create table if not exists public.mission_declines (
  mission_id uuid not null references public.missions(id) on delete cascade,
  partner_id uuid not null references public.accounts(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (mission_id, partner_id)
);
alter table public.mission_declines enable row level security;
revoke all on table public.mission_declines from public, anon, authenticated;

-- ----------------------------------------------------------------------------
-- 3. NUMÉROTATION DES FACTURES CÔTÉ SERVEUR (sans passer par un administrateur)
-- ----------------------------------------------------------------------------
create or replace function secoto_private.next_doc_number(p_prefix text)
returns text language plpgsql volatile security definer set search_path = ''
as $f$
declare v_period text := to_char(now(), 'YYYYMM'); v_num integer;
begin
  insert into public.doc_counters(prefix, period, last_num) values (p_prefix, v_period, 1)
  on conflict (prefix, period) do update set last_num = public.doc_counters.last_num + 1
  returning last_num into v_num;
  return p_prefix || '-' || v_period || '-' || lpad(v_num::text, 4, '0');
end;
$f$;

-- ----------------------------------------------------------------------------
-- 4. DIFFUSION : TOUS LES TRANSPORTEURS VÉRIFIÉS COMPATIBLES
-- ----------------------------------------------------------------------------
-- Les préférences deviennent un filtre facultatif : un transporteur qui n'a
-- rien réglé reçoit tout ce qui le concerne. Il refuse s'il ne peut pas.
create or replace function secoto_private.od_partner_eligible(p_partner uuid, p_order uuid)
returns boolean language sql stable security definer set search_path = ''
as $f$
  select exists (
    select 1
    from public.transport_orders o
    join public.transport_quotes q on q.id = o.quote_id
    join public.accounts a on a.id = p_partner
    left join public.partner_dispatch_preferences pr on pr.account_id = a.id
    where o.id = p_order
      and a.role::text = 'transporter' and a.status::text = 'active'
      and coalesce(a.is_verified, false) and a.deleted_at is null
      and coalesce(pr.available, true)
      and secoto_private.partner_documents_valid(a.id)
      and (
        (o.mode = 'convoyage' and a.transporter_type::text = 'convoyeur')
        or (o.mode = 'plateau' and a.transporter_type::text in ('vl', 'pl') and (
              (coalesce(q.vehicle ->> 'category', 'standard') = 'standard' and coalesce(a.receives_standard_plateau, true))
           or (q.vehicle ->> 'category' = 'luxury' and a.luxury_closed_transport_status = 'approved')))
      )
      -- Filtres facultatifs : ils ne s'appliquent que si le transporteur les a réglés.
      and (pr.account_id is null or cardinality(pr.zones) = 0 or secoto_private.department_of(q.pickup ->> 'postcode') = any(pr.zones))
      and (pr.account_id is null or cardinality(pr.vehicle_classes) = 0 or (q.vehicle ->> 'class') = any(pr.vehicle_classes))
      and (pr.account_id is null or cardinality(pr.weekdays) = 0 or extract(isodow from (o.pickup_at at time zone 'Europe/Paris'))::smallint = any(pr.weekdays))
      and not exists (select 1 from public.transport_offers x where x.order_id = o.id and x.partner_id = a.id and x.status = 'declined')
  );
$f$;

-- Diffusion : un tour, 48 heures, jamais au-delà de la prise en charge.
create or replace function secoto_private.od_broadcast(p_order_id uuid)
returns integer language plpgsql volatile security definer set search_path = ''
as $f$
declare
  v_order public.transport_orders%rowtype;
  v_quote public.transport_quotes%rowtype;
  v_count integer := 0;
  v_offer_id uuid;
  r record;
  v_ttl numeric := secoto_private.policy_num('offer_ttl_minutes', 2880);
  v_expire timestamptz;
  v_state text;
begin
  select * into v_order from public.transport_orders o where o.id = p_order_id for update;
  if v_order.status <> 'searching_partner' then return 0; end if;
  select * into v_quote from public.transport_quotes q where q.id = v_order.quote_id;

  update public.transport_offers set status = 'expired', responded_at = coalesce(responded_at, now())
   where order_id = p_order_id and status = 'sent';

  v_expire := least(now() + make_interval(mins => v_ttl::int), v_order.pickup_at);

  update public.transport_orders
     set dispatch_round = dispatch_round + 1,
         offers_expire_at = v_expire,
         updated_at = now()
   where id = p_order_id returning * into v_order;

  if not secoto_private.flag('dispatch_notifications') then
    perform secoto_private.notify_admins_event('new_request', 'Commande à attribuer',
      format('%s · %s → %s', v_order.public_ref, v_quote.pickup ->> 'city', v_quote.delivery ->> 'city'),
      'requests', 'order-dispatch-manual:' || v_order.id::text || ':' || v_order.dispatch_round, v_order.id);
    return 0;
  end if;

  v_state := case when coalesce((v_quote.vehicle ->> 'rolling')::boolean, true) then 'roulant' else 'NON ROULANT' end;

  for r in select a.id from public.accounts a where secoto_private.od_partner_eligible(a.id, p_order_id) loop
    insert into public.transport_offers(order_id, partner_id, round, partner_pay_cents, expires_at)
    values (p_order_id, r.id, v_order.dispatch_round, v_order.partner_pay_cents, v_order.offers_expire_at)
    on conflict (order_id, partner_id, round) do nothing
    returning id into v_offer_id;
    if v_offer_id is not null then
      v_count := v_count + 1;
      -- Modèle, villes, état du véhicule, rémunération : tout est dans le corps.
      perform secoto_private.notify_event(r.id, 'mission_offer', 'Mission disponible',
        format('%s · %s → %s · %s · %s € pour vous',
          coalesce(nullif(v_quote.vehicle ->> 'model', ''), 'Véhicule'),
          v_quote.pickup ->> 'city', v_quote.delivery ->> 'city', v_state,
          to_char(v_order.partner_pay_cents / 100.0, 'FM999990D00')),
        null, 'offre', 'offer:' || v_offer_id::text, v_offer_id);
    end if;
  end loop;

  perform secoto_private.audit('order_broadcast', 'transport_order', p_order_id::text,
    jsonb_build_object('round', v_order.dispatch_round, 'offers', v_count, 'expires_at', v_order.offers_expire_at));
  return v_count;
end;
$f$;

-- ----------------------------------------------------------------------------
-- 5. RÉSERVATION : ENCAISSEMENT IMMÉDIAT, RÉSERVE DE 48 HEURES
-- ----------------------------------------------------------------------------
create or replace function public.secoto_od_book_quote(p_quote_id uuid, p_use_subscription boolean, p_idempotency_key uuid)
returns jsonb language plpgsql volatile security definer set search_path = ''
as $f$
declare
  v_user uuid := secoto_private.assert_authenticated();
  v_existing jsonb;
  v_quote public.transport_quotes%rowtype;
  v_order public.transport_orders%rowtype;
  v_payment public.payments%rowtype;
  v_strategy text;
  v_client_type text;
begin
  v_existing := secoto_private.lock_operation('od_book_quote', p_idempotency_key);
  if v_existing is not null then return v_existing; end if;

  select * into v_quote from public.transport_quotes q where q.id = p_quote_id for update;
  if not found or not (v_quote.account_id = v_user or (v_quote.business_id is not null and secoto_private.is_business_member(v_quote.business_id, v_user))) then
    raise exception 'Devis introuvable.' using errcode = 'P0002';
  end if;

  select * into v_order from public.transport_orders o where o.quote_id = p_quote_id;
  if found then
    return secoto_private.finish_operation('od_book_quote', p_idempotency_key,
      jsonb_build_object('order', secoto_private.order_client_json(v_order), 'already_booked', true));
  end if;

  if v_quote.status not in ('priced', 'manual_priced') then raise exception 'Ce devis ne peut pas être réservé (%).', v_quote.status; end if;
  if v_quote.valid_until <= now() then
    update public.transport_quotes set status = 'expired', updated_at = now() where id = p_quote_id;
    raise exception 'Ce devis a expiré. Recalculez le prix pour obtenir un devis à jour.';
  end if;
  if v_quote.pickup_at <= now() then raise exception 'La date de prise en charge est dépassée.'; end if;

  if coalesce(p_use_subscription, false) then
    if not secoto_private.flag('subscriptions') then raise exception 'Les abonnements ne sont pas encore ouverts.'; end if;
    v_strategy := 'subscription';
  else
    if not secoto_private.flag('od_payments') then
      raise exception 'Le paiement en ligne n''est pas encore ouvert : contactez SECOTO pour confirmer ce devis.';
    end if;
    -- Décision du 18/09/2026 : on encaisse tout de suite, on garde en réserve
    -- 48 heures, et on rembourse intégralement si aucun transporteur n'accepte.
    v_strategy := 'capture_then_refund';
  end if;

  insert into public.transport_orders(public_ref, quote_id, account_id, business_id, mode, funding, status, payment_strategy,
    client_price_cents, partner_pay_cents, collect_cents, transport_direct_cents, pickup_at)
  values (secoto_private.new_order_ref(), v_quote.id, v_user, v_quote.business_id, v_quote.mode,
    case when v_strategy = 'subscription' then 'subscription' else 'card' end,
    'awaiting_payment', v_strategy, v_quote.client_price_cents, v_quote.partner_pay_cents,
    v_quote.client_price_cents, 0, v_quote.pickup_at)
  returning * into v_order;

  update public.transport_quotes set status = 'accepted', updated_at = now() where id = p_quote_id;

  if v_strategy = 'subscription' then
    perform secoto_private.sub_reserve_for_order(v_order.id);
    perform secoto_private.od_open_dispatch(v_order.id);
  else
    select case when a.client_type = 'particulier' then 'particulier' else 'pro' end into v_client_type
      from public.accounts a where a.id = v_user;
    -- SECOTO vend le transport (sous-traitance) : le consommateur renonce
    -- expressément à son délai de rétractation pour une exécution immédiate.
    insert into public.payments(mission_id, order_id, account_id, purpose, amount_cents, status, capture_method, waiver_required)
    values (null, v_order.id, v_user,
      case when v_order.mode = 'plateau' then 'od_plateau' else 'od_convoyage' end,
      v_order.collect_cents, 'pending', 'automatic',
      coalesce(v_client_type, 'pro') = 'particulier')
    returning * into v_payment;
    update public.transport_orders set payment_id = v_payment.id where id = v_order.id returning * into v_order;
  end if;

  perform secoto_private.audit('order_booked', 'transport_order', v_order.id::text,
    jsonb_build_object('quote_id', p_quote_id, 'strategy', v_strategy));

  return secoto_private.finish_operation('od_book_quote', p_idempotency_key,
    jsonb_build_object('order', secoto_private.order_client_json(v_order), 'already_booked', false));
end;
$f$;

-- ----------------------------------------------------------------------------
-- 6. FACTURE ET RÉCAPITULATIF AUTOMATIQUES À L'ENCAISSEMENT
-- ----------------------------------------------------------------------------
create or replace function secoto_private.od_issue_invoice(p_order_id uuid)
returns void language plpgsql volatile security definer set search_path = ''
as $f$
declare
  v_order public.transport_orders%rowtype;
  v_quote public.transport_quotes%rowtype;
  v_num text;
  v_body text;
  v_line jsonb;
  v_detail text := '';
begin
  select * into v_order from public.transport_orders o where o.id = p_order_id for update;
  if not found or v_order.invoice_number is not null then return; end if;
  select * into v_quote from public.transport_quotes q where q.id = v_order.quote_id;

  v_num := secoto_private.next_doc_number('FAC');
  update public.transport_orders set invoice_number = v_num, invoiced_at = now(), updated_at = now()
   where id = p_order_id;

  for v_line in select value from jsonb_array_elements(coalesce(v_quote.breakdown -> 'lines', '[]'::jsonb)) loop
    v_detail := v_detail || '  - ' || (v_line ->> 'label') || ' : ' || to_char((v_line ->> 'eur')::numeric, 'FM999990D00') || ' EUR' || E'\n';
  end loop;

  v_body :=
    'Facture ' || v_num || E'\n' ||
    'Commande ' || v_order.public_ref || E'\n\n' ||
    'Prestation : transport de vehicule (' ||
      case when v_order.mode = 'plateau' then 'camion plateau' else 'convoyage par la route' end || ')' || E'\n' ||
    'Vehicule : ' || coalesce(nullif(v_quote.vehicle ->> 'model', ''), 'non precise') ||
      case when coalesce((v_quote.vehicle ->> 'rolling')::boolean, true) then ' (roulant)' else ' (NON ROULANT)' end || E'\n' ||
    'Enlevement : ' || coalesce(v_quote.pickup ->> 'label', '') || E'\n' ||
    'Livraison : ' || coalesce(v_quote.delivery ->> 'label', '') || E'\n' ||
    'Date de prise en charge : ' || to_char(v_order.pickup_at at time zone 'Europe/Paris', 'DD/MM/YYYY') || E'\n\n' ||
    case when v_detail <> '' then 'Detail :' || E'\n' || v_detail || E'\n' else '' end ||
    'Total paye : ' || to_char(v_order.client_price_cents / 100.0, 'FM999990D00') || ' EUR' || E'\n' ||
    secoto_private.policy_text('tva', 'TVA non applicable, article 293 B du CGI.') || E'\n\n' ||
    'Votre paiement est conserve en reserve pendant 48 heures, le temps qu''un transporteur SECOTO accepte la mission. ' ||
    'Si aucun transporteur ne se rend disponible, vous etes rembourse integralement sous 24 heures.' || E'\n\n' ||
    'Annulation : remboursement integral jusqu''a 24 heures avant la prise en charge ; au-dela, 50 % sont retenus.' || E'\n\n' ||
    'SECOTO';

  perform secoto_private.queue_email(v_order.account_id,
    'SECOTO - Facture ' || v_num || ' - commande ' || v_order.public_ref,
    v_body, v_order.mission_id, 'od-invoice:' || p_order_id::text);

  perform secoto_private.notify_event(v_order.account_id, 'payment', 'Facture disponible',
    format('Commande %s : facture %s envoyée par e-mail.', v_order.public_ref, v_num),
    null, 'courses', 'od-invoice:' || p_order_id::text, p_order_id);

  perform secoto_private.audit('order_invoiced', 'transport_order', p_order_id::text,
    jsonb_build_object('invoice_number', v_num, 'amount_cents', v_order.client_price_cents));
end;
$f$;

-- ----------------------------------------------------------------------------
-- 7. ÉVÉNEMENTS DE PAIEMENT : nouveau motif, facture, libellés exacts
-- ----------------------------------------------------------------------------
create or replace function public.secoto_od_apply_payment_event(
  p_payment_id uuid, p_event_id text, p_event_type text, p_intent_id text,
  p_amount_refunded_cents integer, p_capture_before timestamptz, p_error text
)
returns jsonb language plpgsql volatile security definer set search_path = ''
as $f$
declare
  v_payment public.payments%rowtype;
  v_order public.transport_orders%rowtype;
  v_new text;
  v_effect text := 'none';
begin
  select * into v_payment from public.payments p where p.id = p_payment_id for update;
  if not found then return jsonb_build_object('skipped', true, 'reason', 'unknown_payment'); end if;
  if v_payment.purpose not in ('od_convoyage', 'od_plateau', 'od_plateau_commission', 'subscription_extension') then
    return jsonb_build_object('skipped', true, 'reason', 'legacy_purpose');
  end if;
  if p_event_id is not null and exists (select 1 from public.payment_events e where e.provider_event_id = p_event_id) then
    return jsonb_build_object('skipped', true, 'reason', 'event_already_processed');
  end if;

  v_new := v_payment.status;
  case p_event_type
    when 'payment_intent.amount_capturable_updated' then
      if v_payment.status in ('pending', 'processing', 'failed') then v_new := 'requires_capture'; end if;
    when 'payment_intent.succeeded' then
      if v_payment.status in ('pending', 'processing', 'failed', 'requires_capture', 'capture_failed') then v_new := 'paid'; end if;
    when 'payment_intent.payment_failed' then
      if v_payment.status in ('pending', 'processing') then v_new := 'failed'; end if;
    when 'payment_intent.canceled' then
      if v_payment.status in ('pending', 'processing', 'requires_capture', 'capture_failed', 'failed') then v_new := 'cancelled'; end if;
    when 'charge.refunded' then
      if coalesce(p_amount_refunded_cents, 0) >= v_payment.amount_cents then v_new := 'refunded'; end if;
    when 'charge.dispute.created' then null;
    when 'charge.dispute.closed' then null;
    else
      return jsonb_build_object('skipped', true, 'reason', 'event_type_ignored');
  end case;

  update public.payments set
    status = v_new,
    provider_intent_id = coalesce(provider_intent_id, p_intent_id),
    authorized_at = case when v_new = 'requires_capture' then coalesce(authorized_at, now()) else authorized_at end,
    capture_before = coalesce(p_capture_before, capture_before),
    captured_at = case when v_new = 'paid' then coalesce(captured_at, now()) else captured_at end,
    paid_at = case when v_new = 'paid' then coalesce(paid_at, now()) else paid_at end,
    failed_at = case when v_new = 'failed' then now() else failed_at end,
    released_at = case when v_new = 'cancelled' then coalesce(released_at, now()) else released_at end,
    refunded_amount_cents = greatest(refunded_amount_cents, coalesce(p_amount_refunded_cents, 0)),
    dispute_status = case p_event_type when 'charge.dispute.created' then 'open' when 'charge.dispute.closed' then 'closed' else dispute_status end,
    last_error = case when v_new = 'failed' then left(coalesce(p_error, ''), 500) else last_error end,
    last_event_at = now(), updated_at = now()
  where id = p_payment_id returning * into v_payment;

  insert into public.payment_events(payment_id, event_type, provider_event_id, payload)
  values (p_payment_id, p_event_type, p_event_id, jsonb_build_object('intent', p_intent_id, 'status', v_new, 'refunded', p_amount_refunded_cents, 'error', p_error))
  on conflict (provider_event_id) where provider_event_id is not null do nothing;

  if v_payment.order_id is not null then
    select * into v_order from public.transport_orders o where o.id = v_payment.order_id for update;
    if v_new = 'paid' then
      -- Facture émise dès l'encaissement, quel que soit l'état du transport.
      perform secoto_private.od_issue_invoice(v_order.id);
    end if;
    if v_new in ('requires_capture', 'paid') and v_order.status = 'awaiting_payment' then
      perform secoto_private.od_open_dispatch(v_order.id);
      v_effect := 'dispatch_opened';
      perform secoto_private.notify_event(v_order.account_id, 'payment', 'Paiement encaissé',
        format('Commande %s : paiement encaissé et gardé en réserve 48 heures, le temps qu''un transporteur accepte. Sans transporteur, remboursement intégral sous 24 heures.', v_order.public_ref),
        null, 'courses', 'od-payment-ok:' || v_order.id::text, v_order.id);
    elsif v_new = 'paid' and v_order.status = 'partner_locked' then
      perform secoto_private.od_confirm(v_order.id);
      v_effect := 'confirmed';
    elsif v_new = 'cancelled' and v_order.status in ('awaiting_payment', 'searching_partner', 'partner_locked') then
      update public.transport_offers set status = 'withdrawn', responded_at = now() where order_id = v_order.id and status = 'sent';
      update public.transport_orders set status = 'cancelled', cancelled_at = now(),
        cancel_reason = coalesce(cancel_reason, 'paiement_non_abouti'), lock_expires_at = null, updated_at = now()
       where id = v_order.id;
      v_effect := 'order_cancelled';
    elsif v_new = 'failed' then
      perform secoto_private.notify_event(v_order.account_id, 'payment_failed', 'Paiement refusé',
        format('Commande %s : le paiement n''a pas abouti. Aucune demande n''est diffusée.', v_order.public_ref),
        null, 'paiement', 'od-payment-failed:' || p_payment_id::text || ':' || coalesce(p_event_id, ''), v_order.id);
    end if;
  end if;

  if p_event_type = 'charge.dispute.created' then
    perform secoto_private.notify_admins_event('payment_failed', 'Contestation bancaire',
      format('Paiement %s contesté.', p_payment_id), 'paiement', 'dispute:' || p_payment_id::text, p_payment_id);
  end if;
  return jsonb_build_object('payment_id', p_payment_id, 'status', v_new, 'effect', v_effect);
end;
$f$;

-- ----------------------------------------------------------------------------
-- 8. ARRÊT D'UNE COMMANDE : remboursement total ou partiel
-- ----------------------------------------------------------------------------
create or replace function secoto_private.od_stop_order(p_order_id uuid, p_status text, p_reason text)
returns void language plpgsql volatile security definer set search_path = ''
as $f$
begin
  perform secoto_private.od_stop_order_amount(p_order_id, p_status, p_reason, null);
end;
$f$;

-- p_refund_cents : NULL = tout le solde. Sinon montant exact à rembourser.
create or replace function secoto_private.od_stop_order_amount(p_order_id uuid, p_status text, p_reason text, p_refund_cents integer)
returns void language plpgsql volatile security definer set search_path = ''
as $f$
declare v_order public.transport_orders%rowtype;
begin
  select * into v_order from public.transport_orders o where o.id = p_order_id for update;
  update public.transport_offers set status = 'withdrawn', responded_at = now() where order_id = p_order_id and status = 'sent';
  update public.transport_orders set status = p_status,
      cancelled_at = case when p_status = 'cancelled' then now() else cancelled_at end,
      cancel_reason = p_reason, lock_partner_id = null, lock_offer_id = null, lock_expires_at = null,
      refund_due_at = case when p_status = 'no_partner'
                           then now() + make_interval(hours => secoto_private.policy_num('no_partner_refund_hours', 24)::int)
                           else refund_due_at end,
      updated_at = now()
   where id = p_order_id;

  -- La mission éventuellement créée est annulée avec la commande.
  if v_order.mission_id is not null and p_status = 'cancelled' then
    update public.missions set status = 'cancelled', cancelled_at = now(),
      cancellation_reason = left(coalesce(p_reason, 'annulation'), 500)
     where id = v_order.mission_id and status::text not in ('completed', 'cancelled');
    update public.partner_payouts set status = 'cancelled' where order_id = p_order_id and status = 'to_pay';
  end if;

  if v_order.funding = 'subscription' then
    perform secoto_private.sub_release_for_order(p_order_id, p_reason);
  elsif v_order.payment_id is not null then
    if p_refund_cents = 0 then
      -- Rien à rembourser : la retenue couvre la totalité.
      return;
    end if;
    update public.payments set release_requested_at = coalesce(release_requested_at, now()),
      refund_reason = coalesce(refund_reason, p_reason),
      refund_requested_cents = coalesce(refund_requested_cents, p_refund_cents),
      status = case when status = 'paid' then 'refund_pending' else status end,
      refund_requested_at = case when status = 'paid' then coalesce(refund_requested_at, now()) else refund_requested_at end,
      updated_at = now()
     where id = v_order.payment_id and status in ('pending', 'processing', 'requires_capture', 'capture_failed', 'paid');
  end if;
end;
$f$;

-- ----------------------------------------------------------------------------
-- 9. ANNULATION CLIENT : gratuite jusqu'à 24 h avant, puis 50 % retenus
-- ----------------------------------------------------------------------------
create or replace function public.secoto_od_cancel_quote_preview(p_order_id uuid)
returns jsonb language plpgsql stable security definer set search_path = ''
as $f$
declare
  v_user uuid := secoto_private.assert_authenticated();
  v_order public.transport_orders%rowtype;
  v_free_h numeric := secoto_private.policy_num('free_cancel_hours_before_pickup', 24);
  v_pct numeric := secoto_private.policy_num('late_cancel_retained_pct', 50);
  v_late boolean;
begin
  select * into v_order from public.transport_orders o where o.id = p_order_id;
  if not found or not (v_order.account_id = v_user or (v_order.business_id is not null and secoto_private.is_business_member(v_order.business_id, v_user))) then
    raise exception 'Commande introuvable.' using errcode = 'P0002';
  end if;
  v_late := v_order.pickup_at - make_interval(hours => v_free_h::int) <= now();
  return jsonb_build_object(
    'cancellable', v_order.status not in ('delivered', 'cancelled', 'no_partner'),
    'late', v_late,
    'free_until', v_order.pickup_at - make_interval(hours => v_free_h::int),
    'retained_pct', case when v_late then v_pct else 0 end,
    'refund_cents', case when v_late then v_order.client_price_cents - round(v_order.client_price_cents * v_pct / 100)::int
                         else v_order.client_price_cents end);
end;
$f$;

create or replace function public.secoto_od_cancel_order(p_order_id uuid, p_idempotency_key uuid)
returns jsonb language plpgsql volatile security definer set search_path = ''
as $f$
declare
  v_user uuid := secoto_private.assert_authenticated();
  v_existing jsonb;
  v_order public.transport_orders%rowtype;
  v_free_h numeric := secoto_private.policy_num('free_cancel_hours_before_pickup', 24);
  v_pct numeric := secoto_private.policy_num('late_cancel_retained_pct', 50);
  v_late boolean;
  v_refund integer;
  v_reason text;
begin
  v_existing := secoto_private.lock_operation('od_cancel_order', p_idempotency_key);
  if v_existing is not null then return v_existing; end if;
  select * into v_order from public.transport_orders o where o.id = p_order_id for update;
  if not found or not (v_order.account_id = v_user or (v_order.business_id is not null and secoto_private.is_business_member(v_order.business_id, v_user))) then
    raise exception 'Commande introuvable.' using errcode = 'P0002';
  end if;
  if v_order.status = 'partner_locked' then
    raise exception 'Un transporteur est en cours de confirmation : réessayez dans deux minutes.';
  end if;
  if v_order.status in ('cancelled', 'delivered', 'no_partner') then
    return secoto_private.finish_operation('od_cancel_order', p_idempotency_key, secoto_private.order_client_json(v_order));
  end if;
  if v_order.status = 'picked_up' then
    raise exception 'Le véhicule est déjà pris en charge : contactez SECOTO.';
  end if;

  v_late := v_order.pickup_at - make_interval(hours => v_free_h::int) <= now();
  if v_order.funding = 'subscription' then
    v_refund := null;
  elsif v_late then
    v_refund := v_order.client_price_cents - round(v_order.client_price_cents * v_pct / 100)::int;
  else
    v_refund := v_order.client_price_cents;
  end if;
  v_reason := case when v_late then 'annulation_client_tardive' else 'annulation_client' end;

  perform secoto_private.od_stop_order_amount(p_order_id, 'cancelled', v_reason, v_refund);

  if v_order.assigned_partner_id is not null then
    perform secoto_private.notify_event(v_order.assigned_partner_id, 'cancellation', 'Mission annulée',
      format('Commande %s annulée par le client.', v_order.public_ref),
      v_order.mission_id, 'assigned', 'od-cancel-partner:' || p_order_id::text, p_order_id);
    perform secoto_private.notify_admins_event('cancellation', 'Annulation après attribution',
      format('%s · %s retenus · transporteur à arbitrer', v_order.public_ref,
        to_char(coalesce(v_order.client_price_cents - coalesce(v_refund, 0), 0) / 100.0, 'FM999990D00') || ' €'),
      'requests', 'od-cancel-admin:' || p_order_id::text, p_order_id);
  end if;

  perform secoto_private.notify_event(v_order.account_id, 'order_update', 'Commande annulée',
    case when v_late
      then format('Commande %s annulée. Annulation à moins de %s h de la prise en charge : %s %% retenus, %s € remboursés.',
             v_order.public_ref, v_free_h::int, v_pct::int, to_char(coalesce(v_refund, 0) / 100.0, 'FM999990D00'))
      else format('Commande %s annulée. Vous êtes remboursé intégralement.', v_order.public_ref) end,
    null, 'courses', 'od-cancel-client:' || p_order_id::text, p_order_id);

  perform secoto_private.audit('order_cancelled_by_client', 'transport_order', p_order_id::text,
    jsonb_build_object('late', v_late, 'refund_cents', v_refund, 'retained_pct', case when v_late then v_pct else 0 end));
  select * into v_order from public.transport_orders o where o.id = p_order_id;
  return secoto_private.finish_operation('od_cancel_order', p_idempotency_key, secoto_private.order_client_json(v_order));
end;
$f$;

-- ----------------------------------------------------------------------------
-- 10. MAINTENANCE : un seul tour, remboursement sous 24 h, versements dus
-- ----------------------------------------------------------------------------
create or replace function public.secoto_od_maintenance_tick()
returns jsonb language plpgsql volatile security definer set search_path = ''
as $f$
declare
  r record;
  v_rounds integer := secoto_private.policy_num('max_rounds', 1)::int;
  v_rebroadcast integer := 0; v_no_partner integer := 0; v_expired_quotes integer := 0;
  v_locks jsonb := '[]'::jsonb;
  v_actions jsonb;
  v_payouts integer := 0;
begin
  update public.transport_quotes set status = 'expired', updated_at = now()
   where status in ('priced', 'manual_priced') and valid_until <= now();
  get diagnostics v_expired_quotes = row_count;

  update public.transport_offers set status = 'expired' where status = 'sent' and expires_at <= now();

  for r in select o.id, o.dispatch_round, o.pickup_at, o.account_id, o.public_ref from public.transport_orders o
            where o.status = 'searching_partner' and o.offers_expire_at <= now()
            for update skip locked loop
    if r.dispatch_round >= v_rounds or r.pickup_at <= now() then
      perform secoto_private.od_stop_order(r.id, 'no_partner', 'aucun_transporteur_disponible');
      perform secoto_private.notify_event(r.account_id, 'order_update', 'Aucun transporteur disponible',
        format('Commande %s : aucun transporteur ne s''est rendu disponible dans les 48 heures. Vous êtes remboursé intégralement sous 24 heures.', r.public_ref),
        null, 'courses', 'od-no-partner:' || r.id::text, r.id);
      perform secoto_private.notify_admins_event('order_update', 'Commande sans transporteur — rembourser sous 24 h',
        r.public_ref, 'requests', 'od-no-partner-admin:' || r.id::text, r.id);
      v_no_partner := v_no_partner + 1;
    else
      perform secoto_private.od_broadcast(r.id);
      v_rebroadcast := v_rebroadcast + 1;
    end if;
  end loop;

  select coalesce(jsonb_agg(jsonb_build_object('order_id', o.id, 'payment_id', o.payment_id, 'intent_id', p.provider_intent_id, 'funding', o.funding)), '[]'::jsonb)
    into v_locks
    from public.transport_orders o left join public.payments p on p.id = o.payment_id
   where o.status = 'partner_locked' and o.lock_expires_at <= now();

  select coalesce(jsonb_agg(jsonb_build_object('payment_id', p.id, 'intent_id', p.provider_intent_id, 'status', p.status,
      'action', case when p.status = 'refund_pending' then 'refund' else 'cancel' end,
      'amount_cents', least(coalesce(p.refund_requested_cents, p.amount_cents - p.refunded_amount_cents),
                            p.amount_cents - p.refunded_amount_cents))), '[]'::jsonb)
    into v_actions
    from public.payments p
   where p.purpose in ('od_convoyage', 'od_plateau', 'od_plateau_commission', 'subscription_extension')
     and p.release_requested_at is not null and p.status in ('pending', 'processing', 'requires_capture', 'capture_failed', 'refund_pending');

  -- Versements transporteurs échus (livraison + 48 h) : rappel à l'administrateur.
  for r in select pp.id, pp.partner_id, m.public_ref, pp.amount_cents
             from public.partner_payouts pp join public.missions m on m.id = pp.mission_id
            where pp.status = 'to_pay' and pp.due_at is not null and pp.due_at <= now() loop
    perform secoto_private.notify_admins_event('payment', 'Versement transporteur à effectuer',
      format('%s · %s €', r.public_ref, to_char(r.amount_cents / 100.0, 'FM999990D00')),
      'paiement', 'payout-due:' || r.id::text, r.id);
    v_payouts := v_payouts + 1;
  end loop;

  return jsonb_build_object('expired_quotes', v_expired_quotes, 'rebroadcast', v_rebroadcast, 'no_partner', v_no_partner,
    'expired_locks', v_locks, 'payment_actions', v_actions, 'payouts_due', v_payouts);
end;
$f$;

create or replace function public.secoto_od_payment_action_result(p_payment_id uuid, p_action text, p_success boolean, p_error text)
returns void language plpgsql volatile security definer set search_path = ''
as $f$
begin
  if p_success then
    update public.payments set
      status = case
        when p_action = 'refund' and coalesce(refund_requested_cents, amount_cents) >= amount_cents - refunded_amount_cents then 'refunded'
        when p_action = 'refund' then 'paid'
        else 'cancelled' end,
      refunded_amount_cents = case when p_action = 'refund'
        then least(amount_cents, refunded_amount_cents + coalesce(refund_requested_cents, amount_cents - refunded_amount_cents))
        else refunded_amount_cents end,
      released_at = case when p_action = 'cancel' then coalesce(released_at, now()) else released_at end,
      release_requested_at = null, refund_requested_cents = null, updated_at = now()
    where id = p_payment_id and status in ('pending', 'processing', 'requires_capture', 'capture_failed', 'refund_pending');
  else
    update public.payments set last_error = left(coalesce(p_error, p_action || '_failed'), 500), updated_at = now() where id = p_payment_id;
  end if;
end;
$f$;

-- ----------------------------------------------------------------------------
-- 11. VERSEMENT TRANSPORTEUR DANS LES 48 H, DANS LES DEUX MODES
-- ----------------------------------------------------------------------------
create or replace function secoto_private.trg_od_sync_from_mission()
returns trigger language plpgsql volatile security definer set search_path = ''
as $f$
declare v_order public.transport_orders%rowtype; v_delay numeric;
begin
  select * into v_order from public.transport_orders o where o.mission_id = new.id;
  if not found then return new; end if;
  if coalesce(new.progress_status, '') in ('pickup_completed', 'in_transit', 'incident_reported', 'delivery_started')
     and v_order.status = 'partner_confirmed' then
    update public.transport_orders set status = 'picked_up', updated_at = now() where id = v_order.id;
  elsif (coalesce(new.progress_status, '') in ('delivery_completed', 'completed') or new.status::text = 'completed')
     and v_order.status in ('partner_confirmed', 'picked_up') then
    update public.transport_orders set status = 'delivered', updated_at = now() where id = v_order.id;
    perform secoto_private.sub_consume_for_order(v_order.id);
    v_delay := secoto_private.policy_num('payout_delay_hours', 48);
    -- SECOTO encaisse la totalité : le transporteur est réglé par virement,
    -- au plus tard 48 heures après la livraison, dans les deux modes.
    insert into public.partner_payouts(mission_id, order_id, partner_id, amount_cents, due_at, mode)
    values (new.id, v_order.id, v_order.assigned_partner_id, v_order.partner_pay_cents,
            now() + make_interval(hours => v_delay::int), v_order.mode)
    on conflict (mission_id) do nothing;
    perform secoto_private.notify_event(v_order.assigned_partner_id, 'payment', 'Paiement en route',
      format('Mission %s livrée : %s € vous sont versés sous 48 heures.', new.public_ref,
             to_char(v_order.partner_pay_cents / 100.0, 'FM999990D00')),
      new.id, 'paiement', 'od-payout-announced:' || v_order.id::text, v_order.id);
  end if;
  return new;
end;
$f$;

-- ----------------------------------------------------------------------------
-- 12. PILOTAGE ADMIN : modifier les conditions à tout moment
-- ----------------------------------------------------------------------------
create or replace function public.secoto_admin_od_update_conditions(p_order_id uuid, p_payload jsonb, p_note text)
returns jsonb language plpgsql volatile security definer set search_path = ''
as $f$
declare
  v_order public.transport_orders%rowtype;
  v_quote public.transport_quotes%rowtype;
  v_client integer; v_partner integer; v_pickup timestamptz;
  v_changes jsonb := '{}'::jsonb;
  v_paid boolean;
begin
  perform secoto_private.assert_admin();
  if length(btrim(coalesce(p_note, ''))) < 3 then
    raise exception 'Indiquez le motif de la modification.';
  end if;
  select * into v_order from public.transport_orders o where o.id = p_order_id for update;
  if not found then raise exception 'Commande introuvable.' using errcode = 'P0002'; end if;
  if v_order.status in ('cancelled', 'no_partner') then
    raise exception 'Commande arrêtée : plus rien à modifier.';
  end if;
  select * into v_quote from public.transport_quotes q where q.id = v_order.quote_id for update;

  v_client := coalesce((p_payload ->> 'client_price_cents')::int, v_order.client_price_cents);
  v_partner := coalesce((p_payload ->> 'partner_pay_cents')::int, v_order.partner_pay_cents);
  v_pickup := coalesce((p_payload ->> 'pickup_at')::timestamptz, v_order.pickup_at);
  if v_client <= 0 or v_partner < 0 then raise exception 'Montants invalides.'; end if;
  if v_partner > v_client then raise exception 'La rémunération transporteur ne peut pas dépasser le prix client.'; end if;

  if p_payload ? 'pickup' or p_payload ? 'delivery' or p_payload ? 'vehicle' then
    update public.transport_quotes set
      pickup = coalesce(p_payload -> 'pickup', pickup),
      delivery = coalesce(p_payload -> 'delivery', delivery),
      vehicle = coalesce(p_payload -> 'vehicle', vehicle),
      updated_at = now()
     where id = v_quote.id returning * into v_quote;
  end if;

  if v_client <> v_order.client_price_cents then v_changes := v_changes || jsonb_build_object('client_price_cents', jsonb_build_array(v_order.client_price_cents, v_client)); end if;
  if v_partner <> v_order.partner_pay_cents then v_changes := v_changes || jsonb_build_object('partner_pay_cents', jsonb_build_array(v_order.partner_pay_cents, v_partner)); end if;
  if v_pickup <> v_order.pickup_at then v_changes := v_changes || jsonb_build_object('pickup_at', jsonb_build_array(v_order.pickup_at, v_pickup)); end if;

  update public.transport_orders set
    client_price_cents = v_client, partner_pay_cents = v_partner,
    collect_cents = v_client, transport_direct_cents = 0,
    pickup_at = v_pickup, conditions_updated_at = now(), updated_at = now()
   where id = p_order_id returning * into v_order;

  -- Offres en cours : la rémunération affichée suit la décision de l'admin.
  update public.transport_offers set partner_pay_cents = v_partner where order_id = p_order_id and status = 'sent';

  if v_order.mission_id is not null then
    update public.missions set
      mission_date = v_pickup,
      pickup_address = coalesce(v_quote.pickup ->> 'label', pickup_address),
      delivery_address = coalesce(v_quote.delivery ->> 'label', delivery_address),
      from_city = coalesce(v_quote.pickup ->> 'city', from_city),
      to_city = coalesce(v_quote.delivery ->> 'city', to_city),
      vehicle = coalesce(left(v_quote.vehicle ->> 'model', 120), vehicle),
      vehicle_rolling = coalesce((v_quote.vehicle ->> 'rolling')::boolean, vehicle_rolling),
      manual_pricing = true,
      manual_carrier_pay = v_partner / 100.0,
      manual_margin = (v_client - v_partner) / 100.0
     where id = v_order.mission_id;
    update public.partner_payouts set amount_cents = v_partner
     where order_id = p_order_id and status = 'to_pay';
  end if;

  select (p.status = 'paid') into v_paid from public.payments p where p.id = v_order.payment_id;
  if coalesce(v_paid, false) and v_changes ? 'client_price_cents' then
    -- Prix changé après encaissement : aucun débit ni remboursement automatique.
    perform secoto_private.notify_admins_event('payment', 'Écart de prix à régulariser',
      format('%s : prix modifié après encaissement. Complément ou remboursement à traiter manuellement.', v_order.public_ref),
      'paiement', 'od-price-change:' || p_order_id::text || ':' || extract(epoch from now())::bigint::text, p_order_id);
  end if;

  perform secoto_private.notify_event(v_order.account_id, 'order_update', 'Conditions mises à jour',
    format('Commande %s : %s', v_order.public_ref, left(p_note, 160)),
    v_order.mission_id, 'courses', 'od-conditions:' || p_order_id::text || ':' || extract(epoch from now())::bigint::text, p_order_id);
  if v_order.assigned_partner_id is not null then
    perform secoto_private.notify_event(v_order.assigned_partner_id, 'order_update', 'Mission modifiée',
      format('Mission %s : %s', v_order.public_ref, left(p_note, 160)),
      v_order.mission_id, 'assigned', 'od-conditions-partner:' || p_order_id::text || ':' || extract(epoch from now())::bigint::text, p_order_id);
  end if;

  perform secoto_private.audit('order_conditions_updated', 'transport_order', p_order_id::text,
    jsonb_build_object('note', p_note, 'changes', v_changes));
  return secoto_private.order_client_json(v_order);
end;
$f$;

-- Devis manuel admin : SECOTO encaisse aussi la totalité.
do $price_quote$
declare v_src text;
begin
  select pg_get_functiondef(p.oid) into v_src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'secoto_admin_price_quote';
  if v_src is null then return; end if;
  v_src := replace(v_src,
    'collect_cents = case when mode = ''plateau'' then v_margin else p_client_price_cents end,',
    'collect_cents = p_client_price_cents,');
  v_src := replace(v_src,
    'transport_direct_cents = case when mode = ''plateau'' then p_partner_pay_cents else 0 end,',
    'transport_direct_cents = 0,');
  execute v_src;
end
$price_quote$;

-- ----------------------------------------------------------------------------
-- 13. SOUS-TRAITANCE TOTALE SUR LES MISSIONS MANUELLES
-- ----------------------------------------------------------------------------
-- Les missions créées AVANT la bascule gardent strictement leurs montants :
-- aucune mission en cours n'est modifiée. À partir de la bascule, le plateau
-- suit la même règle que le convoyage : SECOTO encaisse tout, puis reverse.
create or replace function public.secoto_trg_mission_amounts()
returns trigger
language plpgsql
set search_path = ''
as $function$
declare
  v_type      text    := coalesce(new.type::text, 'convoyage');
  v_manual    boolean := coalesce(new.manual_pricing, false);
  v_carrier   numeric;
  v_margin    numeric;
  v_client    numeric;
  v_transport numeric;
  v_cutover   timestamptz;
begin
  if v_manual then
    v_carrier := round(greatest(coalesce(new.manual_carrier_pay, 0), 0), 2);
    v_margin  := round(greatest(coalesce(new.manual_margin, 0), 0), 2);

    select (s.value ->> 'sous_traitance_totale_since')::timestamptz into v_cutover
      from public.app_settings s where s.key = 'dispatch_policy';

    if v_type = 'plateau'
       and (v_cutover is null or coalesce(new.created_at, now()) < v_cutover) then
      -- Ancien modèle d'intermédiation : conservé pour les missions antérieures.
      v_client    := v_margin;
      v_transport := v_carrier;
    else
      -- Sous-traitance : SECOTO encaisse la totalité, puis règle le transporteur.
      v_client    := round(v_carrier + v_margin, 2);
      v_transport := 0;
    end if;

    new.carrier_cost := v_carrier;
  else
    v_carrier := public.secoto_compute_carrier_pay(
      v_type, new.distance_km, new.carrier_cost);
    v_client := public.secoto_compute_client_price(
      v_type, new.distance_km, new.carrier_cost,
      new.surcharge_urgent, new.surcharge_weekend, new.surcharge_oversize_pct);
    v_margin := public.secoto_compute_margin(
      v_type, new.distance_km, new.carrier_cost,
      new.surcharge_urgent, new.surcharge_weekend, new.surcharge_oversize_pct);
    v_transport := public.secoto_compute_transport_amount(v_type, new.carrier_cost);
  end if;

  new.carrier_pay       := v_carrier;
  new.client_price      := v_client;
  new.margin            := v_margin;
  new.commission_amount := case when v_type = 'plateau' then round(v_client, 2) else 0 end;
  new.transport_amount  := round(coalesce(v_transport, 0), 2);
  new.client_total_due  := round(v_client + coalesce(v_transport, 0), 2);

  return new;
end;
$function$;

-- ----------------------------------------------------------------------------
-- 14. FIN DES CANDIDATURES : accepter ou refuser, partout
-- ----------------------------------------------------------------------------
-- Le tableau des missions publiées affiche désormais la rémunération et l'état
-- du véhicule. Aucune information client ni marge n'y figure.
create or replace view public.secoto_public_missions_v2
with (security_barrier = true, security_invoker = false)
as
select
  m.id, m.public_ref, m.type, m.status, m.progress_status,
  m.from_city, m.to_city, m.vehicle, m.distance_km, m.created_at,
  m.vehicle_category,
  m.capacity_units, m.window_start, m.window_end,
  m.mission_date,
  coalesce(m.vehicle_rolling, true) as vehicle_rolling,
  m.carrier_pay
  -- JAMAIS client_price, margin, commission_amount ni client_total_due ici.
from public.missions m
where public.secoto_current_transporter_matches_mission(m.id)
  and not exists (select 1 from public.mission_declines d where d.mission_id = m.id and d.partner_id = auth.uid());

grant select on table public.secoto_public_missions_v2 to authenticated;

create or replace function public.secoto_mission_accept(p_mission_id uuid, p_idempotency_key uuid)
returns jsonb language plpgsql volatile security definer set search_path = ''
as $f$
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
$f$;

create or replace function public.secoto_mission_decline(p_mission_id uuid)
returns jsonb language plpgsql volatile security definer set search_path = ''
as $f$
declare v_user uuid := secoto_private.assert_authenticated();
begin
  insert into public.mission_declines(mission_id, partner_id) values (p_mission_id, v_user)
  on conflict do nothing;
  return jsonb_build_object('result', 'declined', 'mission_id', p_mission_id);
end;
$f$;

-- La candidature avec prix proposé est fermée dès que l'acceptation directe
-- est ouverte : un seul chemin, pas deux comportements possibles.
do $apply_guard$
declare v_src text; v_args text;
begin
  select pg_get_functiondef(p.oid), pg_get_function_identity_arguments(p.oid) into v_src, v_args
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'secoto_apply_to_mission';
  if v_src is null then return; end if;
  v_src := replace(v_src,
    'if not secoto_private.is_verified_transporter(v_user_id) then',
    'if secoto_private.flag(''direct_accept'') then' || E'\n' ||
    '    raise exception ''Les candidatures sont remplacées par l''''acceptation directe : la rémunération est affichée, vous acceptez ou vous refusez.'';' || E'\n' ||
    '  end if;' || E'\n' ||
    '  if not secoto_private.is_verified_transporter(v_user_id) then');
  execute v_src;
end
$apply_guard$;

-- ----------------------------------------------------------------------------
-- 14 bis. CE QUE VOIT LE TRANSPORTEUR SUR UNE PROPOSITION
-- ----------------------------------------------------------------------------
-- SECOTO encaisse le client puis règle le transporteur : plus aucun transport
-- n'est payé en direct sur le plateau. Le convoyage garde ses frais réels
-- remboursés sur justificatifs (barème validé, inchangé).
create or replace function secoto_private.offer_partner_json(x public.transport_offers)
returns jsonb language sql stable security definer set search_path = ''
as $f$
  select jsonb_build_object(
    'id', x.id, 'order_ref', o.public_ref, 'mode', o.mode,
    'state', case
      when o.assigned_partner_id = x.partner_id then 'confirmed'
      when o.status = 'partner_locked' and o.lock_partner_id = x.partner_id then 'pending_capture'
      when o.status in ('partner_locked', 'partner_confirmed', 'picked_up', 'delivered') then 'already_assigned'
      when o.status in ('cancelled', 'no_partner') then 'unavailable'
      when x.status = 'declined' then 'declined'
      when x.status in ('expired', 'voided', 'withdrawn', 'lost') or x.expires_at <= now() or x.round <> o.dispatch_round then 'expired'
      else 'available' end,
    'partner_pay_cents', x.partner_pay_cents,
    'expires_at', x.expires_at,
    'pickup', jsonb_build_object('label', q.pickup ->> 'label', 'city', q.pickup ->> 'city', 'postcode', q.pickup ->> 'postcode'),
    'delivery', jsonb_build_object('label', q.delivery ->> 'label', 'city', q.delivery ->> 'city', 'postcode', q.delivery ->> 'postcode'),
    'distance_km', q.route -> 'distance_km', 'duration_min', q.route -> 'duration_min',
    'vehicle', q.vehicle, 'schedule', q.schedule, 'pickup_at', o.pickup_at,
    'partner_included', case when o.mode = 'convoyage'
      then jsonb_build_array(
        'Frais réels (carburant, péages) remboursés sur justificatifs validés',
        'Rémunération versée par SECOTO sous 48 h après la livraison')
      else jsonb_build_array(
        'Péages et carburant inclus dans votre rémunération',
        'Rémunération versée par SECOTO sous 48 h après la livraison') end,
    'partner_excluded', case when o.mode = 'convoyage'
      then jsonb_build_array('Retour après livraison : à votre charge')
      else jsonb_build_array('Retour à vide après livraison : à votre charge') end,
    'mission_id', case when o.assigned_partner_id = x.partner_id then o.mission_id end)
  from public.transport_orders o join public.transport_quotes q on q.id = o.quote_id
  where o.id = x.order_id;
$f$;

-- ----------------------------------------------------------------------------
-- 15. DROITS
-- ----------------------------------------------------------------------------
grant execute on function public.secoto_od_cancel_quote_preview(uuid) to authenticated;
grant execute on function public.secoto_mission_accept(uuid, uuid) to authenticated;
grant execute on function public.secoto_mission_decline(uuid) to authenticated;
grant execute on function public.secoto_admin_od_update_conditions(uuid, jsonb, text) to authenticated;
grant execute on function secoto_private.next_doc_number(text) to service_role;
grant execute on function secoto_private.policy_text(text, text) to authenticated, service_role;

-- ----------------------------------------------------------------------------
-- 16. CONTRÔLES
-- ----------------------------------------------------------------------------
do $verif$
declare v numeric; v_txt text;
begin
  select (s.value ->> 'offer_ttl_minutes')::numeric into v from public.app_settings s where s.key = 'dispatch_policy';
  if v <> 2880 then raise exception 'Fenêtre d''offre : % minutes au lieu de 2880 (48 h)', v; end if;
  select (s.value ->> 'max_rounds')::numeric into v from public.app_settings s where s.key = 'dispatch_policy';
  if v <> 1 then raise exception 'Un seul tour de diffusion attendu, % trouvé', v; end if;
  if secoto_private.policy_num('payout_delay_hours', 0) <> 48 then raise exception 'Délai de versement transporteur incorrect.'; end if;
  if secoto_private.policy_num('free_cancel_hours_before_pickup', 0) <> 24 then raise exception 'Fenêtre d''annulation gratuite incorrecte.'; end if;
  if secoto_private.policy_num('late_cancel_retained_pct', 0) <> 50 then raise exception 'Retenue d''annulation tardive incorrecte.'; end if;
  v_txt := secoto_private.policy_text('tva', '');
  if position('293 B' in v_txt) = 0 then raise exception 'Mention de TVA absente : %', v_txt; end if;
  if not exists (select 1 from public.secoto_feature_flags f where f.key = 'direct_accept') then
    raise exception 'Interrupteur direct_accept absent.';
  end if;
  if exists (select 1 from public.secoto_feature_flags f where f.key = 'direct_accept' and f.enabled) then
    raise exception 'direct_accept ne doit pas être activé par la migration.';
  end if;
end
$verif$;

notify pgrst, 'reload schema';
commit;
