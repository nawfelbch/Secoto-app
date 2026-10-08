import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import { estNatif, urlRetour } from "../netlify/lib/retour-app.js";
import { onboardingLink } from "../netlify/functions/connect-onboarding.js";

const lire = (f) => readFileSync(new URL(`../${f}`, import.meta.url), "utf8");

test("retour Stripe : web inchangé, iPhone et Android via la passerelle", () => {
  const base = "https://app.secoto-transport.fr";
  assert.equal(urlRetour(base, "ecran=courses&commande=abc&paiement=ok", "web"), `${base}/?ecran=courses&commande=abc&paiement=ok`);
  assert.equal(urlRetour(base, "ecran=courses&paiement=ok", "ios"), `${base}/retour-app.html?ecran=courses&paiement=ok`);
  assert.equal(urlRetour(`${base}/`, "ecran=bank", "android"), `${base}/retour-app.html?ecran=bank`);
  assert.equal(estNatif("web"), false);
  assert.equal(estNatif(undefined), false);
});

test("inscription Stripe du transporteur : retour dans l'application sur mobile", async () => {
  const appels = [];
  const stripe = { accountLinks: { create: async (p) => { appels.push(p); return { url: "https://connect.stripe.com/x" }; } } };
  await onboardingLink(stripe, "acct_1", { platform: "ios" });
  await onboardingLink(stripe, "acct_1", {});
  assert.match(appels[0].return_url, /\/retour-app\.html\?ecran=bank&connect=retour$/);
  assert.match(appels[0].refresh_url, /\/retour-app\.html\?ecran=bank&connect=relancer$/);
  assert.match(appels[1].return_url, /\/\?ecran=bank&connect=retour$/);
});

test("la passerelle ne transmet que des écrans et identifiants autorisés", () => {
  const html = lire("public/retour-app.html");
  assert.match(html, /secoto:\/\/app/);
  assert.match(html, /var ECRANS = \[/);
  assert.match(html, /\^\[a-zA-Z0-9_-\]\{1,100\}\$/);
  assert.match(html, /noindex/);
  assert.match(html, /safe-area-inset-top/);
});

test("écrans plein écran : zones sûres iPhone / Android respectées", () => {
  for (const f of ["src/ConditionsGate.jsx", "src/MotDePasseProvisoire.jsx"]) {
    assert.match(lire(f), /<main className="app-shell">/, `${f}: hors du cadre qui gère l'encoche`);
  }
});

test("l'application transmet sa plateforme à l'inscription Stripe", () => {
  assert.match(lire("src/lib/onDemand.js"), /connect-onboarding", \{ action, platform: getPlatform\(\) \}/);
  assert.match(lire("src/lib/payments.js"), /googlePayIsTesting: String\(intent\.publishableKey \|\| ""\)\.startsWith\("pk_test_"\)/);
});

test("le lien secoto:// de la passerelle est compris par l'application", async () => {
  const { parseSecotoDeepLink } = await import("../src/lib/deepLinks.js");
  const lien = parseSecotoDeepLink("secoto://app?ecran=courses&commande=abc-123&paiement=ok");
  assert.equal(lien.kind, "navigation");
  assert.equal(lien.screen, "courses");
  assert.equal(lien.orderId, "abc-123");
  assert.equal(parseSecotoDeepLink("secoto://app?ecran=bank&connect=retour").kind, "navigation");
});
