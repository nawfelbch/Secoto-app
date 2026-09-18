import { withLambda } from "@netlify/aws-lambda-compat";
// SECOTO — paiement récurrent de l'abonnement professionnel (Stripe Billing).
// Le montant vient de la proposition ACCEPTÉE en base, jamais du téléphone.
import { createHash } from "node:crypto";
import Stripe from "stripe";
import { UUID_PATTERN, authenticatedUserId, bearer, json, parseBody, serviceClient } from "../lib/secoto-server.js";

const { SECOTO_APP_URL = "https://app.secoto-transport.fr" } = process.env;

const {
  STRIPE_TAX_CODE = "txcd_20030000",
  STRIPE_AUTOMATIC_TAX = "false",
} = process.env;
const AUTOMATIC_TAX_ENABLED = String(STRIPE_AUTOMATIC_TAX).toLowerCase() === "true";

// Voir create-payment-intent : l'empreinte des parametres evite qu'un
// abonnement reste bloque apres un changement de prix ou de fiscalite.
function idempotencyKey(prefix, id, params) {
  const empreinte = createHash("sha256").update(JSON.stringify(params)).digest("hex").slice(0, 16);
  return `${prefix}-${id}-${empreinte}`;
}

const handler = async (event) => {
  if (event.httpMethod !== "POST") return json(405, { error: "method_not_allowed" });
  const admin = serviceClient();
  if (!admin || !process.env.STRIPE_SECRET_KEY || !process.env.SUPABASE_ANON_KEY) return json(503, { error: "server_not_configured" });
  const userId = await authenticatedUserId(bearer(event));
  if (!userId) return json(401, { error: "unauthorized" });
  const body = parseBody(event);
  if (!body || !UUID_PATTERN.test(body.subscriptionId || "")) return json(400, { error: "invalid_request" });

  const { data: flag } = await admin.from("secoto_feature_flags").select("enabled").eq("key", "subscriptions").maybeSingle();
  if (!flag?.enabled) return json(403, { error: "subscriptions_disabled" });

  const { data: sub } = await admin.from("subscriptions").select("id,business_id,proposal_id,status,stripe_subscription_id,cancel_at_period_end").eq("id", body.subscriptionId).maybeSingle();
  if (!sub) return json(404, { error: "not_found" });
  const { data: member } = await admin.from("business_members").select("role").eq("business_id", sub.business_id).eq("account_id", userId).maybeSingle();
  if (member?.role !== "owner") return json(403, { error: "forbidden" });
  const stripe = new Stripe(process.env.STRIPE_SECRET_KEY);

  if (body.action === "cancel_at_period_end") {
    if (!sub.stripe_subscription_id) return json(409, { error: "no_active_billing" });
    await stripe.subscriptions.update(sub.stripe_subscription_id, { cancel_at_period_end: true });
    return json(200, { ok: true });
  }

  if (sub.status !== "pending_payment") return json(409, { error: "already_started" });
  const { data: proposal } = await admin.from("subscription_proposals").select("id,monthly_price_cents,business_id,status").eq("id", sub.proposal_id).single();
  if (!proposal || proposal.status !== "accepted") return json(409, { error: "proposal_not_accepted" });
  const { data: account } = await admin.from("accounts").select("id,email,full_name,stripe_customer_id").eq("id", userId).single();
  let customerId = account?.stripe_customer_id || null;
  if (!customerId) {
    const customer = await stripe.customers.create(
      { email: account?.email || undefined, name: account?.full_name || undefined, metadata: { secoto_account_id: userId } },
      { idempotencyKey: `secoto-customer-${userId}` },
    );
    customerId = customer.id;
    await admin.from("accounts").update({ stripe_customer_id: customerId }).eq("id", userId);
  }
  const session = await stripe.checkout.sessions.create({
    mode: "subscription",
    customer: customerId,
    line_items: [{
      quantity: 1,
      price_data: {
        currency: "eur",
        unit_amount: proposal.monthly_price_cents,
        recurring: { interval: "month" },
        // Meme exigence que create-payment-intent : Stripe Tax refuse un
        // article sans code fiscal des que le calcul automatique est actif.
        product_data: { name: "SECOTO — abonnement professionnel personnalisé", tax_code: STRIPE_TAX_CODE },
        tax_behavior: AUTOMATIC_TAX_ENABLED ? "inclusive" : undefined,
      },
    }],
    // Franchise en base (article 293 B du CGI) : rien n'est ajoute au prix.
    automatic_tax: { enabled: AUTOMATIC_TAX_ENABLED },
    subscription_data: { metadata: { secoto_subscription_id: sub.id } },
    metadata: { secoto_subscription_id: sub.id },
    success_url: `${SECOTO_APP_URL}/?ecran=abonnement&abonnement=ok`,
    cancel_url: `${SECOTO_APP_URL}/?ecran=abonnement&abonnement=annule`,
  }, {
    idempotencyKey: idempotencyKey("secoto-sub-checkout", `${sub.id}-${proposal.id}`, {
      amount: proposal.monthly_price_cents,
      taxCode: STRIPE_TAX_CODE,
      automaticTax: AUTOMATIC_TAX_ENABLED,
      customerId,
    }),
  });
  return json(200, { checkoutUrl: session.url });
};

export default withLambda(handler);
