-- ============================================================================
-- SECOTO 079 — Paiement direct : commande de plusieurs véhicules
-- ----------------------------------------------------------------------------
-- La paie d'une commande groupée couvre tous ses véhicules. Dans le circuit
-- direct, elle n'est virée vers la banque du transporteur qu'une fois TOUS les
-- véhicules livrés (ou annulés), et non dès la livraison du premier.
-- Seule la file des virements du circuit direct est modifiée : l'ancien
-- circuit (Transfers) ne change pas. Migration rejouable.
-- ============================================================================
create or replace function public.secoto_direct_payouts_claim_due(p_limit integer default 20)
returns jsonb language plpgsql volatile security definer set search_path = ''
as $f$
declare v_rows jsonb; v_bloque record;
begin
  -- Virement resté « en cours » plus de 24 h : Stripe a oublié sa clé
  -- d'idempotence, un nouvel essai pourrait payer deux fois. On s'arrête et
  -- l'administrateur vérifie dans Stripe.
  for v_bloque in
    update public.partner_payouts
       set status = 'failed', processing_at = null,
           last_error = left(coalesce(last_error || ' | ', '') || 'Virement interrompu depuis plus de 24 h : vérifier dans Stripe avant tout nouveau virement.', 500)
     where payment_circuit = 'direct' and status = 'processing' and processing_at < now() - interval '24 hours'
    returning id, amount_cents, connected_account_id
  loop
    perform secoto_private.notify_admins_event('payment', 'Virement transporteur à vérifier',
      format('%s € (compte %s) : virement resté en cours plus de 24 h. Vérifiez dans Stripe avant toute nouvelle tentative.',
        to_char(v_bloque.amount_cents / 100.0, 'FM999990D00'), v_bloque.connected_account_id),
      'paiement', 'direct-payout-stuck:' || v_bloque.id::text, v_bloque.id);
  end loop;

  with due as (
    select pp.id
      from public.partner_payouts pp
      left join public.transport_orders o on o.id = pp.order_id
      join public.payments p on p.id = coalesce(o.payment_id, (
             select p2.id from public.payments p2
              where pp.order_id is null and p2.mission_id = pp.mission_id
                and p2.purpose = 'devis_course' and p2.payment_circuit = 'direct'
              order by p2.paid_at desc nulls last limit 1))
     where pp.payment_circuit = 'direct'
       and (
             (pp.status = 'to_pay' and pp.due_at <= now() and coalesce(pp.next_retry_at, now()) <= now())
          or (pp.status = 'processing' and pp.processing_at < now() - interval '15 minutes')
           )
       and pp.amount_cents > 0
       and pp.connected_account_id is not null
       -- Course remboursée : plus rien à verser. Seule la part retenue d'une
       -- annulation tardive part malgré le remboursement partiel.
       and (p.status = 'paid' or (pp.kind = 'late_cancel' and p.status in ('paid', 'refunded', 'refund_pending')))
       and coalesce(p.dispute_status, '') <> 'open'
       -- Mission manuelle : la ligne n'existe qu'une fois la mission livrée.
       and (pp.kind = 'late_cancel' or o.status = 'delivered' or pp.order_id is null)
       -- Commande de plusieurs véhicules : la paie couvre tous les véhicules,
       -- elle n'est virée qu'une fois TOUS livrés (ou annulés).
       and (pp.kind = 'late_cancel' or pp.order_id is null or not exists (
             select 1 from public.missions s
              where s.groupage_order_id = pp.order_id and s.id <> pp.mission_id
                and s.cancelled_at is null
                and not (coalesce(s.progress_status, '') in ('delivery_completed', 'completed') or s.status::text = 'completed')))
     order by pp.due_at
     limit greatest(1, least(coalesce(p_limit, 20), 100))
     for update of pp skip locked
  ), reserve as (
    update public.partner_payouts pp
       set status = 'processing', processing_at = now(), attempt_count = pp.attempt_count + 1
      from due where pp.id = due.id
    returning pp.*
  )
  select coalesce(jsonb_agg(jsonb_build_object(
      'payout_id', r.id, 'amount_cents', r.amount_cents, 'kind', r.kind,
      'connected_account_id', r.connected_account_id,
      'order_id', r.order_id, 'mission_id', r.mission_id, 'attempt', r.attempt_count)), '[]'::jsonb)
    into v_rows
    from reserve r;
  return v_rows;
end;
$f$;
revoke all on function public.secoto_direct_payouts_claim_due(integer) from public, anon, authenticated;
grant execute on function public.secoto_direct_payouts_claim_due(integer) to service_role;

notify pgrst, 'reload schema';
