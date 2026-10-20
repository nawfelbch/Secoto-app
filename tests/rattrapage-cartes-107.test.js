// 107 — carte enregistrée chez Stripe mais webhook manqué : la maintenance la
// rattache (lecture seule chez Stripe), et la page « setup » terminée aussi.
import test from "node:test";
import assert from "node:assert/strict";

process.env.SUPABASE_URL ||= "https://example.invalid";
process.env.SUPABASE_SERVICE_ROLE_KEY ||= "test";

const { rattraperCartes, setupIntentReussi } = await import("../netlify/lib/rattrapage-cartes.js");
const { handleSetupCheckout } = await import("../netlify/functions/stripe-webhook.js");

function fakeAdmin({ payments = [], accounts = [] } = {}) {
  const calls = [];
  return {
    calls,
    rpc: async (name, args) => { calls.push({ name, args }); return { data: { effect: "dispatch_opened" }, error: null }; },
    from: (table) => {
      const filtres = {};
      const rows = () => ({ payments, accounts }[table] || []).filter((r) => Object.entries(filtres).every(([k, v]) => r[k] === v));
      const chain = {
        select: () => chain, eq: (k, v) => { filtres[k] = v; return chain; },
        is: () => chain, not: () => chain, gte: () => chain, order: () => chain,
        limit: async () => ({ data: rows(), error: null }),
        maybeSingle: async () => ({ data: table === "payments" && filtres.setup_intent_id ? null : rows()[0] || null }),
      };
      return chain;
    },
  };
}

test("setupIntentReussi : seul un SetupIntent réussi de CE paiement compte", () => {
  const liste = [
    { id: "seti_a", status: "requires_payment_method", payment_method: null, metadata: { secoto_payment_id: "p1", secoto_circuit: "differe" } },
    { id: "seti_b", status: "succeeded", payment_method: "pm_x", metadata: { secoto_payment_id: "p2", secoto_circuit: "differe" } },
    { id: "seti_c", status: "succeeded", payment_method: "pm_1", created: 5, metadata: { secoto_payment_id: "p1", secoto_circuit: "differe" } },
  ];
  assert.equal(setupIntentReussi(liste, "p1").id, "seti_c");
  assert.equal(setupIntentReussi(liste, "p3"), null);
});

test("rattrapage : carte enregistrée -> rattachée, aucun débit ni création chez Stripe", async () => {
  const admin = fakeAdmin({
    payments: [{ id: "p1", account_id: "a1", status: "processing", debit_a_confirmation: true, payment_circuit: null }],
    accounts: [{ id: "a1", stripe_customer_id: "cus_1" }],
  });
  const appels = [];
  const stripe = new Proxy({}, { get: (_, res) => new Proxy({}, { get: (_, m) => async (...a) => {
    appels.push(`${String(res)}.${String(m)}`);
    return { data: [{ id: "seti_ok", status: "succeeded", payment_method: "pm_9", metadata: { secoto_payment_id: "p1", secoto_circuit: "differe" } }] };
  } }) });
  const r = await rattraperCartes({ admin, stripe });
  assert.deepEqual(appels, ["setupIntents.list"], "lecture seule");
  assert.equal(r.rattaches.length, 1);
  const rpc = admin.calls.find((c) => c.name === "secoto_direct_card_saved");
  assert.deepEqual(rpc.args, { p_payment_id: "p1", p_event_id: "rattrapage:seti_ok", p_setup_intent_id: "seti_ok", p_payment_method_id: "pm_9" });
});

test("rattrapage : paiement hors circuit carte enregistrée ignoré", async () => {
  const admin = fakeAdmin({ payments: [{ id: "p1", account_id: "a1", status: "processing", debit_a_confirmation: false, payment_circuit: null }] });
  const r = await rattraperCartes({ admin, stripe: {} });
  assert.equal(r.verifies, 0);
});

test("webhook checkout.session.completed (setup) -> carte rattachée", async () => {
  const admin = fakeAdmin();
  const stripe = { setupIntents: { retrieve: async () => ({ id: "seti_w", status: "succeeded", payment_method: "pm_w", metadata: { secoto_payment_id: "p1", secoto_circuit: "differe" } }) } };
  const res = await handleSetupCheckout(admin, stripe, { id: "evt_cs", type: "checkout.session.completed", data: { object: { mode: "setup", setup_intent: "seti_w" } } });
  assert.equal(res.statusCode, 200);
  const rpc = admin.calls.find((c) => c.name === "secoto_direct_card_saved");
  assert.equal(rpc.args.p_setup_intent_id, "seti_w");
  assert.equal(rpc.args.p_payment_method_id, "pm_w");
});
