import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { readFileSync } from "node:fs";

import {
  genericPushCopy,
  notificationRoute,
  secretMatches,
} from "../netlify/functions/send-mission-notifications.js";

test("le contenu d'écran verrouillé est générique et ne reprend aucune donnée métier sensible", () => {
  const known = genericPushCopy("course_assigned");
  const unknown = genericPushCopy("adresse=1 rue privée; prix=900; téléphone=0102");
  assert.deepEqual(known, {
    title: "SECOTO",
    body: "Une mission SECOTO nécessite votre attention.",
  });
  assert.deepEqual(unknown, {
    title: "SECOTO",
    body: "Une nouvelle information est disponible dans SECOTO.",
  });
  assert.equal(JSON.stringify([known, unknown]).includes("1 rue"), false);
  assert.equal(JSON.stringify([known, unknown]).includes("900"), false);
});

test("les routes push restent internes et les écrans inconnus sont neutralisés", () => {
  assert.equal(
    notificationRoute({ type: "document", push_screen: "documents", mission_id: "mission-1" }),
    "/?ecran=documents&mission=mission-1",
  );
  assert.equal(
    notificationRoute({ type: "info", push_screen: "https://evil.example", mission_id: null }),
    "/?ecran=courses",
  );
});

test("le secret interne est comparé sans accepter de préfixe ou valeur partielle", () => {
  assert.equal(secretMatches("secret-complet", "secret-complet"), true);
  assert.equal(secretMatches("secret", "secret-complet"), false);
  assert.equal(secretMatches("", "secret-complet"), false);
});

test("l'endpoint n'accepte plus cible, audience ou texte depuis le téléphone", async () => {
  const source = await readFile(
    new URL("../netlify/functions/send-mission-notifications.js", import.meta.url),
    "utf8",
  );
  for (const forbidden of [
    "payload.audience",
    "payload.accountId",
    "payload.transporterType",
    "payload.title",
    "payload.body",
    "payload.url",
    "payload.missionId",
  ]) {
    assert.equal(source.includes(forbidden), false, forbidden);
  }
});

test("102 : aperçu détaillé par défaut — titre et texte de la notification, sinon message générique", async () => {
  const { detailedPushCopy, genericPushCopy: generique } = await import("../netlify/functions/send-mission-notifications.js");
  assert.deepEqual(detailedPushCopy({ type: "order_update", title: "Mission mise à jour", body: "MIS-2026-11EF8B9A : SECOTO a modifié adresses." }),
    { title: "SECOTO · Mission mise à jour", body: "MIS-2026-11EF8B9A : SECOTO a modifié adresses." });
  assert.deepEqual(detailedPushCopy({ type: "payment", title: "", body: "" }), generique("payment"));
  const src = readFileSync(new URL("../netlify/functions/send-mission-notifications.js", import.meta.url), "utf8");
  assert.match(src, /prefs\?\.lockscreen_privacy === "masked" \? "masked" : "detailed"/);
  assert.match(src, /if \(prefs && prefs\.notify_offline === false\)/);
  const sql = readFileSync(new URL("../supabase/migrations/202610190102_notifications_apercu_detaille.sql", import.meta.url), "utf8");
  assert.match(sql, /alter column lockscreen_privacy set default 'detailed'/);
  assert.match(sql, /alter column notify_offline set default true/);
});
