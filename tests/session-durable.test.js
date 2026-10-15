// SECOTO — l'utilisateur reste connecté (réveil du téléphone, réseau lent,
// déconnexion sur un autre appareil).
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { estErreurReseau, sessionEnregistree } from "../src/lib/sessionDurable.js";

const APP = readFileSync(new URL("../src/App.jsx", import.meta.url), "utf8");
const RUNTIME = readFileSync(new URL("../src/platform/runtime.js", import.meta.url), "utf8");

function stockage(entrees) {
  const cles = Object.keys(entrees);
  return { length: cles.length, key: (i) => cles[i], getItem: (k) => entrees[k] ?? null };
}

test("une session enregistrée est reconnue, sans réseau", () => {
  assert.equal(sessionEnregistree(stockage({ "sb-abc-auth-token": JSON.stringify({ access_token: "x", refresh_token: "r" }) })), true);
  assert.equal(sessionEnregistree(stockage({ "sb-abc-auth-token": "null" })), false);
  assert.equal(sessionEnregistree(stockage({ autre: "1" })), false);
  assert.equal(sessionEnregistree(stockage({ "sb-abc-auth-token": "{pas du json" })), false);
  assert.equal(sessionEnregistree(null), false);
});

test("seule une coupure réseau est traitée comme passagère", () => {
  assert.equal(estErreurReseau({ name: "AuthRetryableFetchError", message: "Failed to fetch" }), true);
  assert.equal(estErreurReseau({ message: "Load failed" }), true);
  assert.equal(estErreurReseau({ name: "AuthApiError", status: 400, message: "Invalid Refresh Token: Refresh Token Not Found" }), false);
  assert.equal(estErreurReseau(null), false);
});

test("se déconnecter sur un appareil ne déconnecte pas les autres", () => {
  assert.match(APP, /await supabase\.auth\.signOut\(\{ scope: "local" \}\);/);
  // Compte suspendu : la coupure reste générale.
  assert.match(APP, /status === "suspended"\) \{\s+await supabase\.auth\.signOut\(\);/);
});

test("réveil de l'app : rafraîchissement relancé, coupure réseau sans déconnexion", () => {
  assert.match(APP, /onResume: async \(\) => \{\s+supabase\.auth\.startAutoRefresh\(\);/);
  assert.match(APP, /if \(error && !data\?\.session\) return;/);
  assert.match(APP, /onPause: \(\) => \{ supabase\.auth\.stopAutoRefresh\(\); \}/);
  assert.match(RUNTIME, /if \(isActive\) onResume\?\.\(\);\r?\n\s+else onPause\?\.\(\);/);
});

test("démarrage lent : pas d'écran de connexion tant qu'une session est enregistrée", () => {
  assert.match(APP, /sessionEnregistree\(\) && Date\.now\(\) - debut < 30000/);
  assert.match(APP, /sessionEnregistree\(\) && estErreurReseau\(err\) && essais < 20/);
});
