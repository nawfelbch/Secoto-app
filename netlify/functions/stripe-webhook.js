import { withLambda } from "@netlify/aws-lambda-compat";
// SECOTO — webhook Stripe.
// ----------------------------------------------------------------------------
// C'est le SEUL déclencheur légitime de l'encaissement : le téléphone ne peut
// pas déclarer un paiement réussi. La signature Stripe est vérifiée sur le
// corps BRUT de la requête, avant toute désérialisation.
//
// L'encaissement effectif de la commission est ce qui libère le bon de mission
// vers le transporteur (RPC secoto_settle_payment -> secoto_release_mission_order).
import Stripe from "stripe";
import { createClient } from "@supabase/supabase-js";

const {
  STRIPE_SECRET_KEY,
  STRIPE_WEBHOOK_SECRET,
  SUPABASE_SERVICE_ROLE_KEY,
  SUPABASE_URL,
} = process.env;

function response(statusCode, body) {
  return {
    statusCode,
    headers: { "Cache-Control": "no-store", "Content-Type": "application/json; charset=utf-8" },
    body: JSON.stringify(body),
  };
}

function rawBody(event) {
  if (!event.body) return Buffer.alloc(0);
  return event.isBase64Encoded
    ? Buffer.from(event.body, "base64")
    : Buffer.from(event.body, "utf8");
}

// Correspondance entre événements Stripe et statuts SECOTO.
export function mapStripeEvent(type) {
  if (type === "payment_intent.succeeded") return "paid";
  if (type === "payment_intent.payment_failed") return "failed";
  if (type === "payment_intent.canceled") return "cancelled";
  if (type === "charge.refunded") return "refunded";
  return null;
}

export const handler = async (event) => {
  if (event.httpMethod !== "POST") return response(405, { error: "method_not_allowed" });
  if (!STRIPE_SECRET_KEY || !STRIPE_WEBHOOK_SECRET || !SUPABASE_URL || !SUPABASE_SERVICE_ROLE_KEY) {
    return response(503, { error: "server_not_configured" });
  }

  const signature = event.headers?.["stripe-signature"] || event.headers?.["Stripe-Signature"];
  if (!signature) return response(400, { error: "missing_signature" });

  const stripe = new Stripe(STRIPE_SECRET_KEY);

  let stripeEvent;
  try {
    stripeEvent = stripe.webhooks.constructEvent(rawBody(event), signature, STRIPE_WEBHOOK_SECRET);
  } catch {
    return response(400, { error: "invalid_signature" });
  }

  const status = mapStripeEvent(stripeEvent.type);
  // Stripe considère un 2xx comme « reçu » : on acquitte les types qui ne nous
  // concernent pas, sinon Stripe les rejoue indéfiniment.
  if (!status) return response(200, { ignored: stripeEvent.type });

  const object = stripeEvent.data?.object || {};
  const intentId = object.payment_intent || object.id || null;
  const paymentId = object.metadata?.secoto_payment_id || null;
  const failureMessage =
    object.last_payment_error?.message || object.failure_message || null;

  const admin = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  // Retrouver la ligne de paiement : par métadonnée, sinon par intent.
  let resolvedPaymentId = paymentId;
  if (!resolvedPaymentId && intentId) {
    const { data } = await admin
      .from("payments")
      .select("id")
      .eq("provider_intent_id", intentId)
      .maybeSingle();
    resolvedPaymentId = data?.id || null;
  }
  if (!resolvedPaymentId) {
    // Rien à rapprocher : on acquitte pour ne pas boucler côté Stripe.
    return response(200, { ignored: "unknown_payment", type: stripeEvent.type });
  }

  const { data, error } = await admin.rpc("secoto_settle_payment", {
    p_payment_id: resolvedPaymentId,
    p_provider_intent_id: intentId,
    p_status: status,
    p_provider_event_id: stripeEvent.id,
    p_error: failureMessage,
  });

  if (error) {
    // 500 -> Stripe rejouera l'événement, et secoto_settle_payment est
    // idempotent grâce à payment_events.provider_event_id.
    return response(500, { error: "settle_failed" });
  }

  return response(200, { ok: true, result: data });
};

export default withLambda(handler);
