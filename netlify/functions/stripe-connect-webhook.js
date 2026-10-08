import { withLambda } from "@netlify/aws-lambda-compat";
// SECOTO — webhook Stripe des COMPTES TRANSPORTEURS (migration 074).
// ----------------------------------------------------------------------------
// En paiement direct, le paiement du client est créé sur le compte Stripe du
// transporteur : ses événements (paiement réussi, remboursement, litige)
// arrivent ici, et non sur le webhook du compte SECOTO. Point d'entrée séparé,
// avec SON PROPRE secret de signature (STRIPE_CONNECT_WEBHOOK_SECRET) :
// le webhook historique reste strictement inchangé.
//
// Les événements sont appliqués par les MÊMES fonctions de base que le
// circuit historique (idempotentes : un événement rejoué n'a aucun effet).
import Stripe from "stripe";
import { createClient } from "@supabase/supabase-js";
import { handleNewFlows, mapStripeEvent } from "./stripe-webhook.js";
import { connectStatusFromAccount } from "./connect-onboarding.js";

const { STRIPE_SECRET_KEY, STRIPE_CONNECT_WEBHOOK_SECRET, SUPABASE_SERVICE_ROLE_KEY, SUPABASE_URL } = process.env;

function response(statusCode, body) {
  return {
    statusCode,
    headers: { "Cache-Control": "no-store", "Content-Type": "application/json; charset=utf-8" },
    body: JSON.stringify(body),
  };
}

function rawBody(event) {
  if (!event.body) return Buffer.alloc(0);
  return event.isBase64Encoded ? Buffer.from(event.body, "base64") : Buffer.from(event.body, "utf8");
}

// Capacités du compte transporteur, recopiées dès que Stripe les change.
export async function syncConnectedAccount(admin, acct) {
  if (!acct?.id) return null;
  const s = connectStatusFromAccount(acct);
  const { error } = await admin.from("accounts").update({
    stripe_connect_status: s.status,
    stripe_transfers_enabled: s.transfers_enabled,
    stripe_payouts_enabled: s.payouts_enabled,
    stripe_card_payments_enabled: s.card_payments_enabled,
    stripe_payouts_manual: s.payouts_manual,
    stripe_connect_updated_at: new Date().toISOString(),
  }).eq("stripe_connect_account_id", acct.id);
  return error ? null : s;
}

export async function handleConnectEvent(admin, stripeEvent) {
  // Un événement de compte connecté porte toujours l'identifiant du compte.
  if (!stripeEvent.account) return response(200, { ignored: "not_connect_event" });

  if (stripeEvent.type === "account.updated") {
    const s = await syncConnectedAccount(admin, stripeEvent.data?.object);
    return response(200, { ok: true, account: s?.status || null });
  }

  // Seuls les paiements créés par SECOTO (métadonnée secoto_payment_id ou
  // paiement connu en base) sont traités ; le reste est acquitté sans effet.
  const handled = await handleNewFlows(admin, stripeEvent);
  if (handled) return handled;

  // 077 : lien de devis d'une mission manuelle payé directement chez le
  // transporteur. Même traitement que l'ancien encaissement (bon de mission
  // libéré, devis signé), mais uniquement pour un paiement du circuit direct
  // créé par SECOTO.
  const status = mapStripeEvent(stripeEvent.type);
  if (status) {
    const object = stripeEvent.data?.object || {};
    const intentId = object.payment_intent || object.id || null;
    let paymentId = object.metadata?.secoto_payment_id || null;
    if (!paymentId && intentId) {
      const { data } = await admin.from("payments").select("id").eq("provider_intent_id", intentId).maybeSingle();
      paymentId = data?.id || null;
    }
    if (paymentId) {
      const { data: p } = await admin.from("payments")
        .select("id,purpose,payment_circuit,connected_account_id").eq("id", paymentId).maybeSingle();
      if (p && p.purpose === "devis_course" && p.payment_circuit === "direct" && p.connected_account_id === stripeEvent.account) {
        const { data, error } = await admin.rpc("secoto_settle_payment", {
          p_payment_id: p.id,
          p_provider_intent_id: intentId,
          p_status: status,
          p_provider_event_id: stripeEvent.id,
          p_error: object.last_payment_error?.message || object.failure_message || null,
        });
        if (error) return response(500, { error: "settle_failed" });
        return response(200, { ok: true, result: data });
      }
    }
  }
  return response(200, { ignored: stripeEvent.type });
}

const handler = async (event) => {
  if (event.httpMethod !== "POST") return response(405, { error: "method_not_allowed" });
  if (!STRIPE_SECRET_KEY || !STRIPE_CONNECT_WEBHOOK_SECRET || !SUPABASE_URL || !SUPABASE_SERVICE_ROLE_KEY) {
    return response(503, { error: "server_not_configured" });
  }
  const signature = event.headers?.["stripe-signature"] || event.headers?.["Stripe-Signature"];
  if (!signature) return response(400, { error: "missing_signature" });

  const stripe = new Stripe(STRIPE_SECRET_KEY);
  let stripeEvent;
  try {
    stripeEvent = stripe.webhooks.constructEvent(rawBody(event), signature, STRIPE_CONNECT_WEBHOOK_SECRET);
  } catch {
    return response(400, { error: "invalid_signature" });
  }
  const admin = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  return handleConnectEvent(admin, stripeEvent);
};

export default withLambda(handler);
