// Migration 074 — paiement direct plateau : logique serveur sans réseau
// (Stripe et Supabase simulés). Prouve aussi que l'ancien circuit et le
// convoyage appellent Stripe EXACTEMENT comme avant.
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

process.env.SUPABASE_URL ||= "https://example.invalid";
process.env.SUPABASE_SERVICE_ROLE_KEY ||= "test";
process.env.STRIPE_PUBLISHABLE_KEY ||= "pk_test_x";

const direct = await import("../netlify/lib/paiement-direct.js");
const { captureForOrder } = await import("../netlify/functions/offer-accept.js");
const { runMaintenance } = await import("../netlify/functions/od-maintenance.js");
const { handleDirectSetup } = await import("../netlify/functions/stripe-webhook.js");
const { handleConnectEvent } = await import("../netlify/functions/stripe-connect-webhook.js");
const { directFlow } = await import("../netlify/functions/create-payment-intent.js");
const { connectStatusFromAccount } = await import("../netlify/functions/connect-onboarding.js");

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
          if (state.patch) { updates.push({ table, patch: state.patch, filters: { ...state.filters } }); }
          return chain;
        },
        is: () => chain,
        not: () => chain,
        in: () => chain,
        order: () => chain,
        limit: async () => ({ data: tables[table] || [], error: null }),
        maybeSingle: async () => ({ data: find() }),
        single: async () => ({ data: find() }),
      };
      return chain;
    },
  };
}

// Stripe simulé : enregistre chaque appel avec ses options (stripeAccount…).
function fakeStripe(over = {}) {
  const calls = [];
  const rec = (name, impl) => async (...args) => { calls.push({ name, args }); return impl(...args); };
  return {
    calls,
    paymentMethods: { create: rec("paymentMethods.create", over.pmCreate || (async () => ({ id: "pm_clone" }))) },
    paymentIntents: {
      create: rec("paymentIntents.create", over.piCreate || (async () => ({ id: "pi_direct", status: "succeeded" }))),
      retrieve: rec("paymentIntents.retrieve", over.piRetrieve || (async () => ({ id: "pi_x", status: "succeeded", amount: 50000 }))),
      capture: rec("paymentIntents.capture", over.piCapture || (async () => ({ id: "pi_x", status: "succeeded" }))),
      cancel: rec("paymentIntents.cancel", async () => ({ status: "canceled" })),
    },
    refunds: { create: rec("refunds.create", async () => ({ id: "re_1" })) },
    payouts: { create: rec("payouts.create", over.payoutCreate || (async () => ({ id: "po_1" }))) },
    transfers: { create: rec("transfers.create", async () => ({ id: "tr_1" })) },
    setupIntents: {
      create: rec("setupIntents.create", async () => ({ id: "seti_1", client_secret: "seti_1_secret", status: "requires_payment_method" })),
      retrieve: rec("setupIntents.retrieve", async () => ({ id: "seti_old", status: "succeeded" })),
    },
    checkout: { sessions: { create: rec("checkout.sessions.create", async () => ({ id: "cs_1", url: "https://checkout.stripe.test/cs_1" })) } },
    ephemeralKeys: { create: rec("ephemeralKeys.create", async () => ({ secret: "ek_1" })) },
    accounts: { retrieve: rec("accounts.retrieve", async () => ({})) },
  };
}

const CTX = {
  order_id: "o1", order_status: "partner_locked", public_ref: "CMD-2026-TEST",
  payment_id: "p1", payment_status: "requires_capture", amount_cents: 50000, currency: "eur",
  application_fee_cents: 8000, partner_id: "t1", partner_ready: true,
  connected_account_id: "acct_T", customer_id: "cus_C", payment_method_id: "pm_C",
  provider_intent_id: null, lock_expires_at: new Date(Date.now() + 60000).toISOString(), action_required_at: null,
};
const withCtx = (over = {}, rpc = {}) => fakeAdmin({
  rpc: {
    secoto_direct_charge_context: async () => ({ data: { ...CTX, ...over }, error: null }),
    secoto_od_capture_result: async (a) => ({ data: { result: a.p_success ? "confirmed" : "capture_failed" }, error: null }),
    secoto_direct_charge_needs_action: async () => ({ data: { result: "needs_action", wait_minutes: 120 }, error: null }),
    ...rpc,
  },
});

test("débit direct : sur le compte du transporteur, commission SECOTO en application_fee, carte recopiée", async () => {
  const admin = withCtx();
  const stripe = fakeStripe();
  const r = await direct.chargeDirect({ admin, stripe, orderId: "o1" });
  assert.equal(r.result, "confirmed");
  const clone = stripe.calls.find((c) => c.name === "paymentMethods.create");
  assert.deepEqual(clone.args[0], { customer: "cus_C", payment_method: "pm_C" });
  assert.equal(clone.args[1].stripeAccount, "acct_T");
  const pi = stripe.calls.find((c) => c.name === "paymentIntents.create");
  assert.equal(pi.args[1].stripeAccount, "acct_T", "le paiement est créé SUR LE COMPTE DU TRANSPORTEUR");
  assert.equal(pi.args[0].amount, 50000);
  assert.equal(pi.args[0].application_fee_amount, 8000, "seule la commission revient à SECOTO");
  assert.equal(pi.args[0].payment_method, "pm_clone");
  assert.equal(pi.args[0].off_session, true);
  assert.equal(pi.args[0].confirm, true);
  assert.equal(pi.args[0].metadata.secoto_payment_id, "p1");
  assert.equal(pi.args[0].transfer_data, undefined, "jamais de transfert depuis SECOTO");
  assert.equal(pi.args[0].on_behalf_of, undefined);
  assert.match(pi.args[1].idempotencyKey, /^secoto-direct-charge-p1-acct_T-pm_C$/);
  assert.ok(admin.updates.some((u) => u.table === "payments" && u.patch.provider_intent_id === "pi_direct"));
  assert.ok(!stripe.calls.some((c) => c.name === "transfers.create"));
});

test("débit direct : clés stables -> une reprise retrouve le même paiement", async () => {
  const k1 = []; const k2 = [];
  for (const store of [k1, k2]) {
    const stripe = fakeStripe();
    await direct.chargeDirect({ admin: withCtx(), stripe, orderId: "o1" });
    store.push(...stripe.calls.map((c) => c.args[1]?.idempotencyKey));
  }
  assert.deepEqual(k1, k2);
});

test("débit direct : carte refusée -> mission libérée pour les autres transporteurs", async () => {
  const admin = withCtx();
  const stripe = fakeStripe({ piCreate: async () => { const e = new Error("refusée"); e.type = "StripeCardError"; e.code = "card_declined"; throw e; } });
  const r = await direct.chargeDirect({ admin, stripe, orderId: "o1" });
  assert.equal(r.result, "capture_failed");
  const cr = admin.calls.find((c) => c.name === "secoto_od_capture_result");
  assert.equal(cr.args.p_success, false);
});

test("débit direct : validation bancaire exigée -> le client valide lui-même, la mission reste réservée", async () => {
  const admin = withCtx();
  const stripe = fakeStripe({ piCreate: async () => {
    const e = new Error("auth"); e.code = "authentication_required"; e.raw = { payment_intent: { id: "pi_fail", status: "requires_payment_method" } }; throw e;
  } });
  const r = await direct.chargeDirect({ admin, stripe, orderId: "o1" });
  assert.equal(r.result, "needs_action");
  assert.ok(admin.calls.some((c) => c.name === "secoto_direct_charge_needs_action"));
  assert.ok(!admin.calls.some((c) => c.name === "secoto_od_capture_result"), "rien n'est tranché");
  const cancel = stripe.calls.find((c) => c.name === "paymentIntents.cancel");
  assert.equal(cancel.args[0], "pi_fail");
  assert.equal(cancel.args[2].stripeAccount, "acct_T");
});

test("débit direct : coupure réseau -> rien n'est tranché, la maintenance reprend", async () => {
  const admin = withCtx();
  const stripe = fakeStripe({ piCreate: async () => { const e = new Error("ECONNRESET"); e.type = "StripeConnectionError"; throw e; } });
  const r = await direct.chargeDirect({ admin, stripe, orderId: "o1" });
  assert.equal(r.result, "pending_capture");
  assert.ok(!admin.calls.some((c) => c.name === "secoto_od_capture_result"));
});

test("débit direct : transporteur non prêt ou carte absente -> refus propre, aucun appel Stripe", async () => {
  for (const over of [{ partner_ready: false }, { connected_account_id: null }, { payment_method_id: null }]) {
    const admin = withCtx(over);
    const stripe = fakeStripe();
    const r = await direct.chargeDirect({ admin, stripe, orderId: "o1" });
    assert.equal(r.result, "capture_failed");
    assert.equal(stripe.calls.length, 0);
  }
});

test("débit direct : validation en attente -> on patiente ; délai dépassé -> mission libérée", async () => {
  const waiting = withCtx({ action_required_at: new Date().toISOString() });
  const s1 = fakeStripe();
  assert.equal((await direct.chargeDirect({ admin: waiting, stripe: s1, orderId: "o1" })).result, "needs_action");
  assert.equal(s1.calls.length, 0, "aucun second débit pendant l'attente");
  const expired = withCtx({ action_required_at: new Date().toISOString(), lock_expires_at: new Date(Date.now() - 1000).toISOString() });
  const s2 = fakeStripe();
  assert.equal((await direct.chargeDirect({ admin: expired, stripe: s2, orderId: "o1" })).result, "capture_failed");
  assert.equal(s2.calls.length, 0);
});

test("débit direct : déjà payé (webhook arrivé avant) -> confirmation sans nouveau débit", async () => {
  const admin = withCtx({ payment_status: "paid" });
  const stripe = fakeStripe();
  assert.equal((await direct.chargeDirect({ admin, stripe, orderId: "o1" })).result, "confirmed");
  assert.equal(stripe.calls.length, 0);
});

test("acceptation : le circuit direct passe par le débit direct, l'ancien circuit capture comme avant", async () => {
  const adminDirect = fakeAdmin({
    tables: { payments: [{ id: "p1", provider_intent_id: null, status: "requires_capture", payment_circuit: "direct" }] },
    rpc: withCtx().calls ? {
      secoto_direct_charge_context: async () => ({ data: CTX, error: null }),
      secoto_od_capture_result: async () => ({ data: { result: "confirmed" }, error: null }),
    } : {},
  });
  const s1 = fakeStripe();
  await captureForOrder({ admin: adminDirect, stripe: s1, orderId: "o1", paymentId: "p1" });
  assert.ok(s1.calls.some((c) => c.name === "paymentIntents.create" && c.args[1].stripeAccount === "acct_T"));
  assert.ok(!s1.calls.some((c) => c.name === "paymentIntents.capture"));

  const adminOld = fakeAdmin({
    tables: { payments: [{ id: "p2", provider_intent_id: "pi_old", status: "requires_capture", payment_circuit: null }] },
    rpc: { secoto_od_capture_result: async () => ({ data: { result: "confirmed" }, error: null }) },
  });
  const s2 = fakeStripe({ piRetrieve: async () => ({ id: "pi_old", status: "requires_capture" }) });
  await captureForOrder({ admin: adminOld, stripe: s2, orderId: "o2", paymentId: "p2" });
  const cap = s2.calls.find((c) => c.name === "paymentIntents.capture");
  assert.equal(cap.args[0], "pi_old");
  assert.ok(s2.calls.every((c) => !c.args.some((a) => a && typeof a === "object" && "stripeAccount" in a)), "ancien circuit : aucun compte connecté");
  assert.ok(!s2.calls.some((c) => c.name === "paymentMethods.create" || c.name === "paymentIntents.create"));
});

function maintenanceAdmin(actions, locks = []) {
  return fakeAdmin({
    rpc: {
      secoto_od_maintenance_tick: async () => ({ data: { expired_quotes: 0, rebroadcast: 0, no_partner: 0, expired_locks: locks, payment_actions: actions }, error: null }),
      secoto_payouts_claim_due: async () => ({ data: [], error: null }),
      secoto_direct_charge_context: async () => ({ data: { ...CTX, payment_status: "paid" }, error: null }),
      secoto_od_capture_result: async () => ({ data: { result: "confirmed" }, error: null }),
    },
    tables: { payments: [{ id: "p1", provider_intent_id: "pi_direct", status: "requires_capture", payment_circuit: "direct" }] },
  });
}

test("maintenance : remboursement direct sur le compte du transporteur, commission rendue au prorata", async () => {
  const admin = maintenanceAdmin([
    { payment_id: "p1", intent_id: "pi_direct", action: "refund", amount_cents: 25000, circuit: "direct", connected_account_id: "acct_T" },
    { payment_id: "p9", intent_id: "pi_old", action: "refund", amount_cents: 12000, circuit: null, connected_account_id: null },
  ]);
  const stripe = fakeStripe({ piRetrieve: async (id) => ({ id, status: "succeeded", amount: 50000 }) });
  const report = await runMaintenance({ admin, stripe });
  const refunds = stripe.calls.filter((c) => c.name === "refunds.create");
  const dRefund = refunds.find((c) => c.args[0].payment_intent === "pi_direct");
  assert.equal(dRefund.args[1].stripeAccount, "acct_T");
  assert.equal(dRefund.args[0].refund_application_fee, true, "commission SECOTO rendue dans la même proportion");
  assert.equal(dRefund.args[0].amount, 25000);
  const oldRefund = refunds.find((c) => c.args[0].payment_intent === "pi_old");
  assert.equal(oldRefund.args[1].stripeAccount, undefined, "ancien circuit : remboursement depuis SECOTO, inchangé");
  assert.equal(oldRefund.args[0].refund_application_fee, undefined);
  assert.equal(oldRefund.args[1].idempotencyKey, "secoto-od-refund-p9-12000", "clé historique inchangée");
  // Aucun virement dû dans ce scénario, et jamais de Transfer pour le circuit direct.
  assert.ok(!stripe.calls.some((c) => c.name === "payouts.create"));
  assert.ok(!stripe.calls.some((c) => c.name === "transfers.create"), "aucun Transfer pour le circuit direct");
  assert.deepEqual(report.direct_payouts, []);
});

test("076 : à l'échéance, virement du solde du transporteur vers SA banque, jamais de Transfer", async () => {
  const admin = maintenanceAdmin([]);
  admin.rpc = ((orig) => async (name, args) => {
    if (name === "secoto_direct_payouts_claim_due") {
      admin.calls.push({ name, args });
      return { data: [{ payout_id: "pp1", amount_cents: 40000, kind: "mission", connected_account_id: "acct_T", order_id: "o1", mission_id: "m1" }], error: null };
    }
    return orig(name, args);
  })(admin.rpc);
  const stripe = fakeStripe();
  const report = await runMaintenance({ admin, stripe });
  const po = stripe.calls.find((c) => c.name === "payouts.create");
  assert.equal(po.args[0].amount, 40000);
  assert.equal(po.args[1].stripeAccount, "acct_T", "virement depuis le compte du transporteur");
  assert.equal(po.args[1].idempotencyKey, "secoto-direct-payout-pp1-40000");
  assert.ok(!stripe.calls.some((c) => c.name === "transfers.create"));
  const res = admin.calls.find((c) => c.name === "secoto_payout_transfer_result");
  assert.equal(res.args.p_success, true);
  assert.equal(res.args.p_transfer_id, "po_1");
  assert.equal(report.direct_payouts[0].outcome, "paid");
});

test("076 : fonds pas encore disponibles chez Stripe -> erreur transmise pour un nouvel essai", async () => {
  const admin = maintenanceAdmin([]);
  admin.rpc = ((orig) => async (name, args) => {
    if (name === "secoto_direct_payouts_claim_due") {
      admin.calls.push({ name, args });
      return { data: [{ payout_id: "pp2", amount_cents: 1000, kind: "mission", connected_account_id: "acct_T" }], error: null };
    }
    return orig(name, args);
  })(admin.rpc);
  const stripe = fakeStripe({ payoutCreate: async () => { const e = new Error("Insufficient funds"); e.code = "balance_insufficient"; throw e; } });
  await runMaintenance({ admin, stripe });
  const res = admin.calls.find((c) => c.name === "secoto_payout_transfer_result");
  assert.equal(res.args.p_success, false);
  assert.match(res.args.p_error, /balance_insufficient/);
});

test("maintenance : verrou expiré en circuit direct -> décision prise chez Stripe, jamais un abandon aveugle", async () => {
  const admin = maintenanceAdmin([], [{ order_id: "o1", payment_id: "p1", intent_id: null, funding: "card", circuit: "direct" }]);
  const stripe = fakeStripe();
  const report = await runMaintenance({ admin, stripe });
  assert.equal(report.locks[0].circuit, "direct");
  assert.equal(report.locks[0].outcome, "confirmed");
  assert.ok(!admin.calls.some((c) => c.name === "secoto_od_expire_lock"), "un paiement peut avoir réussi : on ne relâche pas à l'aveugle");
});

test("webhook SECOTO : carte validée d'un paiement direct -> diffusion, sans encaissement", async () => {
  const admin = fakeAdmin({ rpc: { secoto_direct_card_saved: async () => ({ data: { status: "requires_capture", effect: "dispatch_opened" }, error: null }) } });
  const res = await handleDirectSetup(admin, { id: "evt_1", type: "setup_intent.succeeded",
    data: { object: { id: "seti_1", payment_method: "pm_C", metadata: { secoto_payment_id: "p1", secoto_circuit: "direct" } } } });
  assert.equal(res.statusCode, 200);
  const call = admin.calls.find((c) => c.name === "secoto_direct_card_saved");
  assert.deepEqual(call.args, { p_payment_id: "p1", p_event_id: "evt_1", p_setup_intent_id: "seti_1", p_payment_method_id: "pm_C" });
  const ignored = await handleDirectSetup(fakeAdmin(), { id: "evt_2", type: "setup_intent.succeeded", data: { object: { id: "seti_x", metadata: {} } } });
  assert.match(ignored.body, /ignored/);
});

test("webhook Connect : capacités recopiées, paiement appliqué par les fonctions existantes", async () => {
  const admin = fakeAdmin({ rpc: { secoto_od_apply_payment_event: async () => ({ data: { status: "paid", effect: "confirmed" }, error: null }) } });
  const acct = await handleConnectEvent(admin, { id: "evt_a", type: "account.updated", account: "acct_T",
    data: { object: { id: "acct_T", payouts_enabled: true, details_submitted: true, capabilities: { transfers: "active", card_payments: "active" } } } });
  assert.equal(acct.statusCode, 200);
  const upd = admin.updates.find((u) => u.table === "accounts");
  assert.equal(upd.patch.stripe_card_payments_enabled, true);
  assert.equal(upd.filters.stripe_connect_account_id, "acct_T");

  const paid = await handleConnectEvent(admin, { id: "evt_p", type: "payment_intent.succeeded", account: "acct_T", created: 1,
    data: { object: { id: "pi_direct", metadata: { secoto_payment_id: "p1", secoto_purpose: "od_plateau" } } } });
  assert.equal(paid.statusCode, 200);
  assert.ok(admin.calls.some((c) => c.name === "secoto_od_apply_payment_event" && c.args.p_intent_id === "pi_direct"));
  const notConnect = await handleConnectEvent(fakeAdmin(), { id: "evt_n", type: "payment_intent.succeeded", data: { object: {} } });
  assert.match(notConnect.body, /not_connect_event/);
});

test("paiement côté client : carte validée sans débit (natif et web), validation bancaire sur le compte du transporteur", async () => {
  const base = { id: "p1", order_id: "o1", purpose: "od_plateau", amount_cents: 50000, currency: "eur", status: "pending", payment_circuit: "direct", setup_intent_id: null, direct_action_required_at: null };
  const tables = { transport_orders: [{ id: "o1", status: "awaiting_payment", public_ref: "CMD-2026-TEST", lock_expires_at: null }] };
  const args = { platform: "ios", customerId: "cus_C", account: { email: "c@test.invalid" }, returnScreen: "courses", returnQuery: "commande=o1" };

  const s1 = fakeStripe();
  const r1 = JSON.parse((await directFlow({ admin: fakeAdmin({ tables }), stripe: s1, payment: base, ...args })).body);
  assert.equal(r1.mode, "setup_sheet");
  assert.equal(r1.setupIntentClientSecret, "seti_1_secret");
  const si = s1.calls.find((c) => c.name === "setupIntents.create");
  assert.equal(si.args[0].usage, "off_session");
  assert.equal(si.args[0].customer, "cus_C");
  assert.ok(!s1.calls.some((c) => c.name === "paymentIntents.create"), "aucun débit à la réservation");

  const s2 = fakeStripe();
  const r2 = JSON.parse((await directFlow({ admin: fakeAdmin({ tables }), stripe: s2, payment: base, ...args, platform: "web" })).body);
  assert.equal(r2.mode, "checkout");
  assert.equal(s2.calls.find((c) => c.name === "checkout.sessions.create").args[0].mode, "setup");

  const locked = { transport_orders: [{ id: "o1", status: "partner_locked", public_ref: "CMD-2026-TEST", lock_expires_at: new Date(Date.now() + 7200000).toISOString() }] };
  const s3 = fakeStripe();
  const admin3 = fakeAdmin({ tables: locked, rpc: { secoto_direct_charge_context: async () => ({ data: CTX, error: null }) } });
  const r3 = JSON.parse((await directFlow({ admin: admin3, stripe: s3, payment: { ...base, status: "requires_capture", direct_action_required_at: new Date().toISOString() }, ...args })).body);
  assert.equal(r3.mode, "checkout");
  const cs = s3.calls.find((c) => c.name === "checkout.sessions.create");
  assert.equal(cs.args[1].stripeAccount, "acct_T", "paiement sur le compte du transporteur");
  assert.equal(cs.args[0].payment_intent_data.application_fee_amount, 8000);
  assert.equal(cs.args[0].payment_intent_data.metadata.secoto_payment_id, "p1");

  const done = { transport_orders: [{ id: "o1", status: "partner_confirmed", public_ref: "CMD", lock_expires_at: null }] };
  const r4 = await directFlow({ admin: fakeAdmin({ tables: done }), stripe: fakeStripe(), payment: { ...base, status: "requires_capture" }, ...args });
  assert.equal(r4.statusCode, 409, "carte non modifiable une fois le transporteur débité");
});

test("compte transporteur : capacité d'encaissement par carte lue chez Stripe", () => {
  assert.equal(connectStatusFromAccount({ capabilities: { transfers: "active", card_payments: "active" }, payouts_enabled: true }).card_payments_enabled, true);
  assert.equal(connectStatusFromAccount({ capabilities: { transfers: "active" }, payouts_enabled: true }).card_payments_enabled, false);
  assert.equal(connectStatusFromAccount({ capabilities: { transfers: "active" }, payouts_enabled: true }).status, "active", "statut historique inchangé");
});

test("convoyage et ancien circuit : le code historique de création de paiement est intact", () => {
  const src = readFileSync(new URL("../netlify/functions/create-payment-intent.js", import.meta.url), "utf8");
  // Le PaymentIntent historique reste créé sur le compte SECOTO, sans commission ni compte connecté.
  const legacy = src.slice(src.indexOf("// 4b. Réutilisation de l'intention existante"), src.indexOf("// 5. Sur iOS et Android"));
  assert.ok(legacy.length > 200);
  assert.doesNotMatch(legacy, /stripeAccount|application_fee_amount|on_behalf_of|transfer_data/);
  const offer = readFileSync(new URL("../netlify/functions/offer-accept.js", import.meta.url), "utf8");
  assert.match(offer, /if \(isDirect\(payment\)\) return chargeDirect/);
});

test("écrans client : textes du paiement direct, l'ancien circuit inchangé", async () => {
  const copy = await import("../src/lib/orderCopy.js");
  const directOrder = { payment_circuit: "direct", funding: "card", client_price_cents: 48000, payment_status: "requires_capture" };
  const oldOrder = { funding: "card", client_price_cents: 48000, payment_status: "requires_capture" };
  assert.match(copy.paymentExplanation(directOrder), /sans aucun débit/);
  assert.match(copy.paymentExplanation(directOrder), /au nom de ce transporteur/);
  assert.match(copy.paymentExplanation(oldOrder), /encaissés dès la validation/, "ancien texte conservé");
  assert.equal(copy.paymentStateLabel(directOrder), "Carte validée (non débitée)");
  assert.equal(copy.paymentStateLabel(oldOrder), "Paiement autorisé (non débité)");
  assert.match(copy.cancellationPolicy(directOrder), /moins de 2 h/);
  assert.equal(copy.cancellationPolicy(), copy.cancellationPolicy(oldOrder));
  assert.match(copy.cancellationNotice({ cancellable: true, circuit: "direct", charged: false }), /pas été débitée/);
  assert.match(copy.cancellationNotice({ cancellable: true, circuit: "direct", charged: true, last_minute: true }), /aucun remboursement/);
  assert.match(copy.cancellationNotice({ cancellable: true, circuit: "direct", charged: true, late: true, retained_pct: 50, refund_cents: 24000 }), /50 %/);
});

test("compte transporteur : création v2 si Stripe refuse la v1 (mode test), v1 inchangée sinon", async () => {
  const co = await import("../netlify/functions/connect-onboarding.js");
  const refus = Object.assign(new Error("Stripe no longer recommends Accounts v1 for new Connect integrations. Create connected accounts with POST /v2/core/accounts instead."), { type: "StripeInvalidRequestError" });
  const appels = [];
  const majs = [];
  const stripe = { v2: { core: { accounts: {
    create: async (p, o) => { appels.push({ p, o }); return { id: "acct_v2" }; },
    update: async (id, p) => { majs.push({ id, p }); return { id }; },
  } } } };
  const acct = await co.createConnectedAccount(stripe, { email: "t@test.invalid", userId: "u1", directOn: true, cle: "k" }, async () => { throw refus; });
  assert.equal(acct.id, "acct_v2");
  const p = appels[0].p;
  assert.equal(p.dashboard, "express");
  assert.deepEqual(p.defaults.responsibilities, { fees_collector: "application", losses_collector: "application" }, "frais Stripe à la charge de SECOTO");
  assert.equal(p.configuration.merchant, undefined, "création sans configuration marchande (règle Stripe France)");
  assert.equal(p.configuration.recipient.capabilities.stripe_balance.stripe_transfers.requested, true);
  assert.equal(appels[0].o.idempotencyKey, "k-v2");
  assert.equal(majs[0].id, "acct_v2");
  assert.equal(majs[0].p.configuration.merchant.capabilities.card_payments.requested, true, "encaissement par carte ajouté ensuite");
  assert.equal(majs[0].p.identity, undefined, "aucune donnée d'identité envoyée");
  // v1 acceptée : aucun appel v2.
  const ok = await co.createConnectedAccount(stripe, { email: "t", userId: "u2", directOn: false, cle: "k2" }, async () => ({ id: "acct_v1" }));
  assert.equal(ok.id, "acct_v1");
  assert.equal(appels.length, 1);
  // Autre erreur : remontée telle quelle.
  await assert.rejects(co.createConnectedAccount(stripe, { cle: "k3" }, async () => { throw new Error("autre"); }), /autre/);
});

test("lien d'inscription : v1 d'abord, v2 si le compte a été créé en v2", async () => {
  const co = await import("../netlify/functions/connect-onboarding.js");
  const v2 = [];
  const stripe = {
    accountLinks: { create: async () => { throw Object.assign(new Error("account is v2"), { type: "StripeInvalidRequestError" }); } },
    v2: { core: { accountLinks: { create: async (p) => { v2.push(p); return { url: "https://connect.stripe.test/v2" }; } } } },
  };
  const link = await co.onboardingLink(stripe, "acct_v2", { merchant: true });
  assert.equal(link.url, "https://connect.stripe.test/v2");
  assert.deepEqual(v2[0].use_case.account_onboarding.configurations, ["recipient", "merchant"]);
  const v1 = await co.onboardingLink({ accountLinks: { create: async () => ({ url: "https://connect.stripe.test/v1" }) } }, "acct_v1");
  assert.equal(v1.url, "https://connect.stripe.test/v1");
});

test("076 : le réglage « virement manuel » est relu de Stripe et posé à l'activation", async () => {
  assert.equal(connectStatusFromAccount({ settings: { payouts: { schedule: { interval: "manual" } } } }).payouts_manual, true);
  assert.equal(connectStatusFromAccount({ settings: { payouts: { schedule: { interval: "daily" } } } }).payouts_manual, false);
  assert.equal(connectStatusFromAccount({}).payouts_manual, false);
  const { upgradeForDirect } = await import("../netlify/functions/connect-onboarding.js");
  const calls = [];
  const stripe = { accounts: { update: async (...args) => { calls.push(args); return {}; } } };
  await upgradeForDirect(stripe, "acct_X");
  const payouts = calls.find((c) => c[1]?.settings?.payouts);
  assert.equal(payouts[1].settings.payouts.schedule.interval, "manual");
  assert.equal(payouts[1].settings.payouts.debit_negative_balances, true);
});

// ---------------------------------------------------------------------------
// 077 — liens de paiement de devis plateau en paiement direct
// ---------------------------------------------------------------------------
test("077 : mission manuelle -> paiement chez le transporteur, commission prélevée par Stripe", async () => {
  const { sessionDirecte } = await import("../netlify/lib/devis-direct.js");
  const stripe = fakeStripe();
  stripe.checkout = { sessions: { create: async (...args) => { stripe.calls.push({ name: "checkout.create", args }); return { url: "https://checkout.test/s" }; } } };
  const data = { payment_id: "pay1", purpose: "devis_course", reference: "MIS-1", amount_cents: 45000, application_fee_cents: 5000, currency: "eur", connected_account_id: "acct_T", circuit: "direct" };
  const s = await sessionDirecte({ admin: fakeAdmin(), stripe, data, token: "abc", description: "Transport" });
  assert.equal(s.url, "https://checkout.test/s");
  const [params, opts] = stripe.calls.find((c) => c.name === "checkout.create").args;
  assert.equal(params.mode, "payment");
  assert.equal(params.line_items[0].price_data.unit_amount, 45000);
  assert.equal(params.payment_intent_data.application_fee_amount, 5000);
  assert.equal(params.payment_intent_data.metadata.secoto_circuit, "direct");
  assert.equal(opts.stripeAccount, "acct_T", "encaissé sur le compte du transporteur, jamais chez SECOTO");
});

test("077 : devis à la demande -> carte enregistrée, aucun débit", async () => {
  const { sessionDirecte } = await import("../netlify/lib/devis-direct.js");
  const stripe = fakeStripe();
  stripe.customers = { create: async () => ({ id: "cus_new" }) };
  stripe.checkout = { sessions: { create: async (...args) => { stripe.calls.push({ name: "checkout.create", args }); return { url: "https://checkout.test/setup" }; } } };
  const admin = fakeAdmin({ tables: { accounts: [{ id: "acc1", email: "c@test.invalid", full_name: "C", stripe_customer_id: null }] } });
  const data = { payment_id: "pay2", purpose: "od_plateau", amount_cents: 48000, currency: "eur", account_id: "acc1", circuit: "direct" };
  await sessionDirecte({ admin, stripe, data, token: "abc", description: "Transport" });
  const [params, opts] = stripe.calls.find((c) => c.name === "checkout.create").args;
  assert.equal(params.mode, "setup");
  assert.equal(params.customer, "cus_new");
  assert.equal(params.setup_intent_data.metadata.secoto_circuit, "direct");
  assert.match(params.success_url, /retour=carte/);
  assert.equal(opts.stripeAccount, undefined, "la carte est enregistrée chez SECOTO, débitée plus tard chez le transporteur");
});

test("077 : webhook transporteur -> encaissement d'un lien de mission manuelle, uniquement s'il est direct et sur CE compte", async () => {
  const { handleConnectEvent } = await import("../netlify/functions/stripe-connect-webhook.js");
  const mk = (payment) => fakeAdmin({
    rpc: { secoto_settle_payment: async () => ({ data: { ok: true }, error: null }) },
    tables: { payments: [payment] },
  });
  const ev = { id: "evt1", type: "payment_intent.succeeded", account: "acct_T", data: { object: { id: "pi_1", metadata: { secoto_payment_id: "p1" } } } };
  const ok = mk({ id: "p1", purpose: "devis_course", payment_circuit: "direct", connected_account_id: "acct_T" });
  await handleConnectEvent(ok, ev);
  assert.ok(ok.calls.some((c) => c.name === "secoto_settle_payment" && c.args.p_status === "paid"));
  const autre = mk({ id: "p1", purpose: "devis_course", payment_circuit: "direct", connected_account_id: "acct_AUTRE" });
  await handleConnectEvent(autre, ev);
  assert.ok(!autre.calls.some((c) => c.name === "secoto_settle_payment"), "un autre compte ne peut pas solder ce paiement");
  const ancien = mk({ id: "p1", purpose: "devis_course", payment_circuit: null, connected_account_id: null });
  await handleConnectEvent(ancien, ev);
  assert.ok(!ancien.calls.some((c) => c.name === "secoto_settle_payment"), "ancien circuit : rien via le webhook transporteur");
});

test("076-078 : migrations additives, interrupteurs éteints, Transfers toujours exclus du circuit direct", async () => {
  const { readFileSync } = await import("node:fs");
  for (const f of ["202610090076_versement_a_la_livraison", "202610090077_liens_devis_paiement_direct", "202610090078_commission_due_par_le_client"]) {
    const sql = readFileSync(new URL(`../supabase/migrations/${f}.sql`, import.meta.url), "utf8");
    assert.doesNotMatch(sql, /\bdrop table\b|\bdrop column\b|\btruncate\b|\bdelete from\b|alter column/i, f);
    assert.doesNotMatch(sql, /set enabled = true/i, `${f} n'allume aucun interrupteur`);
  }
  const m78 = readFileSync(new URL("../supabase/migrations/202610090078_commission_due_par_le_client.sql", import.meta.url), "utf8");
  assert.match(m78, /\(partner_id = auth\.uid\(\) and kind <> 'commission_client'\)/, "le transporteur ne lit pas la facture de commission du client");
});
