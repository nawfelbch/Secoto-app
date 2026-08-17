import { withLambda } from "@netlify/aws-lambda-compat";
// SECOTO — remboursements en attente.
// ----------------------------------------------------------------------------
// Un seul cas déclenche un remboursement automatique : le désistement du
// TRANSPORTEUR sur une mission plateau. La commission est alors remboursée
// INTÉGRALEMENT, sans barème et sans pénalité. Une annulation par le client ne
// crée jamais de ligne 'refund_pending' : la commission n'est pas remboursable.
import Stripe from "stripe";
import { createClient } from "@supabase/supabase-js";

const {
  STRIPE_SECRET_KEY,
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

const handler = async () => {
  if (!STRIPE_SECRET_KEY || !SUPABASE_URL || !SUPABASE_SERVICE_ROLE_KEY) {
    return response(503, { error: "server_not_configured" });
  }

  const admin = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const stripe = new Stripe(STRIPE_SECRET_KEY);

  const { data: rows, error } = await admin
    .from("payments")
    .select("id,provider_intent_id,amount_cents,refunded_amount_cents")
    .eq("status", "refund_pending")
    .not("provider_intent_id", "is", null)
    .order("refund_requested_at", { ascending: true })
    .limit(20);
  if (error) return response(500, { error: "refund_scan_failed" });

  const results = [];
  for (const row of rows || []) {
    try {
      await stripe.refunds.create(
        {
          payment_intent: row.provider_intent_id,
          reason: "requested_by_customer",
          metadata: { secoto_payment_id: row.id },
        },
        { idempotencyKey: `secoto-refund-${row.id}` },
      );
      // Le passage effectif en 'refunded' est écrit par le webhook
      // charge.refunded, seule source de vérité de l'encaissement.
      results.push({ id: row.id, ok: true });
    } catch (refundError) {
      await admin
        .from("payments")
        .update({
          last_error: String(refundError?.message || "refund_failed").slice(0, 500),
          updated_at: new Date().toISOString(),
        })
        .eq("id", row.id);
      results.push({ id: row.id, ok: false });
    }
  }

  return response(200, { scanned: (rows || []).length, results });
};

export default withLambda(handler);
