// Migration 100 — règlement à l'arrivée du véhicule : logique serveur et
// textes affichés, sans réseau (Stripe et Supabase simulés).
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

process.env.SUPABASE_URL ||= "https://example.invalid";
process.env.SUPABASE_SERVICE_ROLE_KEY ||= "test";
process.env.STRIPE_PUBLISHABLE_KEY ||= "pk_test_x";

const { chargeDiffere } = await import("../netlify/lib/paiement-differe.js");
const { debiterLivraison, processReglements } = await import("../netlify/lib/reglement-livraison.js");
const { directFlow } = await import("../netlify/functions/create-payment-intent.js");
const { handleCommission } = await import("../netlify/functions/stripe-webhook.js");
const { sessionCarteArrivee } = await import("../netlify/lib/devis-direct.js");
const { sessionCommission } = await import("../netlify/functions/commission-pay.js");
const copy = await import("../src/lib/orderCopy.js");

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
        in: () => chain,
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
    paymentMethods: { retrieve: rec("paymentMethods.retrieve", async (id) => ({ id, type: "card" })) },
    paymentIntents: {
      create: rec("paymentIntents.create", over.piCreate || (async () => ({ id: "pi_liv", status: "succeeded", client_secret: "pi_liv_secret" }))),
      retrieve: rec("paymentIntents.retrieve", over.piRetrieve || (async (id) => ({ id, status: "requires_payment_method" }))),
      cancel: rec("paymentIntents.cancel", async () => ({ status: "canceled" })),
    },
    setupIntents: {
      create: rec("setupIntents.create", async () => ({ id: "seti_1", client_secret: "seti_1_secret", status: "requires_payment_method" })),
      retrieve: rec("setupIntents.retrieve", async () => ({ id: "seti_old", status: "succeeded" })),
    },
    customers: { create: rec("customers.create", async () => ({ id: "cus_new" })) },
    checkout: { sessions: { create: rec("checkout.sessions.create", async () => ({ id: "cs_1", url: "https://checkout.stripe.test/cs_1" })) } },
    ephemeralKeys: { create: rec("ephemeralKeys.create", async () => ({ secret: "ek_1" })) },
  };
}
const ligne = (over = {}) => ({
  payment_id: "p1", order_id: "o1", public_ref: "CMD-T", amount_cents: 48000, currency: "eur",
  customer_id: "cus_1", payment_method_id: "pm_1", provider_intent_id: null, tentative: 0,
  mode_reglement: "carte", purpose: "od_plateau", ...over,
});
const adminResultat = () => fakeAdmin({ rpc: {
  secoto_reglement_debit_resultat: (a) => ({ data: { result: a.p_resultat === "reussi" ? "paid" : a.p_resultat === "reseau" ? "retry" : "capture_failed" } }),
} });

test("confirmation du transporteur : aucun débit, la mission est confirmée (carte en garantie)", async () => {
  const ctx = { order_id: "o1", order_status: "partner_locked", payment_status: "requires_capture", payment_id: "p1",
    amount_cents: 48000, customer_id: "cus_1", payment_method_id: "pm_1", debit_a_livraison: true, mode_reglement: "especes" };
  const admin = fakeAdmin({ rpc: {
    secoto_differe_charge_context: () => ({ data: ctx }),
    secoto_reglement_confirmer: () => ({ data: { result: "confirmed", mission_id: "m1" } }),
  } });
  const stripe = fakeStripe();
  const r = await chargeDiffere({ admin, stripe, orderId: "o1" });
  assert.equal(r.result, "confirmed");
  assert.equal(stripe.calls.length, 0, "aucun appel Stripe à la confirmation");
  assert.ok(admin.calls.some((c) => c.name === "secoto_reglement_confirmer"));
  // Carte absente : la mission est libérée, comme un débit refusé.
  const admin2 = fakeAdmin({ rpc: {
    secoto_differe_charge_context: () => ({ data: ctx }),
    secoto_reglement_confirmer: () => ({ data: { result: "capture_failed", reason: "carte_absente" } }),
    secoto_od_capture_result: (a) => ({ data: { result: a.p_success ? "confirmed" : "capture_failed" } }),
  } });
  const r2 = await chargeDiffere({ admin: admin2, stripe, orderId: "o1" });
  assert.equal(r2.result, "capture_failed");
  assert.deepEqual(admin2.calls.find((c) => c.name === "secoto_od_capture_result").args, { p_order_id: "o1", p_success: false, p_error: "carte_absente" });
});

test("livraison : prélèvement hors session de la carte, montant lu en base, une clé par tentative", async () => {
  const admin = adminResultat();
  const stripe = fakeStripe();
  const r = await debiterLivraison({ admin, stripe, ligne: ligne({ tentative: 1 }) });
  assert.equal(r, "paid");
  const [params, opts] = stripe.calls.find((c) => c.name === "paymentIntents.create").args;
  assert.equal(params.amount, 48000);
  assert.equal(params.customer, "cus_1");
  assert.equal(params.payment_method, "pm_1");
  assert.equal(params.off_session, true);
  assert.equal(params.confirm, true);
  assert.deepEqual(params.payment_method_types, ["card"]);
  assert.equal(params.metadata.secoto_payment_id, "p1");
  assert.equal(params.metadata.secoto_purpose, "od_plateau", "le webhook retrouve le paiement");
  assert.equal(params.metadata.secoto_circuit, "livraison");
  assert.equal(opts.idempotencyKey, "secoto-livraison-p1-pm_1-1");
  assert.equal(opts.stripeAccount, undefined, "compte SECOTO");
  assert.ok(admin.updates.some((u) => u.table === "payments" && u.patch.provider_intent_id === "pi_liv"));
  assert.equal(admin.calls.find((c) => c.name === "secoto_reglement_debit_resultat").args.p_resultat, "reussi");
});

test("livraison : déjà prélevé (webhook perdu) -> constaté, jamais redébité", async () => {
  const admin = adminResultat();
  const stripe = fakeStripe({ piRetrieve: async (id) => ({ id, status: "succeeded" }) });
  const r = await debiterLivraison({ admin, stripe, ligne: ligne({ provider_intent_id: "pi_ancien" }) });
  assert.equal(r, "paid");
  assert.equal(stripe.calls.some((c) => c.name === "paymentIntents.create"), false);
  assert.equal(admin.calls[0].args.p_intent_id, "pi_ancien");
});

test("livraison : 3D Secure -> tentative annulée, le client paie lui-même ; refus ; coupure réseau ; carte absente", async () => {
  const err3ds = Object.assign(new Error("authentication_required"), { code: "authentication_required", raw: { payment_intent: { id: "pi_3ds" } } });
  let admin = adminResultat();
  let stripe = fakeStripe({ piCreate: async () => { throw err3ds; } });
  assert.equal(await debiterLivraison({ admin, stripe, ligne: ligne() }), "capture_failed");
  assert.equal(admin.calls[0].args.p_resultat, "action");
  assert.ok(stripe.calls.some((c) => c.name === "paymentIntents.cancel" && c.args[0] === "pi_3ds"));

  admin = adminResultat();
  stripe = fakeStripe({ piCreate: async () => { throw Object.assign(new Error("declined"), { type: "StripeCardError", code: "card_declined", decline_code: "insufficient_funds" }); } });
  await debiterLivraison({ admin, stripe, ligne: ligne() });
  assert.deepEqual([admin.calls[0].args.p_resultat, admin.calls[0].args.p_error], ["refuse", "insufficient_funds"]);

  admin = adminResultat();
  stripe = fakeStripe({ piCreate: async () => { throw new Error("ECONNRESET"); } });
  assert.equal(await debiterLivraison({ admin, stripe, ligne: ligne() }), "retry");
  assert.equal(admin.calls[0].args.p_resultat, "reseau");

  admin = adminResultat();
  stripe = fakeStripe();
  await debiterLivraison({ admin, stripe, ligne: ligne({ customer_id: null }) });
  assert.equal(admin.calls[0].args.p_resultat, "refuse");
  assert.equal(stripe.calls.length, 0);
});

test("maintenance : prélèvements, retenues de marge et relances", async () => {
  const admin = fakeAdmin({ rpc: {
    secoto_reglements_a_debiter: () => ({ data: [ligne(), ligne({ payment_id: "p2", order_id: "o2" })] }),
    secoto_reglement_debit_resultat: () => ({ data: { result: "paid" } }),
    secoto_commissions_retenir: () => ({ data: { retenues: 1 } }),
    secoto_reglement_relances: () => ({ data: { relances: 0 } }),
  } });
  const rapport = await processReglements({ admin, stripe: fakeStripe() });
  assert.equal(rapport.debits.length, 2);
  assert.deepEqual(rapport.retenues, { retenues: 1 });
  assert.ok(admin.calls.some((c) => c.name === "secoto_reglement_relances"));
});

const baseArgs = { customerId: "cus_1", account: { email: "c@test.invalid", full_name: "Client Test" }, returnScreen: "courses", returnQuery: "commande=o1", differe: true };
const paiementArrivee = (over = {}) => ({ id: "p1", order_id: "o1", purpose: "od_convoyage", status: "pending", amount_cents: 48000, currency: "eur",
  debit_a_confirmation: true, debit_a_livraison: true, reglement_tentatives: 0, ...over });

test("réservation : carte seule à l'enregistrement (prélevable à la livraison), dans l'app comme sur le web", async () => {
  const tables = { transport_orders: [{ id: "o1", status: "awaiting_payment", public_ref: "CMD-T", mode_reglement: "klarna" }] };
  const s1 = fakeStripe();
  const sheet = JSON.parse((await directFlow({ admin: fakeAdmin({ tables }), stripe: s1, payment: paiementArrivee(), platform: "ios", feuilleKlarna: true, ...baseArgs })).body);
  assert.equal(sheet.mode, "setup_sheet");
  const si = s1.calls.find((c) => c.name === "setupIntents.create").args[0];
  assert.deepEqual(si.payment_method_types, ["card"]);
  assert.equal(si.automatic_payment_methods, undefined);
  assert.equal(si.usage, "off_session");
  const s2 = fakeStripe();
  await directFlow({ admin: fakeAdmin({ tables }), stripe: s2, payment: paiementArrivee(), platform: "web", ...baseArgs });
  const cs = s2.calls.find((c) => c.name === "checkout.sessions.create").args[0];
  assert.equal(cs.mode, "setup");
  assert.deepEqual(cs.payment_method_types, ["card"]);
  // Sans règlement à l'arrivée (trois offres 099) : moyens du tableau de bord, inchangé.
  const s3 = fakeStripe();
  await directFlow({ admin: fakeAdmin({ tables }), stripe: s3, payment: paiementArrivee({ debit_a_livraison: false }), platform: "ios", feuilleKlarna: true, ...baseArgs });
  assert.deepEqual(s3.calls.find((c) => c.name === "setupIntents.create").args[0].automatic_payment_methods, { enabled: true });
});

test("véhicule livré : « Payer maintenant » (Klarna en plusieurs fois compris), feuille intégrée ou page Stripe", async () => {
  const tables = { transport_orders: [{ id: "o1", status: "delivered", public_ref: "CMD-T", mode_reglement: "klarna" }] };
  const s1 = fakeStripe({ piCreate: async () => ({ id: "pi_k", status: "requires_payment_method", client_secret: "pi_k_secret" }) });
  const body = JSON.parse((await directFlow({ admin: fakeAdmin({ tables }), stripe: s1, payment: paiementArrivee({ status: "requires_capture" }), platform: "ios", feuilleKlarna: true, ...baseArgs })).body);
  assert.equal(body.mode, "payment_sheet");
  assert.equal(body.clientSecret, "pi_k_secret");
  assert.equal(body.circuit, "livraison");
  const [pi, opts] = s1.calls.find((c) => c.name === "paymentIntents.create").args;
  assert.equal(pi.amount, 48000);
  assert.deepEqual(pi.automatic_payment_methods, { enabled: true }, "Klarna et la carte proposés");
  assert.equal(pi.off_session, undefined, "le client paie lui-même");
  assert.equal(pi.metadata.secoto_payment_id, "p1");
  assert.equal(pi.metadata.secoto_circuit, "livraison");
  assert.match(opts.idempotencyKey, /^secoto-livraison-sheet-p1-/);
  // Web (ou ancienne app) : page Stripe en mode paiement, retour à la commande.
  const s2 = fakeStripe();
  const web = JSON.parse((await directFlow({ admin: fakeAdmin({ tables }), stripe: s2, payment: paiementArrivee({ status: "capture_failed" }), platform: "web", ...baseArgs })).body);
  assert.equal(web.mode, "checkout");
  const cs = s2.calls.find((c) => c.name === "checkout.sessions.create").args[0];
  assert.equal(cs.mode, "payment");
  assert.equal(cs.line_items[0].price_data.unit_amount, 48000);
  assert.equal(cs.payment_intent_data.metadata.secoto_circuit, "livraison");
  assert.match(cs.success_url, /ecran=courses&commande=o1&paiement=ok$/);
  // Déjà payé ou pas encore livré : pas de page de paiement.
  const s3 = fakeStripe();
  const avant = await directFlow({ admin: fakeAdmin({ tables: { transport_orders: [{ id: "o1", status: "partner_confirmed", public_ref: "CMD-T" }] } }), stripe: s3, payment: paiementArrivee({ status: "requires_capture" }), platform: "web", ...baseArgs });
  assert.equal(avant.statusCode, 409);
  assert.equal(s3.calls.length, 0);
});

test("lien de devis : carte enregistrée, 0 € prélevé, carte seule", async () => {
  const admin = fakeAdmin({ tables: { accounts: [{ id: "a1", email: "c@test.invalid", full_name: "C", stripe_customer_id: null }] } });
  const stripe = fakeStripe();
  await sessionCarteArrivee({ admin, stripe, data: { payment_id: "p1", account_id: "a1", amount_cents: 48000, currency: "eur", purpose: "od_plateau" }, token: "abc", description: "SECOTO — transport" });
  const cs = stripe.calls.find((c) => c.name === "checkout.sessions.create").args[0];
  assert.equal(cs.mode, "setup");
  assert.equal(cs.customer, "cus_new");
  assert.deepEqual(cs.payment_method_types, ["card"]);
  assert.equal(cs.setup_intent_data.metadata.secoto_circuit, "differe", "le webhook enregistre la carte");
  assert.match(cs.custom_text.submit.message, /0 € prélevé aujourd'hui/);
  assert.match(cs.success_url, /retour=carte_arrivee$/);
  assert.ok(admin.updates.some((u) => u.table === "accounts" && u.patch.stripe_customer_id === "cus_new"));
});

test("marge due : page de paiement au montant restant, réglée par le webhook signé", async () => {
  const stripe = fakeStripe();
  await sessionCommission({ stripe, ctx: { id: "c1", reste_cents: 9000, reference: "COM-CMD-T", email: "t@test.invalid" }, platform: "ios" });
  const [cs, opts] = stripe.calls.find((c) => c.name === "checkout.sessions.create").args;
  assert.equal(cs.mode, "payment");
  assert.equal(cs.line_items[0].price_data.unit_amount, 9000);
  assert.equal(cs.payment_intent_data.metadata.secoto_commission_id, "c1");
  assert.match(cs.success_url, /retour-app\.html\?ecran=offre&paiement=ok$/);
  assert.match(opts.idempotencyKey, /^secoto-commission-c1-/);

  const admin = fakeAdmin({ rpc: { secoto_commission_payee: () => ({ data: { result: "payee" } }) } });
  const res = await handleCommission(admin, { type: "payment_intent.succeeded", data: { object: { id: "pi_c", amount_received: 9000, metadata: { secoto_commission_id: "c1" } } } });
  assert.equal(res.statusCode, 200);
  assert.deepEqual(admin.calls[0].args, { p_commission_id: "c1", p_intent_id: "pi_c", p_montant_cents: 9000 });
  assert.equal(await handleCommission(admin, { type: "payment_intent.succeeded", data: { object: { metadata: {} } } }), null);
  assert.equal(await handleCommission(admin, { type: "payment_intent.payment_failed", data: { object: { metadata: { secoto_commission_id: "c1" } } } }), null);
});

test("textes : 0 € aujourd'hui, modes proposés, consignes à la livraison", () => {
  const order = { debit_a_livraison: true, client_price_cents: 48000, status: "awaiting_payment", especes_possible: true, virement_possible: true };
  assert.match(copy.paymentExplanation(order), /^0 € prélevé aujourd’hui/);
  assert.match(copy.cancellationPolicy(order), /rien n’est prélevé avant son arrivée/);
  assert.equal(copy.cancellationNotice({ cancellable: true, late: true, retained_pct: 50 }, order), "Rien n’a été prélevé : annulation sans frais.");
  assert.deepEqual(copy.modesReglementPossibles(order).map((m) => m.cle), ["carte", "klarna", "virement", "especes"]);
  assert.deepEqual(copy.modesReglementPossibles({ ...order, especes_possible: false, virement_possible: false }).map((m) => m.cle), ["carte", "klarna"]);
  assert.equal(copy.paymentStateLabel({ ...order, payment_status: "requires_capture" }), "Carte enregistrée — 0 € prélevé");
  const livre = { ...order, status: "delivered", payment_status: "requires_capture" };
  assert.match(copy.reglementLivraisonTexte({ ...livre, mode_reglement: "carte" }), /vont être prélevés sur votre carte/);
  assert.match(copy.reglementLivraisonTexte({ ...livre, mode_reglement: "klarna" }), /plusieurs fois avec Klarna/);
  assert.match(copy.reglementLivraisonTexte({ ...livre, mode_reglement: "virement" }), /^Virez 480/);
  assert.match(copy.reglementLivraisonTexte({ ...livre, mode_reglement: "especes" }), /en espèces au transporteur/);
  assert.match(copy.reglementLivraisonTexte({ ...livre, mode_reglement: "especes", especes_statut: "non_recu" }), /ne pas avoir reçu/);
  assert.match(copy.reglementLivraisonTexte({ ...livre, mode_reglement: "especes", especes_statut: "recu", payment_status: "cancelled" }), /réglés en espèces/);
  assert.match(copy.reglementLivraisonTexte({ ...livre, payment_status: "paid" }), /Merci/);
  assert.equal(copy.reglementLivraisonTexte({ ...livre, debit_a_livraison: false }), "");
  // Commande classique : textes inchangés.
  assert.match(copy.paymentExplanation({ client_price_cents: 48000 }), /encaissés dès la validation/);
});

test("migration 100 : additive, derrière interrupteur éteint, plafond espèces légal, aucune policy modifiée", () => {
  const sqlText = readFileSync(new URL("../supabase/migrations/202610180100_reglement_a_l_arrivee.sql", import.meta.url), "utf8");
  assert.match(sqlText, /values \('reglement_arrivee', false\)/);
  assert.match(sqlText, /'plafond_especes_eur', 1000/);
  assert.match(sqlText, /L112-6/);
  assert.doesNotMatch(sqlText, /\b(drop table|drop column|delete from|truncate|alter column|drop policy|create policy|alter policy)\b/i);
  assert.match(sqlText, /enable row level security/);
  // Chaque fonction de service est fermée au public et aux comptes connectés.
  for (const fn of ["secoto_reglement_confirmer", "secoto_reglements_a_debiter", "secoto_reglement_debit_resultat", "secoto_commission_payee", "secoto_commissions_retenir"]) {
    assert.match(sqlText, new RegExp(`revoke all on function public\\.${fn}\\([^)]*\\) from public, anon, authenticated`), fn);
  }
});
