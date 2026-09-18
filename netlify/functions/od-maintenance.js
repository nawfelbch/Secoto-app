import { withLambda } from "@netlify/aws-lambda-compat";
// SECOTO — maintenance des commandes à la demande (chaque minute).
//  • expiration des devis et des offres, nouveaux tours de diffusion,
//    passage « aucun partenaire » ;
//  • verrous de capture expirés : décision selon l'état RÉEL chez Stripe ;
//  • libération des autorisations et remboursements intégraux demandés ;
//  • abonnements : suspension après délai de grâce.
import Stripe from "stripe";
import { json, serviceClient } from "../lib/secoto-server.js";
import { captureForOrder } from "./offer-accept.js";

export async function runMaintenance({ admin, stripe }) {
  const report = { locks: [], actions: [] };
  const { data: tick, error } = await admin.rpc("secoto_od_maintenance_tick");
  if (error) return { error: "tick_failed", message: error.message };
  Object.assign(report, { expired_quotes: tick.expired_quotes, rebroadcast: tick.rebroadcast, no_partner: tick.no_partner });

  for (const lock of tick.expired_locks || []) {
    if (lock.funding !== "card" || !lock.intent_id) {
      const { data } = await admin.rpc("secoto_od_expire_lock", { p_order_id: lock.order_id });
      report.locks.push({ order: lock.order_id, outcome: data?.result });
      continue;
    }
    const outcome = await captureForOrder({ admin, stripe, orderId: lock.order_id, paymentId: lock.payment_id });
    report.locks.push({ order: lock.order_id, outcome: outcome?.result });
  }

  for (const action of tick.payment_actions || []) {
    try {
      if (!action.intent_id) {
        await admin.rpc("secoto_od_payment_action_result", { p_payment_id: action.payment_id, p_action: action.action, p_success: true, p_error: null });
      } else if (action.action === "refund") {
        await stripe.refunds.create(
          { payment_intent: action.intent_id, amount: action.amount_cents, reason: "requested_by_customer", metadata: { secoto_payment_id: action.payment_id } },
          // La clé porte le montant : un remboursement partiel (annulation
          // tardive) et un remboursement du solde restent deux opérations.
          { idempotencyKey: `secoto-od-refund-${action.payment_id}-${action.amount_cents}` },
        );
        await admin.rpc("secoto_od_payment_action_result", { p_payment_id: action.payment_id, p_action: "refund", p_success: true, p_error: null });
      } else {
        const intent = await stripe.paymentIntents.retrieve(action.intent_id);
        if (["requires_payment_method", "requires_capture", "requires_confirmation", "requires_action", "processing"].includes(intent.status)) {
          await stripe.paymentIntents.cancel(intent.id, {}, { idempotencyKey: `secoto-od-cancel-${action.payment_id}` });
        } else if (intent.status === "succeeded") {
          // Encaissé entre-temps : on rembourse intégralement plutôt que d'annuler.
          await stripe.refunds.create(
            { payment_intent: intent.id, amount: action.amount_cents || undefined, reason: "requested_by_customer", metadata: { secoto_payment_id: action.payment_id } },
            { idempotencyKey: `secoto-od-refund-${action.payment_id}-${action.amount_cents || "all"}` });
          await admin.rpc("secoto_od_payment_action_result", { p_payment_id: action.payment_id, p_action: "refund", p_success: true, p_error: null });
          report.actions.push({ payment: action.payment_id, outcome: "refunded_after_success" });
          continue;
        }
        await admin.rpc("secoto_od_payment_action_result", { p_payment_id: action.payment_id, p_action: "cancel", p_success: true, p_error: null });
      }
      report.actions.push({ payment: action.payment_id, outcome: action.action });
    } catch (stripeError) {
      await admin.rpc("secoto_od_payment_action_result", { p_payment_id: action.payment_id, p_action: action.action, p_success: false, p_error: String(stripeError?.message || "stripe_error") });
      report.actions.push({ payment: action.payment_id, outcome: "error" });
    }
  }

  const sub = await admin.rpc("secoto_sub_maintenance_tick");
  report.subscriptions = sub.error ? { error: sub.error.message } : sub.data;
  return report;
}

const handler = async () => {
  const admin = serviceClient();
  if (!admin || !process.env.STRIPE_SECRET_KEY) return json(503, { error: "server_not_configured" });
  const report = await runMaintenance({ admin, stripe: new Stripe(process.env.STRIPE_SECRET_KEY) });
  return json(report.error ? 500 : 200, report);
};

export default withLambda(handler);
