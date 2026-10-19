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
  // Prix affiché : réservation express (nom + e-mail), sans formulaire d'inscription.
  // 099 : même bloc ; seul le libellé du bouton change quand des offres sont affichées.
  assert.match(BOOKING, /\{anonyme && <ReserverExpress( arrivee=\{arrivee\})? onConnexion=\{\(\) => onNeedAccount\?\.\(quote, "login"\)\}( libelle=\{[^}]+\})? \/>\}/);
  assert.match(BOOKING, /<CompteCta prix=\{false\} onCompte=/);
  assert.match(BOOKING, /onCompte\("signup"\)/);
  assert.match(BOOKING, /onCompte\("login"\)/);
  assert.match(BOOKING, /Déjà client \? Me connecter/);
  const EXPRESS = readFileSync(new URL("../src/ondemand/ReserverExpress.jsx", import.meta.url), "utf8");
  assert.match(EXPRESS, /"Réserver"/);
  assert.match(EXPRESS, /Déjà client \? Me connecter/);
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
