import test from "node:test";
import assert from "node:assert/strict";

import { buildMissionPath, parseSecotoDeepLink } from "../src/lib/deepLinks.js";

test("un lien de notification ouvre uniquement un écran et une mission autorisés", () => {
  assert.deepEqual(
    parseSecotoDeepLink("https://app.secoto-transport.fr/?ecran=documents&mission=mission-123"),
    { kind: "navigation", screen: "documents", missionId: "mission-123" },
  );
  assert.equal(buildMissionPath("mission-123", "frais"), "/?ecran=frais&mission=mission-123");
});

test("les hôtes externes et identifiants malveillants sont rejetés ou neutralisés", () => {
  assert.equal(parseSecotoDeepLink("https://evil.example/?ecran=documents&mission=1"), null);
  assert.deepEqual(
    parseSecotoDeepLink("secoto://app/?ecran=admin&mission=../../secret"),
    { kind: "navigation", screen: "courses", missionId: null },
  );
});

test("les callbacks Auth natifs PKCE sont distingués de la navigation métier", () => {
  assert.deepEqual(
    parseSecotoDeepLink("secoto://auth/callback?code=pkce-code"),
    { kind: "auth", code: "pkce-code", authType: null },
  );
  assert.deepEqual(
    parseSecotoDeepLink("secoto://auth/callback?type=recovery"),
    { kind: "auth", code: null, authType: "recovery" },
  );
});

test("un lien client SECOTO est distingué des liens de navigation", () => {
  assert.deepEqual(
    parseSecotoDeepLink(
      "https://app.secoto-transport.fr/?claim=ABCDEFGHIJKLMNOPQRSTUVWXYZabcdef&ref=MIS-2026-TEST",
    ),
    {
      kind: "claim",
      claimToken: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdef",
      claimCode: null,
      publicRef: "MIS-2026-TEST",
    },
  );

  assert.deepEqual(
    parseSecotoDeepLink(
      "secoto://auth/callback?code=pkce-code&claim=ABCDEFGHIJKLMNOPQRSTUVWXYZabcdef&ref=MIS-2026-TEST",
    ),
    {
      kind: "auth",
      code: "pkce-code",
      authType: null,
      claimToken: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdef",
      publicRef: "MIS-2026-TEST",
    },
  );
});
test("2.3.6 : retour Klarna / Satispay reconnu et remis au SDK Stripe, jamais traité comme une navigation", async () => {
  const { STRIPE_RETURN_URL, isStripeReturnUrl } = await import("../src/lib/deepLinks.js");
  assert.equal(STRIPE_RETURN_URL, "secoto://stripe-redirect");
  assert.equal(isStripeReturnUrl("secoto://stripe-redirect?payment_intent=pi_1&redirect_status=succeeded"), true);
  assert.equal(isStripeReturnUrl("secoto://app?ecran=courses"), false);
  assert.equal(isStripeReturnUrl("https://app.secoto-transport.fr/?ecran=courses"), false);
  assert.equal(isStripeReturnUrl(null), false);
});

test("2.3.6 : la feuille de paiement reçoit l'adresse de retour, la liste verticale et les coordonnées", async () => {
  const { readFileSync } = await import("node:fs");
  const src = readFileSync(new URL("../src/lib/payments.js", import.meta.url), "utf8");
  assert.match(src, /returnURL: STRIPE_RETURN_URL/);
  assert.match(src, /paymentMethodLayout: "vertical"/);
  assert.match(src, /defaultBillingDetails: intent\.billing/);
  assert.match(src, /feuilleKlarna: true/);
  const runtime = readFileSync(new URL("../src/platform/runtime.js", import.meta.url), "utf8");
  assert.match(runtime, /isStripeReturnUrl\(rawUrl\)[\s\S]{0,200}handleURLCallback/);
});
