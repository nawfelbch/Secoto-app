// Migration 099 — trois offres et débit à la confirmation : logique serveur
// sans réseau (Stripe et Supabase simulés). Prouve aussi que le paiement
// direct et l'encaissement immédiat appellent Stripe exactement comme avant.
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

process.env.SUPABASE_URL ||= "https://example.invalid";
process.env.SUPABASE_SERVICE_ROLE_KEY ||= "test";
process.env.STRIPE_PUBLISHABLE_KEY ||= "pk_test_x";

const { chargeDiffere, isDiffere } = await import("../netlify/lib/paiement-differe.js");
const { captureForOrder } = await import("../netlify/functions/offer-accept.js");
const { runMaintenance } = await import("../netlify/functions/od-maintenance.js");
const { handleDirectSetup } = await import("../netlify/functions/stripe-webhook.js");
const { directFlow } = await import("../netlify/functions/create-payment-intent.js");

function fakeAdmin({ rpc = {}, tables = {} } = {}) {
  const calls = [];
  const updates = [];
  return {
    calls,
    updates,
    rpc: async (name, args) => {
      calls.push({ name, args });
      const h = rpc[name];
      return h ? h(args) : { data: null, error: null };
    },
    from: (table) => {
      const state = { filters: {}, patch: null };
      const find = () => (tables[table] || []).find((r) => Object.entries(state.filters).every(([k, v]) => r[k] === v)) || null;
      const chain = {
        select: () => chain,
        update: (patch) => { state.patch = patch; return chain; },
        eq: (k, v) => {
          state.filters[k] = v;
          if (state.patch) updates.push({ table, patch: state.patch, filters: { ...state.filters } });
          return chain;
        },
        is: () => chain, not: () => chain, in: () => chain, order: () => chain,
        limit: async () => ({ data: tables[table] || [], error: null }),
        maybeSingle: async () => ({ data: find() }),
        single: async () => ({ data: find() }),
      };
      return chain;
    },
  };
}
function fakeStripe(over = {}) {
  const calls = [];
  const rec = (name, impl) => async (...args) => { calls.push({ name, args }); return impl(...args); };
  return {
    calls,
    paymentMethods: { create: rec("paymentMethods.create", async () => ({ id: "pm_clone" })) },
    paymentIntents: {
      create: rec("paymentIntents.create", over.piCreate || (async () => ({ id: "pi_differe", status: "succeeded" }))),
      retrieve: rec("paymentIntents.retrieve", async () => ({ id: "pi_x", status: "succeeded", amount: 50000 })),
      capture: rec("paymentIntents.capture", async () => ({ id: "pi_x", status: "succeeded" })),
      cancel: rec("paymentIntents.cancel", async () => ({ status: "canceled" })),
    },
    refunds: { create: rec("refunds.create", async () => ({ id: "re_1" })) },
    setupIntents: {
      create: rec("setupIntents.create", async () => ({ id: "seti_1", client_secret: "seti_1_secret", status: "requires_payment_method" })),
      retrieve: rec("setupIntents.retrieve", async () => ({ id: "seti_old", status: "succeeded" })),
    },
    checkout: { sessions: { create: rec("checkout.sessions.create", async () => ({ id: "cs_1", url: "https://checkout.stripe.test/cs_1" })) } },
    ephemeralKeys: { create: rec("ephemeralKeys.create", async () => ({ secret: "ek_1" })) },
  };
}
const ctx = (over = {}) => ({
  order_id: "o1", public_ref: "CMD-TEST", order_status: "partner_locked", offre: "standard",
  lock_expires_at: new Date(Date.now() + 120000).toISOString(), lock_offer_id: "off1",
  payment_id: "p1", payment_status: "requires_capture", amount_cents: 48000, currency: "eur",
  customer_id: "cus_1", payment_method_id: "pm_1", action_required_at: null, ...over,
});
const adminWith = (c, extra = {}) => fakeAdmin({ rpc: {
  secoto_differe_charge_context: () => ({ data: c }),
  secoto_od_capture_result: (a) => ({ data: { result: a.p_success ? "confirmed" : "capture_failed" } }),
  secoto_differe_needs_action: () => ({ data: { result: "needs_action", wait_minutes: 1440 } }),
  secoto_differe_action_expired: () => ({ data: { result: "released" } }),
  ...extra,
} });

test("isDiffere : uniquement les paiements marqués « débit à la confirmation »", () => {
  assert.equal(isDiffere({ debit_a_confirmation: true }), true);
  assert.equal(isDiffere({ differe: true }), true);
  assert.equal(isDiffere({ debit_a_confirmation: false, payment_circuit: "direct" }), false);
  assert.equal(isDiffere(null), false);
});

test("scénario 1 — un transporteur confirme : débit hors session sur le compte SECOTO, montant lu en base", async () => {
  const admin = adminWith(ctx());
  const stripe = fakeStripe();
  const r = await chargeDiffere({ admin, stripe, orderId: "o1" });
  assert.equal(r.result, "confirmed");
  const pi = stripe.calls.find((c) => c.name === "paymentIntents.create");
  const [params, opts] = pi.args;
  assert.equal(params.amount, 48000);
  assert.equal(params.customer, "cus_1");
  assert.equal(params.payment_method, "pm_1");
  assert.equal(params.off_session, true);
  assert.equal(params.confirm, true);
  assert.equal(params.application_fee_amount, undefined, "aucune commission séparée");
  assert.equal(opts.stripeAccount, undefined, "compte SECOTO, jamais celui du transporteur");
  assert.equal(params.metadata.secoto_circuit, "differe");
  assert.match(opts.idempotencyKey, /secoto-differe-charge-p1-pm_1-off1/);
  assert.equal(stripe.calls.some((c) => c.name === "paymentMethods.create"), false, "pas de copie de carte");
  assert.ok(admin.updates.some((u) => u.table === "payments" && u.patch.provider_intent_id === "pi_differe"));
  assert.deepEqual(admin.calls.find((c) => c.name === "secoto_od_capture_result").args, { p_order_id: "o1", p_success: true, p_error: null });
});

test("scénario 3 — 3D Secure demandé : tentative annulée, client prévenu, mission réservée", async () => {
  const err = Object.assign(new Error("authentication_required"), { code: "authentication_required", raw: { payment_intent: { id: "pi_3ds", status: "requires_payment_method" } } });
  const admin = adminWith(ctx());
  const stripe = fakeStripe({ piCreate: async () => { throw err; } });
  const r = await chargeDiffere({ admin, stripe, orderId: "o1" });
  assert.equal(r.result, "needs_action");
  assert.equal(r.wait_minutes, 1440);
  assert.ok(stripe.calls.some((c) => c.name === "paymentIntents.cancel" && c.args[0] === "pi_3ds"));
  assert.ok(admin.calls.some((c) => c.name === "secoto_differe_needs_action"));
  assert.equal(admin.calls.some((c) => c.name === "secoto_od_capture_result"), false, "rien n'est tranché");
  // Variante : Stripe renvoie requires_action sans erreur.
  const stripe2 = fakeStripe({ piCreate: async () => ({ id: "pi_ra", status: "requires_action" }) });
  const r2 = await chargeDiffere({ admin: adminWith(ctx()), stripe: stripe2, orderId: "o1" });
  assert.equal(r2.result, "needs_action");
  assert.ok(stripe2.calls.some((c) => c.name === "paymentIntents.cancel" && c.args[0] === "pi_ra"));
});

test("3D Secure en attente : rien ne bouge avant le délai ; après, la mission repart (aucun débit)", async () => {
  const enAttente = adminWith(ctx({ action_required_at: new Date().toISOString() }));
  const stripe = fakeStripe();
  assert.equal((await chargeDiffere({ admin: enAttente, stripe, orderId: "o1" })).result, "needs_action");
  assert.equal(stripe.calls.length, 0);
  const expire = adminWith(ctx({ action_required_at: new Date().toISOString(), lock_expires_at: new Date(Date.now() - 1000).toISOString() }));
  const r = await chargeDiffere({ admin: expire, stripe, orderId: "o1" });
  assert.equal(r.result, "released");
  assert.ok(expire.calls.some((c) => c.name === "secoto_differe_action_expired"));
  assert.equal(stripe.calls.length, 0, "aucun appel Stripe, aucun débit");
});

test("carte refusée : mission libérée, client invité à mettre sa carte à jour ; réseau coupé : rien n'est tranché", async () => {
  const declined = Object.assign(new Error("declined"), { type: "StripeCardError", code: "card_declined", decline_code: "insufficient_funds" });
  const admin = adminWith(ctx());
  const r = await chargeDiffere({ admin, stripe: fakeStripe({ piCreate: async () => { throw declined; } }), orderId: "o1" });
  assert.equal(r.result, "capture_failed");
  assert.equal(admin.calls.find((c) => c.name === "secoto_od_capture_result").args.p_error, "insufficient_funds");
  const admin2 = adminWith(ctx());
  const r2 = await chargeDiffere({ admin: admin2, stripe: fakeStripe({ piCreate: async () => { throw new Error("ECONNRESET"); } }), orderId: "o1" });
  assert.equal(r2.result, "pending_capture");
  assert.equal(admin2.calls.some((c) => c.name === "secoto_od_capture_result"), false);
});

test("déjà payé ou commande plus disponible : aucun nouveau débit", async () => {
  const stripe = fakeStripe();
  assert.equal((await chargeDiffere({ admin: adminWith(ctx({ payment_status: "paid" })), stripe, orderId: "o1" })).result, "confirmed");
  assert.equal((await chargeDiffere({ admin: adminWith(ctx({ order_status: "searching_partner" })), stripe, orderId: "o1" })).result, "unavailable");
  assert.equal(stripe.calls.filter((c) => c.name === "paymentIntents.create").length, 0);
});

test("acceptation : captureForOrder choisit le débit à la confirmation, sinon rien ne change", async () => {
  const admin = fakeAdmin({
    tables: { payments: [{ id: "p1", provider_intent_id: null, status: "requires_capture", payment_circuit: null, debit_a_confirmation: true }] },
    rpc: {
      secoto_differe_charge_context: () => ({ data: ctx() }),
      secoto_od_capture_result: () => ({ data: { result: "confirmed" } }),
    },
  });
  const stripe = fakeStripe();
  const r = await captureForOrder({ admin, stripe, orderId: "o1", paymentId: "p1" });
  assert.equal(r.result, "confirmed");
  assert.ok(stripe.calls.some((c) => c.name === "paymentIntents.create"));
  // Ancien circuit (encaissement autorisé puis capture) : capture, comme avant.
  const old = fakeAdmin({
    tables: { payments: [{ id: "p2", provider_intent_id: "pi_old", status: "requires_capture", payment_circuit: null, debit_a_confirmation: false }] },
    rpc: { secoto_od_capture_result: () => ({ data: { result: "confirmed" } }) },
  });
  const s2 = fakeStripe();
  await captureForOrder({ admin: old, stripe: s2, orderId: "o2", paymentId: "p2" });
  assert.deepEqual(s2.calls.map((c) => c.name), ["paymentIntents.retrieve"]);
});

test("maintenance : verrou expiré d'une offre -> même logique (validation en attente ou délai)", async () => {
  const admin = fakeAdmin({
    tables: { payments: [{ id: "p1", provider_intent_id: null, status: "requires_capture", payment_circuit: null, debit_a_confirmation: true }] },
    rpc: {
      secoto_od_maintenance_tick: () => ({ data: { expired_locks: [{ order_id: "o1", payment_id: "p1", intent_id: null, funding: "card", circuit: null, differe: true }], payment_actions: [] } }),
      secoto_differe_charge_context: () => ({ data: ctx({ action_required_at: new Date().toISOString(), lock_expires_at: new Date(Date.now() - 1000).toISOString() }) }),
      secoto_differe_action_expired: () => ({ data: { result: "released" } }),
    },
  });
  const report = await runMaintenance({ admin, stripe: fakeStripe() });
  assert.deepEqual(report.locks, [{ order: "o1", outcome: "released", circuit: "differe" }]);
  assert.equal(admin.calls.some((c) => c.name === "secoto_od_expire_lock"), false);
});

test("scénario 2 — fenêtre écoulée : annulation sans aucun appel Stripe (rien n'a été pris)", async () => {
  const admin = fakeAdmin({ rpc: {
    secoto_od_maintenance_tick: () => ({ data: { expired_locks: [], payment_actions: [{ payment_id: "p9", intent_id: null, action: "cancel", circuit: null }] } }),
  } });
  const stripe = fakeStripe();
  const report = await runMaintenance({ admin, stripe });
  assert.deepEqual(admin.calls.find((c) => c.name === "secoto_od_payment_action_result").args,
    { p_payment_id: "p9", p_action: "cancel", p_success: true, p_error: null });
  assert.equal(stripe.calls.filter((c) => /refunds|paymentIntents/.test(c.name)).length, 0);
  assert.equal(report.actions[0].outcome, "cancel");
});

test("réservation : la carte est enregistrée chez SECOTO (SetupIntent), jamais débitée", async () => {
  const admin = fakeAdmin({ tables: { transport_orders: [{ id: "o1", status: "awaiting_payment", public_ref: "CMD-T" }] } });
  const stripe = fakeStripe();
  const payment = { id: "p1", order_id: "o1", purpose: "od_plateau", status: "pending", amount_cents: 48000, currency: "eur", debit_a_confirmation: true };
  const res = await directFlow({ admin, stripe, payment, platform: "ios", customerId: "cus_1", account: {}, returnScreen: "courses", returnQuery: "commande=o1", differe: true });
  const body = JSON.parse(res.body);
  assert.equal(body.mode, "setup_sheet");
  assert.equal(body.circuit, "differe");
  const si = stripe.calls.find((c) => c.name === "setupIntents.create");
  assert.equal(si.args[0].usage, "off_session");
  assert.equal(si.args[0].metadata.secoto_circuit, "differe");
  assert.equal(si.args[1].stripeAccount, undefined);
  assert.equal(stripe.calls.some((c) => c.name === "paymentIntents.create"), false, "aucun débit à la réservation");
  // Web : page Stripe en mode « setup ».
  const s2 = fakeStripe();
  const web = JSON.parse((await directFlow({ admin, stripe: s2, payment, platform: "web", customerId: "cus_1", account: {}, returnScreen: "courses", returnQuery: "commande=o1", differe: true })).body);
  assert.equal(web.setup, true);
  assert.equal(s2.calls.find((c) => c.name === "checkout.sessions.create").args[0].mode, "setup");
});

test("3D Secure : le client paie lui-même sur une page Stripe du compte SECOTO", async () => {
  const admin = fakeAdmin({
    tables: { transport_orders: [{ id: "o1", status: "partner_locked", public_ref: "CMD-T", lock_expires_at: new Date(Date.now() + 86400000).toISOString() }] },
    rpc: { secoto_differe_charge_context: () => ({ data: ctx() }) },
  });
  const stripe = fakeStripe();
  const payment = { id: "p1", order_id: "o1", purpose: "od_plateau", status: "requires_capture", amount_cents: 48000, currency: "eur", debit_a_confirmation: true, direct_action_required_at: new Date().toISOString() };
  const body = JSON.parse((await directFlow({ admin, stripe, payment, platform: "web", customerId: "cus_1", account: {}, returnScreen: "courses", returnQuery: "commande=o1", differe: true })).body);
  assert.equal(body.mode, "checkout");
  assert.equal(body.amountCents, 48000);
  const cs = stripe.calls.find((c) => c.name === "checkout.sessions.create");
  assert.equal(cs.args[0].mode, "payment");
  assert.equal(cs.args[0].payment_intent_data.application_fee_amount, undefined);
  assert.equal(cs.args[0].payment_intent_data.metadata.secoto_payment_id, "p1");
  assert.equal(cs.args[1].stripeAccount, undefined);
});

test("webhook : carte enregistrée d'une offre -> la commande part aux transporteurs", async () => {
  const admin = fakeAdmin({ rpc: { secoto_direct_card_saved: () => ({ data: { effect: "dispatch_opened" } }) } });
  const res = await handleDirectSetup(admin, { id: "evt_1", type: "setup_intent.succeeded",
    data: { object: { id: "seti_1", payment_method: "pm_9", metadata: { secoto_payment_id: "p1", secoto_circuit: "differe" } } } });
  assert.equal(res.statusCode, 200);
  assert.deepEqual(admin.calls[0].args, { p_payment_id: "p1", p_event_id: "evt_1", p_setup_intent_id: "seti_1", p_payment_method_id: "pm_9" });
  // Un SetupIntent sans circuit reconnu reste ignoré.
  const admin2 = fakeAdmin();
  await handleDirectSetup(admin2, { id: "evt_2", data: { object: { id: "seti_2", metadata: { secoto_payment_id: "p1" } } } });
  assert.equal(admin2.calls.length, 0);
});

test("migration 099 : additive, derrière interrupteur éteint, aucune policy modifiée", () => {
  const sqlText = readFileSync(new URL("../supabase/migrations/202610170099_trois_offres.sql", import.meta.url), "utf8");
  assert.match(sqlText, /values \('trois_offres', false\)/);
  assert.doesNotMatch(sqlText, /\b(drop table|drop column|delete from|truncate|alter column|drop policy|create policy|alter policy)\b/i);
  assert.doesNotMatch(sqlText, /garanti/i, "jamais « garanti » dans les textes");
  assert.match(sqlText, /Rien n''a été débité/);
});
