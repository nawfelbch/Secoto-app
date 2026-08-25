// ============================================================================
// SECOTO — Paiement intégré (Stripe).
// ----------------------------------------------------------------------------
//  PLATEAU / MOTO : le client règle la commission de 20 % dès la signature du
//  devis. C'est cet encaissement — et lui seul — qui libère le bon de mission
//  vers le transporteur. Le prix du transport ne transite jamais par SECOTO.
//
//  CONVOYAGE : aucun paiement à la réservation. Le règlement de la totalité
//  intervient à la livraison, via un lien de paiement déclenché depuis l'app.
//  Le convoyeur n'encaisse jamais en direct : l'argent arrive chez SECOTO.
//
//  Aucun achat intégré (StoreKit / Play Billing) : ce sont des services du
//  monde réel consommés hors de l'application, explicitement exclus de
//  l'obligation d'achat intégré côté Apple comme côté Google.
//
//  Le montant n'est JAMAIS transmis par le téléphone : la base crée la ligne
//  de paiement, la fonction Netlify relit le montant, Stripe encaisse, et le
//  webhook signé est le seul à pouvoir déclarer l'encaissement.
// ============================================================================

import { Capacitor } from "@capacitor/core";
import { supabase } from "../supabaseClient";
import { randomIdempotencyKey } from "./fileSafety";
import { getServerFunctionUrl } from "../platform/runtime";
import { humanizeError } from "./humanError";

export const PAYMENT_STATUS_LABEL = {
  not_required: "Aucun paiement requis",
  awaiting_payment: "En attente de paiement",
  paid: "Payé",
  failed: "Paiement échoué",
  refunded: "Remboursé",
  cancelled: "Annulé",
};

function platform() {
  return Capacitor.isNativePlatform() ? Capacitor.getPlatform() : "web";
}

export function paymentFromDb(row) {
  if (!row) return null;
  return {
    id: row.id,
    missionId: row.mission_id,
    accountId: row.account_id,
    purpose: row.purpose,
    amount: Number(row.amount_cents || 0) / 100,
    amountCents: row.amount_cents,
    currency: row.currency,
    status: row.status,
    waiverRequired: row.waiver_required,
    waiverAccepted: row.waiver_accepted,
    paidAt: row.paid_at,
    lastError: row.last_error,
    createdAt: row.created_at,
  };
}

/** Prépare (ou retrouve) le paiement de commission d'une mission plateau. */
export async function prepareCommissionPayment(missionId) {
  const { data, error } = await supabase.rpc("secoto_prepare_commission_payment", {
    p_mission_id: missionId,
    p_idempotency_key: randomIdempotencyKey(),
  });
  if (error) throw new Error(explain(error));
  return data;
}

/** Prépare le règlement du convoyage, déclenché à la livraison. */
export async function prepareDeliveryPayment(missionId) {
  const { data, error } = await supabase.rpc("secoto_prepare_delivery_payment", {
    p_mission_id: missionId,
    p_idempotency_key: randomIdempotencyKey(),
  });
  if (error) throw new Error(explain(error));
  return data;
}

/**
 * Enregistre la double mention cochée par le client.
 * L'appelant DOIT s'assurer que la case a été cochée par l'utilisateur :
 * une case pré-cochée annule juridiquement la renonciation.
 */
export async function acceptPaymentWaiver(paymentId) {
  const { data, error } = await supabase.rpc("secoto_accept_payment_waiver", {
    p_payment_id: paymentId,
  });
  if (error) throw new Error(explain(error));
  return Array.isArray(data) ? data[0] : data;
}

export async function fetchPayment(paymentId) {
  const { data, error } = await supabase
    .from("payments")
    .select("id,mission_id,account_id,purpose,amount_cents,currency,status,waiver_required,waiver_accepted,paid_at,last_error,created_at")
    .eq("id", paymentId)
    .single();
  if (error) throw new Error(explain(error));
  return paymentFromDb(data);
}

/** Suit en temps réel le passage du paiement à « payé ». */
export function watchPayment(paymentId, onChange) {
  const channel = supabase
    .channel(`payment-${paymentId}`)
    .on(
      "postgres_changes",
      { event: "UPDATE", schema: "public", table: "payments", filter: `id=eq.${paymentId}` },
      (message) => onChange(paymentFromDb(message.new)),
    )
    .subscribe();
  return () => { supabase.removeChannel(channel); };
}

async function requestIntent(paymentId) {
  const { data: sessionData } = await supabase.auth.getSession();
  const accessToken = sessionData?.session?.access_token;
  if (!accessToken) throw new Error("Session expirée. Reconnectez-vous puis réessayez.");

  const result = await fetch(getServerFunctionUrl("create-payment-intent"), {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${accessToken}`,
    },
    body: JSON.stringify({ paymentId, platform: platform() }),
  });

  const body = await result.json().catch(() => ({}));
  if (result.status === 428 || body.error === "waiver_required") {
    throw new Error(
      "Cochez la case de demande d'exécution immédiate avant de régler.",
    );
  }
  if (result.status === 409 && body.error === "already_paid") {
    return { alreadyPaid: true };
  }
  if (result.status === 409 && body.error === "payment_not_payable") {
    throw new Error("Ce paiement n’est plus actif. Rechargez la mission pour réessayer.");
  }
  if (!result.ok) {
    throw new Error("Le service de paiement est momentanément indisponible.");
  }
  return body;
}

/**
 * Règlement effectif.
 *  - iOS / Android : feuille de paiement native Stripe (Apple Pay, Google Pay,
 *    cartes enregistrées) via @capacitor-community/stripe.
 *  - Web : session Stripe Checkout hébergée.
 * Retourne { ok, pending } — « pending » signifie que l'encaissement sera
 * confirmé par le webhook, jamais par le téléphone.
 */
export async function payNow(paymentId) {
  const intent = await requestIntent(paymentId);
  if (intent.alreadyPaid) return { ok: true, pending: false };

  if (intent.mode === "checkout") {
    if (!intent.checkoutUrl) throw new Error("Session de paiement indisponible.");
    window.location.assign(intent.checkoutUrl);
    return { ok: true, pending: true };
  }

  const { Stripe: StripePlugin } = await import("@capacitor-community/stripe");
  if (!intent.publishableKey) throw new Error("Paiement non configuré.");

  await StripePlugin.initialize({
    publishableKey: intent.publishableKey,
    enableGooglePay: platform() === "android",
  });

  const customerOptions = intent.ephemeralKey
    ? {
        customerId: intent.customerId,
        customerEphemeralKeySecret: intent.ephemeralKey,
      }
    : {};

  await StripePlugin.createPaymentSheet({
    paymentIntentClientSecret: intent.clientSecret,
    ...customerOptions,
    merchantDisplayName: "SECOTO",
    countryCode: "FR",
    // Apple Pay exige un merchant identifier déclaré dans le compte développeur
    // ET l'entitlement com.apple.developer.in-app-payments côté iOS.
    applePayMerchantId: import.meta.env.VITE_APPLE_PAY_MERCHANT_ID || undefined,
    enableApplePay: platform() === "ios" && Boolean(import.meta.env.VITE_APPLE_PAY_MERCHANT_ID),
    enableGooglePay: platform() === "android",
    googlePayIsTesting: false,
  });

  const outcome = await StripePlugin.presentPaymentSheet();
  const value = outcome?.paymentResult;

  if (value === "paymentSheetCompleted") {
    // Le statut « payé » n'est écrit que par le webhook signé : on affiche une
    // confirmation en attente et on écoute la base.
    return { ok: true, pending: true };
  }
  if (value === "paymentSheetCanceled") {
    return { ok: false, pending: false, cancelled: true };
  }
  throw new Error("Le paiement n'a pas abouti. Aucun montant n'a été prélevé.");
}

function explain(error) {
  return humanizeError(error, "Le paiement est momentanément indisponible. Réessayez dans un instant.");
}
