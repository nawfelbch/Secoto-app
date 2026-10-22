// SECOTO 105-106 — Klarna sous le prix, relances branchées sur la maintenance.
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { klarnaSousPrix } from "../src/lib/orderCopy.js";

const lire = (f) => readFileSync(new URL(`../${f}`, import.meta.url), "utf8");

test("Klarna sous le prix : exemple en 3 fois, jamais promis, rien sous 35 €", () => {
  assert.match(klarnaSousPrix(69932), /^ou en plusieurs fois avec Klarna, par exemple 3 × 233,11\s?€, à la livraison$/);
  assert.equal(klarnaSousPrix(2000), "");
  assert.match(lire("src/ondemand/OffresCartes.jsx"), /klarna && klarnaSousPrix\(o\.client_cents\)/);
  assert.match(lire("src/ondemand/OnDemandBooking.jsx"), /klarna=\{arrivee\}/);
});

test("relances et zéro devis manuel : branchés et réglables", () => {
  assert.match(lire("netlify/functions/od-maintenance.js"), /secoto_devis_relances/);
  const m105 = lire("supabase/migrations/202610200105_zero_devis_manuel.sql");
  for (const motif of ["luxury_pct", "constraint_client_eur", "short_notice_pct", "od_distance_estimee", "od_hors_zone", "Ajustement tarifaire"]) {
    assert.ok(m105.includes(motif), motif);
  }
  // 116 : « à rappeler » devient « à prévenir par message ».
  assert.match(lire("src/App.jsx"), /devis à prévenir par message \(téléphone seul\)/);
});
