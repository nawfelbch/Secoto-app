// Course réservée mais non réglée (correctif 051).
// Sur iPhone, le client qui venait de créer son compte retrouvait sa course
// dans « Mes commandes » et devait aller l'y chercher pour payer : trop
// d'étapes pour quelqu'un qui pensait avoir fini.
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const BANDEAU = readFileSync(new URL("../src/ondemand/PaiementAFinaliser.jsx", import.meta.url), "utf8");
const APP = readFileSync(new URL("../src/App.jsx", import.meta.url), "utf8");

test("le bandeau ne propose qu'une seule action : payer", () => {
  assert.match(BANDEAU, /Payer \$\{montant\}/);
  // Aucune navigation, aucun second bouton concurrent.
  assert.doesNotMatch(BANDEAU, /Voir ma commande|Annuler|Suivre/);
});

test("il ne s'affiche que pour une course réellement à régler", () => {
  assert.match(BANDEAU, /o\.funding === "card"/);
  assert.match(BANDEAU, /\["awaiting_payment"\]\.includes\(o\.status\)/);
  assert.match(BANDEAU, /if \(\["paid", "requires_capture"\]\.includes\(paiement\.status\)\) return null/);
});

test("il disparaît dès l'encaissement, sans rechargement", () => {
  assert.match(BANDEAU, /watchPayment\(paiement\.id/);
  assert.match(BANDEAU, /setCommande\(null\);\s*\n\s*onPaid\?\.\(\)/);
});

test("la renonciation reste exigée et jamais pré-cochée", () => {
  assert.match(BANDEAU, /useState\(false\); \/\/ jamais pré-cochée/);
  assert.match(BANDEAU, /acceptPaymentWaiver\(paiement\.id\)/);
  assert.match(BANDEAU, /if \(!renonciation\)/);
});

test("un bandeau de confort ne casse pas l'écran qui le porte", () => {
  assert.match(BANDEAU, /catch \{\s*\n\s*\/\/ Un bandeau de confort/);
  assert.match(BANDEAU, /if \(!commande \|\| !paiement\) return null/);
});

test("il suit le client partout, sauf là où le paiement est déjà à l'écran", () => {
  assert.match(APP, /isClient && activeClientTab !== "ondemand" && \(/);
  assert.match(APP, /<PaiementAFinaliser onPaid=/);
});
