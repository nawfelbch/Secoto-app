// SECOTO 099 — Débit à la confirmation (trois offres Express / Standard / Éco).
// ----------------------------------------------------------------------------
// Circuit SECOTO habituel, mais décalé dans le temps :
//  · réservation : la carte du client est ENREGISTRÉE (SetupIntent), rien
//    n'est débité ;
//  · un transporteur confirme : débit hors session sur le compte SECOTO, du
//    montant de l'offre choisie (lu en base, jamais envoyé par le téléphone) ;
//  · ensuite tout est inchangé : versement au transporteur après livraison,
//    remboursements éventuels sur le compte SECOTO.
// Si la banque demande une validation (3D Secure), la tentative est annulée,
// le client est prévenu et la mission reste réservée au transporteur le
// temps réglé (24 h par défaut) ; au-delà, elle repart en diffusion.
// Toutes les opérations Stripe portent une clé d'idempotence stable.
import { needsCustomerAction } from "./paiement-direct.js";

const CARD_DECLINE_CODES = new Set([
  "card_declined", "expired_card", "insufficient_funds", "incorrect_cvc", "processing_error",
  "payment_intent_unexpected_state", "card_not_supported", "do_not_honor",
]);

export const DIFFERE_DESCRIPTION = "Mise en relation pour un transport de véhicule — SECOTO";

export function isDiffere(row) {
  return row?.debit_a_confirmation === true || row?.differe === true;
}

function isCardError(error) {
  return error?.type === "StripeCardError" || CARD_DECLINE_CODES.has(error?.code) || CARD_DECLINE_CODES.has(error?.decline_code);
}

async function captureResult(admin, orderId, success, motif) {
  const { data } = await admin.rpc("secoto_od_capture_result", { p_order_id: orderId, p_success: success, p_error: motif || null });
  return data || { result: success ? "confirmed" : "capture_failed" };
}

async function cancelQuietly(stripe, intentId) {
  try {
    await stripe.paymentIntents.cancel(intentId);
  } catch {
    // Tentative déjà échouée : sans conséquence, rien n'est débité.
  }
}

async function needsAction(admin, orderId) {
  const { data } = await admin.rpc("secoto_differe_needs_action", { p_order_id: orderId });
  return { result: "needs_action", ...(data || {}) };
}

/**
 * Débite le client au moment où un transporteur confirme, puis confirme (ou
 * libère) la mission. Même contrat que captureForOrder / chargeDirect :
 * { result: "confirmed" | "capture_failed" | "pending_capture" | "needs_action" | "released" }.
 */
export async function chargeDiffere({ admin, stripe, orderId, now = Date.now() }) {
  const { data: ctx, error } = await admin.rpc("secoto_differe_charge_context", { p_order_id: orderId });
  if (error || !ctx) return { result: "pending_capture", retry: true };
  if (ctx.error) return captureResult(admin, orderId, false, ctx.error);
  if (ctx.order_status !== "partner_locked") return { result: ctx.order_status === "partner_confirmed" ? "confirmed" : "unavailable" };
  if (ctx.payment_status === "paid") return captureResult(admin, orderId, true, null);
  if (!ctx.payment_method_id || !ctx.customer_id) return captureResult(admin, orderId, false, "carte_absente");

  // Validation bancaire demandée : on attend le paiement du client (webhook).
  // Délai dépassé : la mission repart en diffusion, rien n'est débité.
  if (ctx.action_required_at) {
    const expire = ctx.lock_expires_at ? Date.parse(ctx.lock_expires_at) : 0;
    if (expire && expire > now) return { result: "needs_action" };
    const { data } = await admin.rpc("secoto_differe_action_expired", { p_order_id: orderId });
    return { result: data?.result || "released" };
  }

  try {
    const intent = await stripe.paymentIntents.create(
      {
        amount: ctx.amount_cents,
        currency: ctx.currency || "eur",
        customer: ctx.customer_id,
        payment_method: ctx.payment_method_id,
        payment_method_types: ["card"],
        confirm: true,
        off_session: true,
        description: `${DIFFERE_DESCRIPTION} — commande ${ctx.public_ref}`,
        metadata: {
          secoto_payment_id: ctx.payment_id,
          secoto_order_id: ctx.order_id,
          secoto_purpose: "od_plateau",
          secoto_circuit: "differe",
          secoto_offre: ctx.offre || "",
        },
      },
      // Une clé par acceptation : après un refus ou une validation non faite, la
      // confirmation suivante est une nouvelle tentative, pas une rediffusion.
      { idempotencyKey: `secoto-differe-charge-${ctx.payment_id}-${ctx.payment_method_id}-${ctx.lock_offer_id || "admin"}` },
    );
    await admin.from("payments").update({ provider_intent_id: intent.id, updated_at: new Date(now).toISOString() }).eq("id", ctx.payment_id);
    if (intent.status === "succeeded") return captureResult(admin, orderId, true, null);
    if (intent.status === "processing") return { result: "pending_capture" };
    if (intent.status === "requires_action") {
      await cancelQuietly(stripe, intent.id);
      return needsAction(admin, orderId);
    }
    return captureResult(admin, orderId, false, `intent_${intent.status}`);
  } catch (err) {
    if (needsCustomerAction(err)) {
      const failed = err?.raw?.payment_intent?.id;
      if (failed) await cancelQuietly(stripe, failed);
      return needsAction(admin, orderId);
    }
    if (isCardError(err)) return captureResult(admin, orderId, false, err.decline_code || err.code || "card_error");
    // Réseau, Stripe indisponible : rien n'est tranché ; la maintenance
    // reprend avec la même clé et retrouve le paiement s'il a été créé.
    return { result: "pending_capture", retry: true };
  }
}
