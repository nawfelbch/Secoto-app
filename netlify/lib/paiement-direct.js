// SECOTO — paiement direct au transporteur (plateau et moto, migration 074).
// ----------------------------------------------------------------------------
// Le client est débité SUR LE COMPTE STRIPE DU TRANSPORTEUR (« direct charge »).
// Seule la commission SECOTO (application_fee_amount) arrive chez SECOTO.
// Les montants viennent toujours de la base (secoto_direct_charge_context),
// jamais du téléphone ni du transporteur.
//
// Versement (076, décision D3) : le prix du transport reste sur le solde
// Stripe DU TRANSPORTEUR jusqu'à la livraison validée ; la maintenance vire
// ensuite ce montant vers SA banque (compte en virement « manuel »), 4 h après
// la livraison. La commission SECOTO est prélevée par Stripe au débit du
// client. Aucun Transfer : l'argent du transport ne passe jamais par SECOTO.
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

/**
 * 076 — Virements bancaires du circuit direct : solde Stripe du transporteur
 * vers SA banque, à l'échéance (livraison + 4 h, ou annulation tardive).
 * Fonds pas encore disponibles chez Stripe : nouvel essai automatique
 * (secoto_payout_transfer_result gère l'attente, 6 h entre deux essais).
 */
export async function processDirectPayouts({ admin, stripe }) {
  const report = [];
  const { data: due, error } = await admin.rpc("secoto_direct_payouts_claim_due", { p_limit: 20 });
  if (error) return [{ error: error.message }];
  for (const p of due || []) {
    try {
      const payout = await stripe.payouts.create(
        {
          amount: p.amount_cents,
          currency: "eur",
          description: p.kind === "late_cancel" ? "SECOTO — frais d'annulation" : "SECOTO — mission livrée",
          metadata: { secoto_payout_id: p.payout_id, secoto_order_id: p.order_id || "", secoto_mission_id: p.mission_id || "" },
        },
        { stripeAccount: p.connected_account_id, idempotencyKey: `secoto-direct-payout-${p.payout_id}-${p.amount_cents}` },
      );
      await admin.rpc("secoto_payout_transfer_result", {
        p_payout_id: p.payout_id, p_success: true, p_transfer_id: payout.id, p_charge_id: null, p_error: null,
      });
      report.push({ payout: p.payout_id, outcome: "paid", stripe: payout.id });
    } catch (err) {
      await admin.rpc("secoto_payout_transfer_result", {
        p_payout_id: p.payout_id, p_success: false, p_transfer_id: null, p_charge_id: null,
        p_error: [err?.code, err?.message || "payout_failed"].filter(Boolean).join(" · ").slice(0, 500),
      });
      report.push({ payout: p.payout_id, outcome: "error" });
    }
  }
  return report;
}

/** 076 — Transfers de l'ancien circuit reçus par un compte en virement manuel : vers sa banque. */
export async function processBankPayouts({ admin, stripe }) {
  const report = [];
  const { data: due, error } = await admin.rpc("secoto_bank_payouts_claim_due", { p_limit: 20 });
  if (error) return [{ error: error.message }];
  for (const b of due || []) {
    try {
      const payout = await stripe.payouts.create(
        { amount: b.amount_cents, currency: "eur", description: "SECOTO — rémunération de mission", metadata: { secoto_bank_payout_id: b.bank_payout_id } },
        { stripeAccount: b.connected_account_id, idempotencyKey: `secoto-bank-payout-${b.bank_payout_id}` },
      );
      await admin.rpc("secoto_bank_payout_result", { p_id: b.bank_payout_id, p_success: true, p_stripe_payout_id: payout.id, p_error: null });
      report.push({ bank_payout: b.bank_payout_id, outcome: "paid" });
    } catch (err) {
      await admin.rpc("secoto_bank_payout_result", {
        p_id: b.bank_payout_id, p_success: false, p_stripe_payout_id: null,
        p_error: [err?.code, err?.message].filter(Boolean).join(" · ").slice(0, 500),
      });
      report.push({ bank_payout: b.bank_payout_id, outcome: "error" });
    }
  }
  return report;
}
