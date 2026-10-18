// SECOTO 100 — Règlement à l'arrivée du véhicule.
// ----------------------------------------------------------------------------
// La carte du client est enregistrée à la réservation (0 € prélevé). À la
// livraison, la base fixe l'échéance selon le mode choisi (carte : tout de
// suite ; Klarna : 24 h ; virement : 48 h ; espèces : seulement si le
// transporteur déclare ne pas avoir été payé). Ici, à chaque maintenance :
//  · prélèvement hors session des paiements arrivés à échéance ;
//  · retenue des marges SECOTO impayées sur les versements à venir ;
//  · relance des règlements en espèces non confirmés.
// Montants lus en base, jamais envoyés par le téléphone. Clé d'idempotence
// stable par tentative : une reprise après coupure retrouve le même débit.
import { moyenNonDebitable, needsCustomerAction } from "./paiement-direct.js";

const CARD_DECLINE_CODES = new Set([
  "card_declined", "expired_card", "insufficient_funds", "incorrect_cvc", "processing_error",
  "payment_intent_unexpected_state", "card_not_supported", "do_not_honor",
]);

export const REGLEMENT_DESCRIPTION = "Transport de véhicule — SECOTO";

function isCardError(error) {
  return error?.type === "StripeCardError" || CARD_DECLINE_CODES.has(error?.code) || CARD_DECLINE_CODES.has(error?.decline_code);
}

async function resultat(admin, paymentId, res, intentId, motif) {
  const { data } = await admin.rpc("secoto_reglement_debit_resultat", {
    p_payment_id: paymentId, p_resultat: res, p_intent_id: intentId || null, p_error: motif || null,
  });
  return data?.result || res;
}

async function cancelQuietly(stripe, intentId) {
  try {
    await stripe.paymentIntents.cancel(intentId);
  } catch {
    // Tentative déjà échouée : sans conséquence, rien n'est débité.
  }
}

/** Prélève une ligne réservée par secoto_reglements_a_debiter. */
export async function debiterLivraison({ admin, stripe, ligne }) {
  if (!ligne.customer_id || !ligne.payment_method_id) {
    return resultat(admin, ligne.payment_id, "refuse", null, "carte_absente");
  }
  // Déjà prélevé (webhook perdu, coupure après le débit) : on le constate, on ne redébite pas.
  if (ligne.provider_intent_id) {
    try {
      const deja = await stripe.paymentIntents.retrieve(ligne.provider_intent_id);
      if (deja.status === "succeeded") return resultat(admin, ligne.payment_id, "reussi", deja.id, null);
      if (deja.status === "processing") return "pending";
    } catch {
      // Intention introuvable : on poursuit avec une nouvelle tentative.
    }
  }
  try {
    const intent = await stripe.paymentIntents.create(
      {
        amount: ligne.amount_cents,
        currency: ligne.currency || "eur",
        customer: ligne.customer_id,
        payment_method: ligne.payment_method_id,
        payment_method_types: ["card"],
        confirm: true,
        off_session: true,
        description: `${REGLEMENT_DESCRIPTION} — commande ${ligne.public_ref}`,
        metadata: {
          secoto_payment_id: ligne.payment_id,
          secoto_order_id: ligne.order_id,
          secoto_purpose: ligne.purpose || "od_plateau",
          secoto_circuit: "livraison",
        },
      },
      // Une clé par tentative : après un refus, l'essai suivant est un nouveau débit.
      { idempotencyKey: `secoto-livraison-${ligne.payment_id}-${ligne.payment_method_id}-${ligne.tentative || 0}` },
    );
    await admin.from("payments").update({ provider_intent_id: intent.id, updated_at: new Date().toISOString() }).eq("id", ligne.payment_id);
    if (intent.status === "succeeded") return resultat(admin, ligne.payment_id, "reussi", intent.id, null);
    if (intent.status === "processing") return "pending";
    if (intent.status === "requires_action") {
      await cancelQuietly(stripe, intent.id);
      return resultat(admin, ligne.payment_id, "action", intent.id, "validation_bancaire_demandee");
    }
    return resultat(admin, ligne.payment_id, "refuse", intent.id, `intent_${intent.status}`);
  } catch (err) {
    const failed = err?.raw?.payment_intent?.id;
    if (needsCustomerAction(err) || moyenNonDebitable(err)) {
      if (failed) await cancelQuietly(stripe, failed);
      return resultat(admin, ligne.payment_id, "action", failed, err?.code || "validation_bancaire_demandee");
    }
    if (isCardError(err)) return resultat(admin, ligne.payment_id, "refuse", failed, err.decline_code || err.code || "card_error");
    // Réseau, Stripe indisponible : rien n'est tranché, nouvel essai (même clé).
    return resultat(admin, ligne.payment_id, "reseau", null, String(err?.message || "stripe_error").slice(0, 200));
  }
}

export async function processReglements({ admin, stripe }) {
  const rapport = { debits: [] };
  const { data: lignes, error } = await admin.rpc("secoto_reglements_a_debiter", { p_limit: 20 });
  if (error) {
    rapport.error = error.message;
  } else {
    for (const ligne of lignes || []) {
      const issue = await debiterLivraison({ admin, stripe, ligne });
      rapport.debits.push({ payment: ligne.payment_id, outcome: issue });
    }
  }
  const retenues = await admin.rpc("secoto_commissions_retenir");
  rapport.retenues = retenues.error ? { error: retenues.error.message } : retenues.data;
  const relances = await admin.rpc("secoto_reglement_relances");
  rapport.relances = relances.error ? { error: relances.error.message } : relances.data;
  return rapport;
}
