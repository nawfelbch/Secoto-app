// SECOTO — paiement direct au transporteur (plateau et moto, migration 074).
// ----------------------------------------------------------------------------
// Le client est débité SUR LE COMPTE STRIPE DU TRANSPORTEUR (« direct charge »).
// Seule la commission SECOTO (application_fee_amount) arrive chez SECOTO.
// Les montants viennent toujours de la base (secoto_direct_charge_context),
// jamais du téléphone ni du transporteur.
//
// Versement : Stripe verse automatiquement au transporteur ce qui est encaissé
// sur son compte ; la commission SECOTO est prélevée au même instant. Aucun
// Transfer, aucun virement à déclencher par SECOTO.
//
// Toutes les opérations Stripe portent une clé d'idempotence stable : une
// reprise après coupure (maintenance, double appui) retrouve le MÊME paiement
// au lieu d'en créer un second.

const CARD_DECLINE_CODES = new Set([
  "card_declined", "expired_card", "insufficient_funds", "incorrect_cvc", "processing_error",
  "payment_intent_unexpected_state", "card_not_supported", "do_not_honor",
]);

export const DIRECT_DESCRIPTION = "Transport de véhicule sur plateau — via SECOTO";

export function isDirect(row) {
  return row?.payment_circuit === "direct" || row?.circuit === "direct";
}

// Erreur Stripe « la banque du client veut une validation » ?
export function needsCustomerAction(error) {
  const intent = error?.raw?.payment_intent || error?.payment_intent;
  return error?.code === "authentication_required"
    || intent?.status === "requires_action"
    || (error?.decline_code === "authentication_required");
}

function isCardError(error) {
  return error?.type === "StripeCardError" || CARD_DECLINE_CODES.has(error?.code) || CARD_DECLINE_CODES.has(error?.decline_code);
}

async function captureResult(admin, orderId, success, motif) {
  const { data } = await admin.rpc("secoto_od_capture_result", { p_order_id: orderId, p_success: success, p_error: motif || null });
  return data || { result: success ? "confirmed" : "capture_failed" };
}

/**
 * Débite le client chez le transporteur qui vient d'accepter, puis confirme
 * (ou libère) la mission. Même contrat que captureForOrder :
 * renvoie { result: "confirmed" | "capture_failed" | "pending_capture" | "needs_action" }.
 */
export async function chargeDirect({ admin, stripe, orderId, now = Date.now() }) {
  const { data: ctx, error } = await admin.rpc("secoto_direct_charge_context", { p_order_id: orderId });
  if (error || !ctx) return { result: "pending_capture", retry: true };
  if (ctx.error) return captureResult(admin, orderId, false, ctx.error);
  if (ctx.order_status !== "partner_locked") return { result: ctx.order_status === "partner_confirmed" ? "confirmed" : "unavailable" };
  if (ctx.payment_status === "paid") return captureResult(admin, orderId, true, null);

  const stripeAccount = ctx.connected_account_id;
  if (!ctx.partner_ready || !stripeAccount) return captureResult(admin, orderId, false, "compte_transporteur_inactif");
  if (!ctx.payment_method_id || !ctx.customer_id) return captureResult(admin, orderId, false, "carte_absente");

  // Le client doit valider lui-même : on attend son paiement (webhook), puis
  // on libère la mission si le délai est dépassé.
  if (ctx.action_required_at) {
    const expire = ctx.lock_expires_at ? Date.parse(ctx.lock_expires_at) : 0;
    if (expire && expire > now) return { result: "needs_action" };
    return captureResult(admin, orderId, false, "validation_bancaire_non_realisee");
  }

  const cles = `${ctx.payment_id}-${stripeAccount}-${ctx.payment_method_id}`;
  try {
    // La carte enregistrée chez SECOTO est recopiée sur le compte du
    // transporteur : le client n'a rien à ressaisir.
    const pm = await stripe.paymentMethods.create(
      { customer: ctx.customer_id, payment_method: ctx.payment_method_id },
      { stripeAccount, idempotencyKey: `secoto-direct-pm-${cles}` },
    );
    const intent = await stripe.paymentIntents.create(
      {
        amount: ctx.amount_cents,
        currency: ctx.currency || "eur",
        payment_method: pm.id,
        payment_method_types: ["card"],
        confirm: true,
        off_session: true,
        application_fee_amount: ctx.application_fee_cents,
        description: `${DIRECT_DESCRIPTION} — commande ${ctx.public_ref}`,
        metadata: {
          secoto_payment_id: ctx.payment_id,
          secoto_order_id: ctx.order_id,
          secoto_purpose: "od_plateau",
          secoto_circuit: "direct",
        },
      },
      { stripeAccount, idempotencyKey: `secoto-direct-charge-${cles}` },
    );
    await admin.from("payments").update({ provider_intent_id: intent.id, updated_at: new Date(now).toISOString() }).eq("id", ctx.payment_id);
    if (intent.status === "succeeded") return captureResult(admin, orderId, true, null);
    if (intent.status === "processing") return { result: "pending_capture" };
    if (intent.status === "requires_action") {
      await cancelQuietly(stripe, intent.id, stripeAccount);
      const { data } = await admin.rpc("secoto_direct_charge_needs_action", { p_order_id: orderId, p_intent_id: null });
      return { result: "needs_action", ...(data || {}) };
    }
    return captureResult(admin, orderId, false, `intent_${intent.status}`);
  } catch (err) {
    if (needsCustomerAction(err)) {
      const failed = err?.raw?.payment_intent?.id;
      if (failed) await cancelQuietly(stripe, failed, stripeAccount);
      const { data } = await admin.rpc("secoto_direct_charge_needs_action", { p_order_id: orderId, p_intent_id: null });
      return { result: "needs_action", ...(data || {}) };
    }
    if (isCardError(err)) return captureResult(admin, orderId, false, err.decline_code || err.code || "card_error");
    // Réseau, Stripe indisponible : rien n'est tranché, la maintenance reprend
    // avec la même clé et retrouve le paiement s'il a été créé.
    return { result: "pending_capture", retry: true };
  }
}

async function cancelQuietly(stripe, intentId, stripeAccount) {
  try {
    await stripe.paymentIntents.cancel(intentId, {}, { stripeAccount });
  } catch {
    // Paiement non annulable (déjà échoué) : sans conséquence, rien n'est débité.
  }
}

/**
 * Remboursement d'un paiement direct : sur le compte du transporteur, la
 * commission SECOTO rendue dans la même proportion (partage au prorata).
 */
export async function refundDirect({ stripe, action }) {
  return stripe.refunds.create(
    {
      payment_intent: action.intent_id,
      amount: action.amount_cents,
      refund_application_fee: true,
      reason: "requested_by_customer",
      metadata: { secoto_payment_id: action.payment_id, secoto_circuit: "direct" },
    },
    { stripeAccount: action.connected_account_id, idempotencyKey: `secoto-direct-refund-${action.payment_id}-${action.amount_cents}` },
  );
}
