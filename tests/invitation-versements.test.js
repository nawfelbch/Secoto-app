// Invitation à activer les versements (correctif 044).
// Un transporteur pouvait accepter une course, la livrer, et n'avoir aucun
// moyen d'être payé automatiquement : rien ne le prévenait.
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const APP = readFileSync(new URL("../src/App.jsx", import.meta.url), "utf8");

test("l'état des versements n'est lu que pour un transporteur, flag ouvert", () => {
  const effet = APP.slice(APP.indexOf('connectOnboarding("status")') - 600, APP.indexOf('connectOnboarding("status")') + 200);
  assert.match(effet, /account\.role !== "transporter" \|\| !flags\.connect_payouts/);
});

test("seul « actif » dispense de l'invitation", () => {
  assert.match(APP, /versements !== "active"/);
});

test("la redirection n'a lieu qu'une fois", () => {
  assert.match(APP, /if \(versementsAConfigurer && !dejaInviteAuxVersements\(\)\)/);
  assert.match(APP, /marquerInvitationVersements\(\)/);
  // La mémoire du navigateur peut être indisponible : jamais d'écran bloqué.
  assert.match(APP, /catch \{ return true; \}/);
  assert.match(APP, /catch \{ \/\* navigation privee \*\/ \}/);
});

test("le message explique pourquoi, pas seulement quoi", () => {
  assert.match(APP, /SECOTO ne peut pas vous virer votre rémunération 48 h après la livraison/);
});

test("le bandeau reste tant que ce n'est pas fait, et s'efface sur l'écran concerné", () => {
  assert.match(APP, /versementsAConfigurer && transporterTab !== "bank"/);
  assert.match(APP, /Activer mes versements/);
  // Une vérification Stripe en cours ne doit pas être présentée comme un oubli.
  assert.match(APP, /versements === "pending"/);
});
