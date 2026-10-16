// SECOTO — Après chaque demande sans compte : créer son compte ou se
// connecter saute aux yeux, en une action, et l'écran de compte rappelle
// la demande (trajet, prix).
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { repriseDepuisDevis } from "../src/lib/repriseLien.js";

const BOOKING = readFileSync(new URL("../src/ondemand/OnDemandBooking.jsx", import.meta.url), "utf8");
const APP = readFileSync(new URL("../src/App.jsx", import.meta.url), "utf8");
const CSS = readFileSync(new URL("../src/index.css", import.meta.url), "utf8");

test("rappel de la demande : trajet + prix si tarifé, trajet seul sinon", () => {
  const q = { pickup: { city: "Digne-les-Bains" }, delivery: { city: "Ollioules" }, status: "priced", client_price_cents: 30452 };
  assert.deepEqual(repriseDepuisDevis(q), { trajet: "Digne-les-Bains → Ollioules", prixCents: 30452 });
  assert.deepEqual(repriseDepuisDevis({ ...q, status: "manual_review", client_price_cents: null }), { trajet: "Digne-les-Bains → Ollioules", prixCents: null });
  assert.equal(repriseDepuisDevis(null), null);
});

test("bloc compte sous le prix ET sous chaque demande en devis personnalisé", () => {
  assert.match(BOOKING, /function CompteCta\(\{ prix, onCompte \}\)/);
  assert.match(BOOKING, /\{anonyme && <CompteCta prix onCompte=\{\(mode\) => onNeedAccount\?\.\(quote, mode\)\} \/>\}/);
  assert.match(BOOKING, /<CompteCta prix=\{false\} onCompte=/);
  assert.match(BOOKING, /onCompte\("signup"\)/);
  assert.match(BOOKING, /onCompte\("login"\)/);
  assert.match(BOOKING, /Déjà client \? Me connecter/);
  // Prix obtenu : un seul mot d'action, « Réserver ».
  assert.match(BOOKING, /\{prix \? "Réserver" : "Créer mon compte gratuit"\}/);
  // Plus de bouton « facultatif » discret.
  assert.doesNotMatch(BOOKING, /\(facultatif\)/);
  assert.match(CSS, /\.od-compte-btn \{ width: 100%; min-height: 52px;/);
});

test("écran de compte : ouvert sur le bon onglet, deux onglets seulement, demande rappelée", () => {
  assert.match(APP, /onNeedAccount=\{\(quote, mode\) => \{\s+setEntree\(\{ mode: mode === "login" \? "login" : "signup", reprise: repriseDepuisDevis\(quote\) \}\);/);
  assert.match(APP, /repriseLien=\{claimMode \? null : entree\?\.reprise \|\| repriseLien\}/);
  assert.match(APP, /: repriseLien\s+\? \[\s+\{ value: "signup", label: "Créer un compte" \},\s+\{ value: "login", label: "Connexion" \},\s+\]/);
  // « Retour » ne perd pas le prix : la page de demande reste montée.
  assert.match(APP, /\{\(!surCompte \|\| entree\) && <div hidden=\{surCompte\}>\{landing\}<\/div>\}/);
});
