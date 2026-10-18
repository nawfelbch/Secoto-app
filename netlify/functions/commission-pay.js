import { withLambda } from "@netlify/aws-lambda-compat";
// SECOTO 100 — Le transporteur règle la marge SECOTO d'une course payée en espèces.
// ----------------------------------------------------------------------------
// Le téléphone n'envoie que l'identifiant de la marge due : le montant restant
// et la propriété sont relus en base (secoto_commission_contexte). Le paiement
// n'est acté que par le webhook Stripe signé (secoto_commission_payee).
import Stripe from "stripe";
import { createClient } from "@supabase/supabase-js";
import { createWithManagedPaymentsFallback, idempotencyKey, withCors } from "../lib/secoto-server.js";
import { urlRetour } from "../lib/retour-app.js";

const {
  STRIPE_SECRET_KEY,
  SUPABASE_ANON_KEY,
  SUPABASE_SERVICE_ROLE_KEY,
  SUPABASE_URL,
  SECOTO_APP_URL = "https://app.secoto-transport.fr",
} = process.env;

const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const PLATEFORMES = new Set(["ios", "android", "web"]);

function response(statusCode, body) {
  return {
    statusCode,
    headers: { "Cache-Control": "no-store", "Content-Type": "application/json; charset=utf-8" },
    body: JSON.stringify(body),
  };
}

export async function sessionCommission({ stripe, ctx, platform, now = Date.now() }) {
  const description = `Marge SECOTO — ${ctx.reference}`;
  const metadata = { secoto_commission_id: ctx.id, secoto_reference: ctx.reference };
  const heure = Math.floor(now / 3600000);
  const expiresAt = Math.floor((heure * 3600000 + 24 * 3600000 - 60000) / 1000);
  return createWithManagedPaymentsFallback((managed) => stripe.checkout.sessions.create(
    {
      ...managed,
      mode: "payment",
      line_items: [{
        price_data: { currency: "eur", unit_amount: ctx.reste_cents, product_data: { name: description } },
        quantity: 1,
      }],
      customer_email: ctx.email || undefined,
      payment_intent_data: { description, metadata },
      metadata,
      expires_at: expiresAt,
      success_url: urlRetour(SECOTO_APP_URL, "ecran=offre&paiement=ok", platform),
      cancel_url: urlRetour(SECOTO_APP_URL, "ecran=offre&paiement=annule", platform),
    },
    { idempotencyKey: idempotencyKey("secoto-commission", ctx.id, { amount: ctx.reste_cents, expiresAt, managed, platform }) },
  ));
}

const handler = async (event) => {
  if (event.httpMethod !== "POST") return response(405, { error: "method_not_allowed" });
  if (!STRIPE_SECRET_KEY || !SUPABASE_URL || !SUPABASE_SERVICE_ROLE_KEY || !SUPABASE_ANON_KEY) {
    return response(503, { error: "server_not_configured" });
  }
  const raw = event.headers?.authorization || event.headers?.Authorization || "";
  const accessToken = raw.startsWith("Bearer ") ? raw.slice(7) : "";
  if (!accessToken) return response(401, { error: "unauthorized" });

  let payload;
  try {
    payload = JSON.parse(event.body || "{}");
  } catch {
    return response(400, { error: "invalid_json" });
  }
  if (!UUID_PATTERN.test(payload.commissionId || "")) return response(400, { error: "invalid_commission_id" });
  const platform = PLATEFORMES.has(payload.platform) ? payload.platform : "web";

  const anon = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, { auth: { persistSession: false, autoRefreshToken: false } });
  const { data: userData, error: userError } = await anon.auth.getUser(accessToken);
  const userId = userData?.user?.id;
  if (userError || !userId) return response(401, { error: "unauthorized" });

  const admin = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, { auth: { persistSession: false, autoRefreshToken: false } });
  const { data: ctx, error } = await admin.rpc("secoto_commission_contexte", { p_commission_id: payload.commissionId, p_account: userId });
  if (error || !ctx) return response(503, { error: "server_not_configured" });
  if (ctx.error === "deja_reglee") return response(409, { error: "already_paid" });
  if (ctx.error || !(ctx.reste_cents > 0)) return response(404, { error: "commission_not_found" });

  try {
    const session = await sessionCommission({ stripe: new Stripe(STRIPE_SECRET_KEY), ctx, platform });
    return response(200, { mode: "checkout", checkoutUrl: session.url, amountCents: ctx.reste_cents });
  } catch {
    return response(502, { error: "stripe_unavailable" });
  }
};

export default withLambda(withCors(handler));
