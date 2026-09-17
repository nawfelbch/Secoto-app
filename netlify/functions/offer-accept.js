import { withLambda } from "@netlify/aws-lambda-compat";
// SECOTO — acceptation d'une mission par un partenaire (ou attribution admin).
// ----------------------------------------------------------------------------
// 1. Verrou atomique en base (une seule acceptation gagne).
// 2. Si le paiement est seulement AUTORISÉ : capture Stripe immédiate.
// 3. La mission n'est confirmée qu'après capture réussie. En cas d'échec, le
//    verrou est libéré et la commande redevient disponible.
// Une erreur réseau pendant la capture ne tranche rien : le verrou expire et
// « od-maintenance » vérifie l'état réel chez Stripe.
import Stripe from "stripe";
import { UUID_PATTERN, authenticatedUserId, bearer, json, parseBody, serviceClient, userClient } from "../lib/secoto-server.js";

const DECLINE_CODES = new Set(["card_declined", "expired_card", "insufficient_funds", "payment_intent_unexpected_state", "authentication_required"]);

export async function captureForOrder({ admin, stripe, orderId, paymentId }) {
  const { data: payment } = await admin.from("payments").select("id,provider_intent_id,status").eq("id", paymentId).single();
  if (!payment?.provider_intent_id) {
    await admin.rpc("secoto_od_capture_result", { p_order_id: orderId, p_success: false, p_error: "intent_absent" });
    return { result: "capture_failed" };
  }
  try {
    let intent = await stripe.paymentIntents.retrieve(payment.provider_intent_id);
    if (intent.status === "requires_capture") {
      intent = await stripe.paymentIntents.capture(intent.id, {}, { idempotencyKey: `secoto-capture-${payment.id}` });
    }
    if (intent.status === "succeeded") {
      const { data } = await admin.rpc("secoto_od_capture_result", { p_order_id: orderId, p_success: true, p_error: null });
      return data;
    }
    if (intent.status === "processing") return { result: "pending_capture" };
    const { data } = await admin.rpc("secoto_od_capture_result", { p_order_id: orderId, p_success: false, p_error: `intent_${intent.status}` });
    return data;
  } catch (error) {
    if (error?.type === "StripeCardError" || DECLINE_CODES.has(error?.code)) {
      const { data } = await admin.rpc("secoto_od_capture_result", { p_order_id: orderId, p_success: false, p_error: error.code || "card_error" });
      return data;
    }
    return { result: "pending_capture", retry: true };
  }
}

const handler = async (event) => {
  if (event.httpMethod !== "POST") return json(405, { error: "method_not_allowed" });
  const admin = serviceClient();
  if (!admin || !process.env.STRIPE_SECRET_KEY || !process.env.SUPABASE_ANON_KEY) return json(503, { error: "server_not_configured" });
  const token = bearer(event);
  const userId = await authenticatedUserId(token);
  if (!userId) return json(401, { error: "unauthorized" });
  const body = parseBody(event);
  if (!body) return json(400, { error: "invalid_json" });
  const asUser = userClient(token);

  let rpc;
  if (body.offerId) {
    if (!UUID_PATTERN.test(body.offerId) || !UUID_PATTERN.test(body.idempotencyKey || "")) return json(400, { error: "invalid_request" });
    rpc = await asUser.rpc("secoto_offer_accept", { p_offer_id: body.offerId, p_idempotency_key: body.idempotencyKey });
  } else if (body.adminOrderId && body.partnerId) {
    if (!UUID_PATTERN.test(body.adminOrderId) || !UUID_PATTERN.test(body.partnerId)) return json(400, { error: "invalid_request" });
    rpc = await asUser.rpc("secoto_admin_od_lock_for_partner", { p_order_id: body.adminOrderId, p_partner_id: body.partnerId });
  } else {
    return json(400, { error: "invalid_request" });
  }
  if (rpc.error) return json(422, { error: "accept_rejected", message: rpc.error.message });

  let result = rpc.data;
  if (result?.result === "pending_capture") {
    const stripe = new Stripe(process.env.STRIPE_SECRET_KEY);
    result = await captureForOrder({ admin, stripe, orderId: result.order_id, paymentId: result.payment_id });
  }
  // Le partenaire ne reçoit jamais l'identifiant de paiement.
  const safe = { result: result?.result || "unavailable", mission_id: result?.mission_id || null };
  return json(200, safe);
};

export default withLambda(handler);
