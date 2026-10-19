// SECOTO 104 — un seul encaissement après la livraison.
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { debiterLivraison, fermerPaiementClient } from "../netlify/lib/reglement-livraison.js";

function fauxStripe({ session = null, intent = null, cancelEchoue = false, apresCancel = null } = {}) {
  const appels = [];
  return {
    appels,
    checkout: { sessions: {
      retrieve: async (id) => { appels.push(["session.retrieve", id]); return session; },
      expire: async (id) => { appels.push(["session.expire", id]); return { ...session, status: "expired" }; },
    } },
    paymentIntents: {
      retrieve: async (id) => { appels.push(["pi.retrieve", id]); return appels.some((a) => a[0] === "pi.cancel") && apresCancel ? apresCancel : intent; },
      cancel: async (id) => { appels.push(["pi.cancel", id]); if (cancelEchoue) throw new Error("déjà payé"); return { ...intent, status: "canceled" }; },
      create: async () => { appels.push(["pi.create"]); return { id: "pi_auto", status: "succeeded" }; },
    },
  };
}
const fauxAdmin = () => {
  const rpc = [];
  return { rpc: async (name, args) => { rpc.push([name, args]); return { data: { result: args.p_resultat === "reussi" ? "paid" : args.p_resultat } }; },
    from: () => ({ update: () => ({ eq: async () => ({}) }) }), appelsRpc: rpc };
};
const ligne = (extra = {}) => ({ payment_id: "p1", order_id: "o1", public_ref: "CMD-TEST", amount_cents: 69932, customer_id: "cus_1", payment_method_id: "pm_1", tentative: 0, ...extra });

test("le client a déjà payé (Klarna / carte) : constaté, aucun prélèvement automatique", async () => {
  const stripe = fauxStripe({ intent: { id: "pi_client", status: "succeeded" } });
  const admin = fauxAdmin();
  const r = await debiterLivraison({ admin, stripe, ligne: ligne({ client_intent_id: "pi_client" }) });
  assert.equal(r, "paid");
  assert.ok(!stripe.appels.some((a) => a[0] === "pi.create"), "pas de second débit");
  assert.equal(admin.appelsRpc[0][1].p_intent_id, "pi_client");
});

test("paiement client ouvert mais non réglé : fermé, puis prélèvement automatique", async () => {
  const stripe = fauxStripe({ intent: { id: "pi_client", status: "requires_payment_method" } });
  const r = await debiterLivraison({ admin: fauxAdmin(), stripe, ligne: ligne({ client_intent_id: "pi_client" }) });
  assert.equal(r, "paid");
  const ordre = stripe.appels.map((a) => a[0]);
  assert.ok(ordre.indexOf("pi.cancel") < ordre.indexOf("pi.create"), "fermeture AVANT le prélèvement");
});

test("le client paie pendant la fermeture : son paiement compte, pas de prélèvement", async () => {
  const stripe = fauxStripe({ intent: { id: "pi_client", status: "requires_confirmation" }, cancelEchoue: true, apresCancel: { id: "pi_client", status: "succeeded" } });
  assert.deepEqual(await fermerPaiementClient(stripe, ligne({ client_intent_id: "pi_client" })), { paye: "pi_client" });
});

test("page Stripe en cours (expiration refusée) ou paiement en traitement : on attend, rien n'est débité", async () => {
  const s1 = fauxStripe({ session: { status: "open", payment_status: "unpaid" } });
  s1.checkout.sessions.expire = async () => { throw new Error("payment in progress"); };
  assert.equal(await debiterLivraison({ admin: fauxAdmin(), stripe: s1, ligne: ligne({ client_session_id: "cs_1" }) }), "pending");
  const s2 = fauxStripe({ intent: { id: "pi_client", status: "processing" } });
  assert.equal(await debiterLivraison({ admin: fauxAdmin(), stripe: s2, ligne: ligne({ client_intent_id: "pi_client" }) }), "pending");
  assert.ok(![...s1.appels, ...s2.appels].some((a) => a[0] === "pi.create"));
  const s3 = fauxStripe({ session: { status: "complete", payment_status: "paid", payment_intent: "pi_cs" } });
  assert.equal(await debiterLivraison({ admin: fauxAdmin(), stripe: s3, ligne: ligne({ client_session_id: "cs_1" }) }), "paid");
});

test("« Payer maintenant » : refusé pendant un prélèvement en cours, paiement ouvert mémorisé", () => {
  const src = readFileSync(new URL("../netlify/functions/create-payment-intent.js", import.meta.url), "utf8");
  assert.match(src, /error: "debit_en_cours"/);
  assert.match(src, /memoriser\(\{ reglement_client_intent_id: intent\.id \}\)/);
  assert.match(src, /memoriser\(\{ reglement_client_session_id: session\.id \}\)/);
  const sql = readFileSync(new URL("../supabase/migrations/202610190104_reglement_sans_double_debit.sql", import.meta.url), "utf8");
  assert.match(sql, /'client_intent_id', pr\.reglement_client_intent_id/);
});
