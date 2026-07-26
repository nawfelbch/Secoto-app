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
