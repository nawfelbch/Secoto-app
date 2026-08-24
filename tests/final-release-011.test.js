import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

function source(path) {
  return readFileSync(new URL(`../${path}`, import.meta.url), "utf8");
}

test("le formulaire ne propose plus les suppléments supprimés", () => {
  const app = source("src/App.jsx");
  assert.doesNotMatch(app, /Week-end \(\+20 %\)/);
  assert.doesNotMatch(app, /Gros gabarit \/ véhicule premium/);
});

test("l’accès client échange téléphone et code contre une session normale", () => {
  const claims = source("src/lib/missionClaims.js");
  const endpoint = source("netlify/functions/client-mission-access.js");
  assert.match(claims, /signInWithMissionAccess/);
  assert.match(claims, /supabase\.auth\.verifyOtp/);
  assert.match(endpoint, /secoto_prepare_client_phone_access/);
  assert.match(endpoint, /secoto_complete_client_phone_access/);
  assert.match(endpoint, /SUPABASE_SERVICE_ROLE_KEY/);
  assert.doesNotMatch(claims, /SERVICE_ROLE/);
});

test("la migration limite les essais et réserve les RPC au service serveur", () => {
  const sql = source("supabase/migrations/202608240011_client_access_final.sql");
  assert.match(sql, /client_access_attempts/);
  assert.match(sql, /ACCESS_RATE_LIMITED/);
  assert.match(sql, /to service_role/);
  assert.match(sql, /from public, anon, authenticated/);
});

test("les textes légaux corrigés sont disponibles même avant la migration SQL", () => {
  const legal = source("src/lib/legalCopy.js");
  assert.match(legal, /règle la mise en relation/);
  assert.match(legal, /exécution complète/);
  assert.match(legal, /droit de rétractation/);
});

test("iOS demande l’autorisation native pour tout état non accordé", () => {
  const push = source("src/push.js");
  assert.match(push, /permission\.receive !== "granted"/);
  assert.match(push, /PushNotifications\.requestPermissions\(\)/);
  assert.equal(source("capacitor.config.json").includes('"appId": "fr.secoto.app"'), true);
});
