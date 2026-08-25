import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const payments = readFileSync(new URL("../src/lib/payments.js", import.meta.url), "utf8");
const paymentScreen = readFileSync(new URL("../src/PaymentScreen.jsx", import.meta.url), "utf8");
const intent = readFileSync(
  new URL("../netlify/functions/create-payment-intent.js", import.meta.url),
  "utf8",
);
const webhook = readFileSync(
  new URL("../netlify/functions/stripe-webhook.js", import.meta.url),
  "utf8",
);
const paymentMigration = readFileSync(
  new URL(
    "../supabase/migrations/202608170009_paiement_bareme_notifications.sql",
    import.meta.url,
  ),
  "utf8",
);
const migration = readFileSync(
  new URL("../supabase/migrations/202608250013_release_reliability.sql", import.meta.url),
  "utf8",
);
const css = readFileSync(new URL("../src/index.css", import.meta.url), "utf8");
const main = readFileSync(new URL("../src/main.jsx", import.meta.url), "utf8");

test("le paiement natif utilise l'URL HTTPS des fonctions et distingue les conflits", () => {
  assert.match(payments, /getServerFunctionUrl\("create-payment-intent"\)/);
  assert.doesNotMatch(payments, /const INTENT_ENDPOINT/);
  assert.match(payments, /body\.error === "already_paid"/);
  assert.match(payments, /body\.error === "payment_not_payable"/);
});

test("la feuille Stripe reste utilisable sans carte enregistrée", () => {
  assert.match(payments, /const customerOptions = intent\.ephemeralKey/);
  assert.match(payments, /\.\.\.customerOptions/);
  assert.match(intent, /idempotencyKey: `secoto-customer-\$\{userId\}`/);
});

test("le téléphone ne choisit jamais le montant et ne peut pas valider lui-même le paiement", () => {
  assert.match(intent, /\.from\("payments"\)[\s\S]*?\.eq\("id", paymentId\)/);
  assert.match(intent, /payment\.account_id !== userId/);
  assert.match(intent, /amount: payment\.amount_cents/);
  assert.doesNotMatch(intent, /amount:\s*payload\./);
  assert.match(webhook, /stripe\.webhooks\.constructEvent\(rawBody\(event\), signature/);
  assert.match(webhook, /secoto_settle_payment/);
  assert.match(
    paymentMigration,
    /grant execute on function public\.secoto_settle_payment\([\s\S]*?to service_role/,
  );
  assert.match(
    paymentMigration,
    /if v_payment\.purpose = 'commission_plateau' then[\s\S]*?secoto_release_mission_order/,
  );
});

test("la confirmation de paiement survit à une coupure du temps réel", () => {
  assert.match(paymentScreen, /\["pending", "processing"\]\.includes\(payment\.status\)/);
  assert.match(paymentScreen, /fetchPayment\(payment\.id\)/);
  assert.match(paymentScreen, /window\.setInterval/);
  assert.match(paymentScreen, /\["failed", "cancelled"\]/);
});

test("le code mission permet de reconnecter uniquement le client déjà lié", () => {
  assert.match(migration, /v_claim\.status::text not in \('pending', 'claimed'\)/);
  assert.match(migration, /v_claim\.claimed_by_account_id is distinct from p_account_id/);
  assert.match(migration, /v_mission\.client_account_id is distinct from p_account_id/);
});

test("l'enveloppe native est bord à bord avec protection Dynamic Island", () => {
  assert.match(main, /dataset\.nativePlatform/);
  assert.match(css, /html\[data-native-platform\] \.app-shell/);
  assert.match(css, /env\(safe-area-inset-top/);
  assert.match(css, /width: 100%/);
  assert.match(css, /border-radius: 0/);
});
