import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dateCourte, dateMinStandard, expressObligatoire, offreAutorisee } from "../src/lib/offres.js";

const NOW = new Date("2026-11-09T21:00:00").getTime();
const offres = [{ cle: "express" }, { cle: "standard", recommande: true }, { cle: "eco" }];

test("132 : départ à moins de 48 h -> Express obligatoire", () => {
  assert.equal(expressObligatoire({ pickup_at: new Date("2026-11-10T08:00:00").toISOString() }, NOW), true);
  assert.equal(expressObligatoire({ pickup_at: new Date("2026-11-11T08:00:00").toISOString() }, NOW), true);
  assert.equal(expressObligatoire({ pickup_at: new Date("2026-11-12T08:00:00").toISOString() }, NOW), false);
  assert.equal(expressObligatoire({ schedule: { pickup_date: "2026-11-10" } }, NOW), true);
  assert.equal(expressObligatoire({}, NOW), false);
  // La base fait foi quand elle répond.
  assert.equal(expressObligatoire({ express_obligatoire: false, pickup_at: new Date("2026-11-10T08:00:00").toISOString() }, NOW), false);
});

test("132 : date à partir de laquelle le Standard redevient possible", () => {
  assert.equal(dateMinStandard({ pickup_at: new Date("2026-11-10T08:00:00").toISOString() }, NOW), "2026-11-12");
  assert.equal(dateMinStandard({ standard_des: "2026-11-13" }, NOW), "2026-11-13");
  assert.equal(dateCourte("2026-11-12"), "12/11");
});

test("132 : l'offre retenue est forcée sur Express, jamais Standard", () => {
  assert.equal(offreAutorisee(offres, "standard", true), "express");
  assert.equal(offreAutorisee(offres, "standard", false), "standard");
  assert.equal(offreAutorisee([{ cle: "standard" }], "standard", true), null);
});

test("132 : la base refuse Standard / Éco à moins de 48 h et l'écran grise l'offre", () => {
  const sql = readFileSync(new URL("../supabase/migrations/202611090132_express_obligatoire_moins_48h.sql", import.meta.url), "utf8");
  assert.match(sql, /p_offre <> ''express'' and secoto_private\.express_obligatoire\(v_quote\)/);
  assert.match(sql, /interval '48 hours'/);
  assert.match(sql, /''express_obligatoire'', secoto_private\.express_obligatoire\(q\)/);
  const cartes = readFileSync(new URL("../src/ondemand/OffresCartes.jsx", import.meta.url), "utf8");
  assert.match(cartes, /is-grise/);
  assert.match(cartes, /Changer la date/);
  const booking = readFileSync(new URL("../src/ondemand/OnDemandBooking.jsx", import.meta.url), "utf8");
  assert.match(booking, /bookQuoteOffre\(quote\.id, offreRetenue\)/);
});
