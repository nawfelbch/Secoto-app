import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const composant = readFileSync(new URL("../src/ondemand/RenonciationRetractation.jsx", import.meta.url), "utf8");
const reservation = readFileSync(new URL("../src/ondemand/OnDemandBooking.jsx", import.meta.url), "utf8");
const finaliser = readFileSync(new URL("../src/ondemand/PaiementAFinaliser.jsx", import.meta.url), "utf8");

test("case de rétractation : texte rassurant, sans date précise promise", () => {
  assert.match(composant, /organise mon transport dès maintenant, sans attendre la fin du délai légal de rétractation de 14 jours/);
  assert.match(composant, /La date indiquée est une date souhaitée, confirmée ensuite avec le transporteur/);
  assert.doesNotMatch(composant, /renonce expressément/);
  assert.doesNotMatch(composant, /à la date choisie/);
});

test("« rien n'est prélevé aujourd'hui » seulement pour un règlement à l'arrivée", () => {
  assert.match(composant, /\{arrivee && " Rien n’est prélevé aujourd’hui/);
  assert.match(reservation, /<RenonciationRetractation checked=\{waiver\} onChange=\{setWaiver\} arrivee=\{arrivee\} \/>/);
  assert.match(finaliser, /arrivee=\{commande\.debit_a_livraison === true\}/);
});

test("case jamais pré-cochée", () => {
  assert.match(composant, /checked=\{checked\}/);
  assert.match(finaliser, /useState\(false\); \/\/ jamais pré-cochée/);
});
