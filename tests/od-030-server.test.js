// Migration 030-032 — logique serveur sans réseau (fournisseurs simulés).
import test from "node:test";
import assert from "node:assert/strict";

process.env.SUPABASE_URL ||= "https://example.invalid";
process.env.SUPABASE_SERVICE_ROLE_KEY ||= "test";

const lib = await import("../netlify/lib/secoto-server.js");
const { handleNewFlows } = await import("../netlify/functions/stripe-webhook.js");
const { captureForOrder } = await import("../netlify/functions/offer-accept.js");
const { notificationRoute, loadOfferSummary } = await import("../netlify/functions/send-mission-notifications.js");
const { refreshEtas } = await import("../netlify/functions/live-eta.js");
const { runMaintenance } = await import("../netlify/functions/od-maintenance.js");
const { parseSecotoDeepLink } = await import("../src/lib/deepLinks.js");

const A = { lat: 48.79, lng: 2.29 };
const B = { lat: 45.76, lng: 4.83 };

function fakeAdmin({ rpc = {}, tables = {} } = {}) {
  const calls = [];
  return {
    calls,
    rpc: async (name, args) => {
      calls.push({ name, args });
      const handler = rpc[name];
      return handler ? handler(args) : { data: null, error: null };
    },
    from: (table) => {
      const state = { table, filters: {} };
      const chain = {
        select: () => chain,
        eq: (k, v) => { state.filters[k] = v; return chain; },
        maybeSingle: async () => ({ data: (tables[table] || []).find((r) => Object.entries(state.filters).every(([k, v]) => r[k] === v)) || null }),
        single: async () => ({ data: (tables[table] || []).find((r) => Object.entries(state.filters).every(([k, v]) => r[k] === v)) || null }),
      };
      return chain;
    },
  };
}

test("itinéraire : aucun fournisseur → null (devis manuel), jamais de vol d'oiseau", async () => {
  assert.equal(await lib.computeRoute(A, B, { env: {} }), null);
  assert.equal(await lib.computeRoute({ lat: 200, lng: 0 }, B, { env: { ROUTING_PROVIDER: "ors", ORS_API_KEY: "k" } }), null);
});

test("itinéraire : ORS et OSRM convertis en km / minutes, erreurs → null", async () => {
  const ors = await lib.computeRoute(A, B, {
    env: { ROUTING_PROVIDER: "ors", ORS_API_KEY: "k" },
    fetchImpl: async (url, opts) => {
      assert.match(url, /driving-car\?start=2.29,48.79&end=4.83,45.76/);
      assert.equal(opts.headers.Authorization, "k");
      return { ok: true, json: async () => ({ features: [{ properties: { summary: { distance: 465321, duration: 16200 } } }] }) };
    },
  });
  assert.deepEqual(ors, { distance_km: 465.3, duration_min: 270, provider: "ors-driving-car" });
  const osrm = await lib.computeRoute(A, B, {
    env: { ROUTING_PROVIDER: "osrm", OSRM_URL: "https://osrm.test/" },
    fetchImpl: async () => ({ ok: true, json: async () => ({ code: "Ok", routes: [{ distance: 1000, duration: 120 }] }) }),
  });
  assert.equal(osrm.distance_km, 1);
  const down = await lib.computeRoute(A, B, { env: { ROUTING_PROVIDER: "ors", ORS_API_KEY: "k" }, fetchImpl: async () => { throw new Error("down"); } });
  assert.equal(down, null);
});

test("notification d'offre : aperçu masqué par défaut, détail sans donnée client", () => {
  const offer = { partner_pay_cents: 42050, pickup: { city: "Paris", postcode: "75011" }, delivery: { city: "Lyon", postcode: "69002" }, vehicle_model: "Peugeot 308" };
  const masked = lib.offerPushCopy(offer, "masked");
  assert.doesNotMatch(masked.title + masked.body, /Paris|Lyon|420/);
  const detailed = lib.offerPushCopy(offer, "detailed");
  assert.match(detailed.title, /420,50\s?€ pour vous/);
  assert.equal(detailed.body, "Paris (75011) → Lyon (69002) · Peugeot 308");
  const route = notificationRoute({ type: "mission_offer", ref_id: "5f0b7c1e-1a2b-4c3d-8e9f-001122334455" });
  assert.equal(route, "/?ecran=offre&offre=5f0b7c1e-1a2b-4c3d-8e9f-001122334455");
  const link = parseSecotoDeepLink(`https://app.secoto-transport.fr${route}`);
  assert.equal(link.screen, "offre");
  assert.equal(link.offerId, "5f0b7c1e-1a2b-4c3d-8e9f-001122334455");
});

test("résumé d'offre : refusé si l'offre appartient à un autre partenaire", async () => {
  const admin = fakeAdmin({ tables: {
    transport_offers: [{ id: "o1", partner_id: "p1", partner_pay_cents: 100, order_id: "c1" }],
    transport_orders: [{ id: "c1", quote_id: "q1" }],
    transport_quotes: [{ id: "q1", pickup: { city: "Paris", postcode: "75011", label: "12 rue privée" }, delivery: { city: "Lyon", postcode: "69002" }, vehicle: { model: "Clio" } }],
  } });
  assert.equal(await loadOfferSummary(admin, "o1", "p2"), null);
  const ok = await loadOfferSummary(admin, "o1", "p1");
  assert.equal(ok.pickup.label, undefined, "jamais l'adresse exacte dans une notification");
});

test("webhook : événements des commandes routés vers la machine d'état, historique inchangé", async () => {
  const admin = fakeAdmin({
    rpc: { secoto_od_apply_payment_event: async (a) => ({ data: { status: "requires_capture", args: a }, error: null }) },
    tables: { payments: [{ id: "pay-legacy", provider_intent_id: "pi_legacy", purpose: "commission_plateau" }] },
  });
  const od = await handleNewFlows(admin, { id: "evt_1", type: "payment_intent.amount_capturable_updated",
    data: { object: { id: "pi_1", metadata: { secoto_payment_id: "pay-1", secoto_purpose: "od_convoyage" } } } });
  assert.equal(od.statusCode, 200);
  assert.equal(admin.calls[0].args.p_event_id, "evt_1");
  const legacy = await handleNewFlows(admin, { id: "evt_2", type: "payment_intent.succeeded",
    data: { object: { id: "pi_legacy", metadata: { secoto_payment_id: "pay-legacy", secoto_purpose: "commission_plateau" } } } });
  assert.equal(legacy, null, "les paiements historiques gardent leur traitement");
  const refund = await handleNewFlows(fakeAdmin({ tables: { payments: [{ id: "pay-9", provider_intent_id: "pi_9", purpose: "od_plateau_commission" }] },
    rpc: { secoto_od_apply_payment_event: async (a) => ({ data: a, error: null }) } }),
    { id: "evt_3", type: "charge.refunded", data: { object: { payment_intent: "pi_9", amount_refunded: 2500 } } });
  assert.equal(JSON.parse(refund.body).result.p_amount_refunded_cents, 2500);
  const failing = await handleNewFlows(fakeAdmin({ rpc: { secoto_od_apply_payment_event: async () => ({ error: { message: "x" } }) } }),
    { id: "evt_4", type: "payment_intent.succeeded", data: { object: { id: "pi", metadata: { secoto_payment_id: "p", secoto_purpose: "od_convoyage" } } } });
  assert.equal(failing.statusCode, 500, "Stripe rejouera l'événement");
});

test("webhook abonnement : période de facture et identifiants extraits", async () => {
  const data = lib.subscriptionEventData("invoice.paid", {
    subscription: "sub_1",
    lines: { data: [{ period: { start: 1790000000, end: 1792592000 }, metadata: { secoto_subscription_id: "s-1" } }] },
  });
  assert.equal(data.subscriptionId, "s-1");
  assert.equal(data.stripeSubscriptionId, "sub_1");
  assert.equal(data.periodStart, new Date(1790000000 * 1000).toISOString());
  assert.equal(lib.subscriptionEventData("checkout.session.completed", { mode: "payment" }), null);
});

test("capture : succès → confirmation ; refus carte → échec tracé ; panne réseau → aucune décision", async () => {
  const base = { tables: { payments: [{ id: "pay", provider_intent_id: "pi_1", status: "requires_capture" }] } };
  const okAdmin = fakeAdmin({ ...base, rpc: { secoto_od_capture_result: async (a) => ({ data: { result: a.p_success ? "confirmed" : "capture_failed" } }) } });
  const okStripe = { paymentIntents: { retrieve: async () => ({ id: "pi_1", status: "requires_capture" }), capture: async (id, _p, opts) => { assert.equal(opts.idempotencyKey, "secoto-capture-pay"); return { id, status: "succeeded" }; } } };
  assert.equal((await captureForOrder({ admin: okAdmin, stripe: okStripe, orderId: "o", paymentId: "pay" })).result, "confirmed");

  const declined = { paymentIntents: { retrieve: async () => ({ id: "pi_1", status: "requires_capture" }), capture: async () => { const e = new Error("declined"); e.type = "StripeCardError"; e.code = "card_declined"; throw e; } } };
  const failAdmin = fakeAdmin({ ...base, rpc: { secoto_od_capture_result: async (a) => ({ data: { result: a.p_success ? "confirmed" : "capture_failed" } }) } });
  assert.equal((await captureForOrder({ admin: failAdmin, stripe: declined, orderId: "o", paymentId: "pay" })).result, "capture_failed");

  const network = { paymentIntents: { retrieve: async () => { const e = new Error("ECONNRESET"); e.type = "StripeConnectionError"; throw e; } } };
  const netAdmin = fakeAdmin(base);
  const r = await captureForOrder({ admin: netAdmin, stripe: network, orderId: "o", paymentId: "pay" });
  assert.equal(r.result, "pending_capture");
  assert.equal(netAdmin.calls.length, 0, "aucune confirmation ni échec sans état Stripe connu");
});

test("maintenance : libération d'autorisation, remboursement, verrou de forfait", async () => {
  const stripeCalls = [];
  const admin = fakeAdmin({ rpc: {
    secoto_od_maintenance_tick: async () => ({ data: { expired_quotes: 0, rebroadcast: 0, no_partner: 1,
      expired_locks: [{ order_id: "o-sub", funding: "subscription" }],
      payment_actions: [
        { payment_id: "p-auth", intent_id: "pi_a", action: "cancel", amount_cents: 1000 },
        { payment_id: "p-paid", intent_id: "pi_b", action: "refund", amount_cents: 2000 },
        { payment_id: "p-none", intent_id: null, action: "cancel", amount_cents: 500 },
      ] } }),
    secoto_od_expire_lock: async () => ({ data: { result: "confirmed" } }),
    secoto_sub_maintenance_tick: async () => ({ data: { suspended: 0 } }),
  } });
  const stripe = {
    paymentIntents: { retrieve: async (id) => ({ id, status: "requires_capture" }), cancel: async (id) => { stripeCalls.push(["cancel", id]); return {}; } },
    refunds: { create: async (p, o) => { stripeCalls.push(["refund", p.payment_intent, p.amount, o.idempotencyKey]); return {}; } },
  };
  const report = await runMaintenance({ admin, stripe });
  assert.deepEqual(stripeCalls, [["cancel", "pi_a"], ["refund", "pi_b", 2000, "secoto-od-refund-p-paid"]]);
  assert.equal(report.locks[0].outcome, "confirmed");
  const results = admin.calls.filter((c) => c.name === "secoto_od_payment_action_result").map((c) => [c.args.p_payment_id, c.args.p_success]);
  assert.deepEqual(results, [["p-auth", true], ["p-paid", true], ["p-none", true]]);
});

test("ETA : estimation calculée depuis la position, destination géocodée si besoin", async () => {
  const admin = fakeAdmin({ rpc: {
    secoto_live_eta_targets: async () => ({ data: [
      { mission_id: "m1", lat: 48.8, lng: 2.3, recorded_at: "2026-09-17T10:00:00Z", destination: { label: "Lyon", lat: 45.76, lng: 4.83 }, multi_mission: true },
      { mission_id: "m2", lat: 48.8, lng: 2.3, recorded_at: "2026-09-17T10:00:00Z", destination: { label: "adresse introuvable" } },
    ] }),
  } });
  const now = new Date("2026-09-17T10:01:00Z");
  const report = await refreshEtas({ admin, now, route: async () => ({ distance_km: 460, duration_min: 270, provider: "test" }), geocode: async () => null });
  assert.deepEqual(report, { targets: 2, updated: 1 });
  const call = admin.calls.find((c) => c.name === "secoto_live_set_eta");
  assert.equal(call.args.p_eta_at, "2026-09-17T14:31:00.000Z");
  assert.equal(call.args.p_multi, true);
});
