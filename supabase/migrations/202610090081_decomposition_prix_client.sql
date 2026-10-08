-- ============================================================================
-- SECOTO 081 — Décomposition du prix pour le client (D5, lot 3)
-- ----------------------------------------------------------------------------
-- Plateau en paiement direct uniquement (interrupteur plateau_paiement_direct) :
-- le client voit, avant de valider, le prix réservé au transporteur et la
-- commission de mise en relation SECOTO. Le convoyage et l'ancien circuit ne
-- changent pas. Côté transporteur, rien ne change : il ne voit toujours ni le
-- prix client ni la commission.
-- Migration additive et rejouable.
-- ============================================================================

-- 1. DEVIS (avant réservation) -----------------------------------------------------
create or replace function secoto_private.quote_client_json(q public.transport_quotes)
returns jsonb language sql stable set search_path = ''
as $f$
  select jsonb_build_object(
    'id', q.id, 'mode', q.mode, 'status',
      case when q.status in ('priced', 'manual_priced') and q.valid_until <= now() then 'expired' else q.status end,
    'pickup', q.pickup, 'delivery', q.delivery, 'vehicle', q.vehicle, 'schedule', q.schedule,
    'vehicles', coalesce(q.vehicles, jsonb_build_array(q.vehicle)),
    'group_discount_cents', coalesce(q.group_discount_cents, 0),
    'distance_km', q.route -> 'distance_km', 'duration_min', q.route -> 'duration_min',
    'client_price_cents', q.client_price_cents,
    'collect_cents', q.collect_cents,
    'transport_direct_cents', q.transport_direct_cents,
    'lines', coalesce(q.breakdown -> 'lines', '[]'::jsonb),
    'included', coalesce(q.breakdown -> 'included', '[]'::jsonb),
    'excluded', coalesce(q.breakdown -> 'excluded', '[]'::jsonb),
    'grid_version', q.grid_version,
    'manual_reason', q.manual_reason,
    'valid_until', q.valid_until, 'pickup_at', q.pickup_at,
    'business_id', q.business_id, 'created_at', q.created_at,
    -- 081 : plateau en paiement direct -> décomposition affichée AVANT le
    -- paiement (prix réservé au transporteur + commission SECOTO). Jamais
    -- pour le convoyage, jamais quand l'interrupteur est éteint.
    'payment_circuit', case when q.mode = 'plateau' and secoto_private.flag('plateau_paiement_direct') then 'direct' end,
    'transport_price_cents', case when q.mode = 'plateau' and secoto_private.flag('plateau_paiement_direct')
                                   and q.partner_pay_cents is not null then q.partner_pay_cents end,
    'commission_cents', case when q.mode = 'plateau' and secoto_private.flag('plateau_paiement_direct')
                              and q.partner_pay_cents is not null and q.client_price_cents is not null
                              then q.client_price_cents - q.partner_pay_cents end);
$f$;

-- 2. COMMANDE ---------------------------------------------------------------------------
select secoto_private.mig074_patch(
  'secoto_private.order_client_json(public.transport_orders)'::regprocedure,
  '''payment_circuit'', o.payment_circuit, ''payment_action_required'',',
  '''payment_circuit'', o.payment_circuit,
    ''transport_price_cents'', case when o.payment_circuit = ''direct'' then o.partner_pay_cents end,
    ''commission_cents'', case when o.payment_circuit = ''direct'' then o.client_price_cents - o.partner_pay_cents end,
    ''payment_action_required'',');

-- 3. LIEN DE PAIEMENT DE DEVIS -------------------------------------------------------------
select secoto_private.mig074_patch(
  'public.secoto_devis_link_open(text)'::regprocedure,
  '      ''account_id'',      v_payment.account_id',
  '      ''account_id'',      v_payment.account_id,
      ''commission_cents'', case when v_payment.payment_circuit = ''direct'' then
        (select o.client_price_cents - o.partner_pay_cents from public.transport_orders o where o.id = v_payment.order_id) end');
select secoto_private.mig074_patch(
  'public.secoto_devis_link_open(text)'::regprocedure,
  '    ''application_fee_cents'', v_payment.application_fee_cents',
  '    ''application_fee_cents'', v_payment.application_fee_cents,
    ''commission_cents'', v_payment.application_fee_cents');

notify pgrst, 'reload schema';
