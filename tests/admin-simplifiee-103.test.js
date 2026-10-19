// SECOTO 103 — administration simplifiée.
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const lire = (f) => readFileSync(new URL(`../${f}`, import.meta.url), "utf8");

test("distance admin : coordonnées gardées, sinon géocodage de l'adresse", async () => {
  const { resoudrePoint } = await import("../netlify/functions/admin-route.js");
  assert.deepEqual(await resoudrePoint({ lat: 48.9, lng: 2.5, country: "FR" }), { lat: 48.9, lng: 2.5, country: "FR" });
  assert.deepEqual(await resoudrePoint({ label: "12 rue Test Villepinte" }, async (l) => ({ lat: 1, lng: 2, l })), { lat: 1, lng: 2, l: "12 rue Test Villepinte" });
  assert.equal(await resoudrePoint({}), null);
  const src = lire("netlify/functions/admin-route.js");
  assert.match(src, /compte\?\.role !== "admin"\) return json\(403/);
});

test("admin : « Demandes » disparaît, « À la demande » en tête, À traiter en tuiles, recherche, cartes repliées", () => {
  const app = lire("src/App.jsx");
  assert.doesNotMatch(app, /key: "requests", label: "Demandes"/);
  assert.doesNotMatch(app, /label: "Proposer une mission"/);
  assert.doesNotMatch(app, /label: "Mes demandes"/);
  assert.ok(app.indexOf('key: "ondemand", label: "À la demande"') < app.indexOf('key: "create", label: "Créer une mission"'));
  assert.match(app, /className="a-traiter-tuile"/);
  assert.equal((app.match(/\{rechercheMissionChamp\}/g) || []).length, 3);
  assert.match(app, /<details className="mission-details"/);
  assert.match(app, /<DistanceAuto form=\{form\} setForm=\{setForm\} \/>/);
  const od = lire("src/ondemand/AdminOnDemand.jsx");
  assert.match(od, /⚡ Prix du barème/);
  assert.match(od, /<details className="od-avance">/);
  assert.match(od, /useState\(ongletInitial\)/);
});
