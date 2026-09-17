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
import {
  OD_PAYMENT_EVENTS,
  OD_PURPOSES,
  SUBSCRIPTION_EVENTS,
  intentIdFromObject,
  subscriptionEventData,
} from "../lib/secoto-server.js";

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

// Retourne une réponse si l'événement relève des nouveaux parcours, sinon null
// (le traitement historique, inchangé, s'applique alors).
export async function handleNewFlows(admin, stripeEvent) {
  const type = stripeEvent.type;
  const object = stripeEvent.data?.object || {};

  if (SUBSCRIPTION_EVENTS.has(type)) {
    const data = subscriptionEventData(type, object);
    if (!data || (!data.subscriptionId && !data.stripeSubscriptionId)) return null;
    const { data: result, error } = await admin.rpc("secoto_sub_apply_billing_event", {
      p_subscription_id: data.subscriptionId,
      p_event_id: stripeEvent.id,
      p_event_type: type,
      p_stripe_subscription_id: data.stripeSubscriptionId,
      p_period_start: data.periodStart || null,
      p_period_end: data.periodEnd || null,
    });
    if (error) return response(500, { error: "subscription_settle_failed" });
    return response(200, { ok: true, result });
  }

  if (!OD_PAYMENT_EVENTS.has(type)) return null;
  const intentId = intentIdFromObject(type, object);
  let paymentId = type.startsWith("payment_intent.") ? object.metadata?.secoto_payment_id || null : null;
  let purpose = type.startsWith("payment_intent.") ? object.metadata?.secoto_purpose || null : null;
  if ((!paymentId || !purpose) && intentId) {
    const { data } = await admin.from("payments").select("id,purpose").eq("provider_intent_id", intentId).maybeSingle();
    paymentId = paymentId || data?.id || null;
    purpose = purpose || data?.purpose || null;
  }
  if (!paymentId || !OD_PURPOSES.has(purpose)) return null;

  const { data: result, error } = await admin.rpc("secoto_od_apply_payment_event", {
    p_payment_id: paymentId,
    p_event_id: stripeEvent.id,
    p_event_type: type,
    p_intent_id: intentId,
    p_amount_refunded_cents: type === "charge.refunded" ? Number(object.amount_refunded || 0) : 0,
    p_capture_before: object.latest_charge?.payment_method_details?.card?.capture_before
      ? new Date(object.latest_charge.payment_method_details.card.capture_before * 1000).toISOString()
      : null,
    p_error: object.last_payment_error?.message || null,
  });
  // 500 -> Stripe rejoue ; la fonction SQL est idempotente et monotone.
  if (error) return response(500, { error: "settle_failed" });
  return response(200, { ok: true, result });
}

const handler = async (event) => {
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

  const admin = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  // Migration 030-031 : commandes à la demande, extensions, abonnements.
  const handled = await handleNewFlows(admin, stripeEvent);
  if (handled) return handled;

  const status = mapStripeEvent(stripeEvent.type);
  // Stripe considère un 2xx comme « reçu » : on acquitte les types qui ne nous
  // concernent pas, sinon Stripe les rejoue indéfiniment.
  if (!status) return response(200, { ignored: stripeEvent.type });

  const object = stripeEvent.data?.object || {};
  const intentId = object.payment_intent || object.id || null;
  const paymentId = object.metadata?.secoto_payment_id || null;
  const failureMessage =
    object.last_payment_error?.message || object.failure_message || null;

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
