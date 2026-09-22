// Migration 036 — versements transporteurs par Stripe Connect (sans réseau).
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

process.env.SUPABASE_URL ||= "https://example.invalid";
process.env.SUPABASE_SERVICE_ROLE_KEY ||= "test";

const { processPayouts } = await import("../netlify/functions/od-maintenance.js");
const { connectStatusFromAccount } = await import("../netlify/functions/connect-onboarding.js");
const SQL = readFileSync(new URL("../supabase/migrations/202609220036_versements_stripe_connect.sql", import.meta.url), "utf8");

function fakeAdmin(due) {
  const calls = [];
  return {
    calls,
    rpc: async (name, args) => {
      calls.push({ name, args });
      if (name === "secoto_payouts_claim_due") return { data: due, error: null };
      return { data: { result: "ok" }, error: null };
    },
  };
}

test("statut Connect : actif seulement si transferts ET virements bancaires sont ouverts", () => {
  assert.equal(connectStatusFromAccount({ capabilities: { transfers: "active" }, payouts_enabled: true }).status, "active");
  assert.equal(connectStatusFromAccount({ capabilities: { transfers: "active" }, payouts_enabled: false, details_submitted: true }).status, "pending");
  assert.equal(connectStatusFromAccount({ requirements: { disabled_reason: "rejected.fraud" } }).status, "restricted");
  assert.equal(connectStatusFromAccount({ requirements: { disabled_reason: "requirements.pending_verification" }, details_submitted: true }).status, "pending");
  assert.equal(connectStatusFromAccount({}).status, "incomplete");
});

test("transfert : montant exact, charge d'origine, clé d'idempotence avec le montant", async () => {
  const admin = fakeAdmin([{ payout_id: "p1", amount_cents: 50000, destination: "acct_1", intent_id: "pi_1", order_id: "o1", mission_id: "m1", kind: "mission" }]);
  const created = [];
  const stripe = {
    paymentIntents: { retrieve: async () => ({ latest_charge: "ch_1" }) },
    transfers: { create: async (params, opts) => { created.push({ params, opts }); return { id: "tr_1" }; } },
  };
  const report = await processPayouts({ admin, stripe });
  assert.equal(report[0].outcome, "paid");
  assert.equal(created[0].params.amount, 50000);
  assert.equal(created[0].params.destination, "acct_1");
  assert.equal(created[0].params.source_transaction, "ch_1", "la charge ch_…, pas le PaymentIntent");
  assert.equal(created[0].opts.idempotencyKey, "secoto-partner-payout-p1-50000");
  const result = admin.calls.find((c) => c.name === "secoto_payout_transfer_result");
  assert.deepEqual(result.args, { p_payout_id: "p1", p_success: true, p_transfer_id: "tr_1", p_charge_id: "ch_1", p_error: null });
});

test("mission manuelle sans paiement Stripe : transfert depuis le solde, sans source_transaction", async () => {
  const admin = fakeAdmin([{ payout_id: "p2", amount_cents: 22000, destination: "acct_2", intent_id: null, kind: "mission" }]);
  const created = [];
  const stripe = { transfers: { create: async (params) => { created.push(params); return { id: "tr_2" }; } } };
  await processPayouts({ admin, stripe });
  assert.equal(created[0].source_transaction, undefined);
});

test("échec Stripe : le résultat est remonté, rien n'est marqué payé", async () => {
  const admin = fakeAdmin([{ payout_id: "p3", amount_cents: 1000, destination: "acct_3", intent_id: null }]);
  const stripe = { transfers: { create: async () => { throw new Error("Insufficient funds in Stripe account"); } } };
  const report = await processPayouts({ admin, stripe });
  assert.equal(report[0].outcome, "error");
  const result = admin.calls.find((c) => c.name === "secoto_payout_transfer_result");
  assert.equal(result.args.p_success, false);
  assert.match(result.args.p_error, /Insufficient funds/);
});

test("paiement client sans charge : versement suspendu, aucun transfert", async () => {
  const admin = fakeAdmin([{ payout_id: "p4", amount_cents: 1000, destination: "acct_4", intent_id: "pi_4" }]);
  let transferts = 0;
  const stripe = {
    paymentIntents: { retrieve: async () => ({ latest_charge: null }) },
    transfers: { create: async () => { transferts += 1; return { id: "x" }; } },
  };
  await processPayouts({ admin, stripe });
  assert.equal(transferts, 0);
});

test("décisions du 22/09/2026 écrites dans la migration", () => {
  assert.match(SQL, /'late_cancel_partner_pct', 45/);
  assert.match(SQL, /for update of pp skip locked/);
  assert.match(SQL, /in \('especes', 'espèces', 'cash'\)/);
  assert.match(SQL, /Paiement déclenché sous 48 h après la livraison/);
  assert.doesNotMatch(SQL, /versée par SECOTO sous 48 h/);
  assert.match(SQL, /insert into public\.secoto_feature_flags\(key\) values \('connect_payouts'\) on conflict \(key\) do nothing;/);
});

// Stripe rejoue pendant 24 h la reponse memorisee pour une cle d'idempotence,
// erreurs comprises : une cle figee bloquerait le transporteur une journee.
test("création du compte : la clé d'idempotence change d'heure en heure", () => {
  const source = readFileSync(new URL("../netlify/functions/connect-onboarding.js", import.meta.url), "utf8");
  const ligne = source.split("\n").find((l) => l.includes("secoto-connect-account-"));
  assert.ok(ligne, "la clé d'idempotence du compte Connect est introuvable");
  assert.match(ligne, /toISOString\(\)\.slice\(0, 13\)/);
});
