import { withLambda } from "@netlify/aws-lambda-compat";
// SECOTO — maintenance des commandes à la demande (chaque minute).
//  • expiration des devis et des offres, nouveaux tours de diffusion,
//    passage « aucun partenaire » ;
//  • verrous de capture expirés : décision selon l'état RÉEL chez Stripe ;
//  • libération des autorisations et remboursements intégraux demandés ;
//  • abonnements : suspension après délai de grâce ;
//  • versements transporteurs dus : Stripe Transfer vers le compte Connect
//    (migration 036, interrupteur connect_payouts).
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

  // Relance des commissions reglees en especes : la base decide seule si
  // l'echeance est atteinte, la maintenance ne fait que lui donner la main.
  const relances = await admin.rpc("secoto_commission_relances");
  report.commissions = relances.error ? { error: relances.error.message } : relances.data;

  const sub = await admin.rpc("secoto_sub_maintenance_tick");
  report.subscriptions = sub.error ? { error: sub.error.message } : sub.data;
  report.payouts = await processPayouts({ admin, stripe });
  return report;
}

// ---------------------------------------------------------------------------
// Versements transporteurs (charges et transferts séparés).
// La base réserve atomiquement les versements dus (secoto_payouts_claim_due) :
// deux exécutions simultanées ne traitent jamais le même. Le montant est celui
// de partner_payouts, jamais recalculé ici. La clé d'idempotence porte le
// montant : une reprise après incident renvoie le même transfert, une
// correction de montant par l'admin en crée un nouveau.
// ---------------------------------------------------------------------------
export async function processPayouts({ admin, stripe }) {
  const report = [];
  const { data: due, error } = await admin.rpc("secoto_payouts_claim_due", { p_limit: 20 });
  if (error) return [{ error: error.message }];
  for (const p of due || []) {
    let chargeId = null;
    try {
      if (p.intent_id) {
        // source_transaction attend la CHARGE (ch_…), pas le PaymentIntent :
        // le transfert attend alors que les fonds de ce paiement soient disponibles.
        const intent = await stripe.paymentIntents.retrieve(p.intent_id);
        chargeId = typeof intent.latest_charge === "string" ? intent.latest_charge : intent.latest_charge?.id || null;
        if (!chargeId) throw new Error("Paiement client sans charge Stripe : versement suspendu.");
      }
      const transfer = await stripe.transfers.create(
        {
          amount: p.amount_cents,
          currency: "eur",
          destination: p.destination,
          ...(chargeId ? { source_transaction: chargeId } : {}),
          description: p.kind === "late_cancel" ? "SECOTO — indemnité d'annulation" : "SECOTO — rémunération de mission",
          metadata: {
            secoto_payout_id: p.payout_id,
            secoto_order_id: p.order_id || "",
            secoto_mission_id: p.mission_id || "",
            secoto_kind: p.kind || "mission",
          },
        },
        { idempotencyKey: `secoto-partner-payout-${p.payout_id}-${p.amount_cents}` },
      );
      await admin.rpc("secoto_payout_transfer_result", {
        p_payout_id: p.payout_id, p_success: true, p_transfer_id: transfer.id, p_charge_id: chargeId, p_error: null,
      });
      report.push({ payout: p.payout_id, outcome: "paid", transfer: transfer.id });
    } catch (stripeError) {
      await admin.rpc("secoto_payout_transfer_result", {
        p_payout_id: p.payout_id, p_success: false, p_transfer_id: null, p_charge_id: chargeId,
        // Le code Stripe voyage avec le message : la base distingue ainsi une
        // attente de fonds (balance_insufficient) d'un vrai refus.
        p_error: [stripeError?.code, stripeError?.message || "transfer_failed"].filter(Boolean).join(" · ").slice(0, 500),
      });
      report.push({ payout: p.payout_id, outcome: "error" });
    }
  }
  return report;
}

const handler = async () => {
  const admin = serviceClient();
  if (!admin || !process.env.STRIPE_SECRET_KEY) return json(503, { error: "server_not_configured" });
  const report = await runMaintenance({ admin, stripe: new Stripe(process.env.STRIPE_SECRET_KEY) });
  return json(report.error ? 500 : 200, report);
};

export default withLambda(handler);
