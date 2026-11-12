import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { GABARITS, classeDuGabarit, erreurDimensions } from "../src/lib/gabarits.js";

const sql = readFileSync(new URL("../supabase/migrations/202611120133_bareme_v3_gabarits_trois_offres.sql", import.meta.url), "utf8");

// Même formule que secoto_private.bareme_v3 (contrôle des chiffres validés).
const R = { forfait: 60, tranches: [[300, 0.95], [700, 0.80], [Infinity, 0.70]], util: [[300, 0.95], [700, 0.95], [Infinity, 0.90]] };
const G = { citadine: [1.0, 245], berline: [1.10, 265], grand: [1.25, 295], utilitaire: [1.40, 450], moto: [0.75, 220], caravane: [1.40, 450] };
function prix(gab, km) {
  let pay = R.forfait, prev = 0;
  for (const [max, eur] of gab === "utilitaire" ? R.util : R.tranches) { if (km <= prev) break; pay += (Math.min(km, max) - prev) * eur; prev = max; }
  pay *= G[gab][0];
  const client = Math.max(G[gab][1], pay + 75, pay / 0.83);
  return Math.round(client);
}

test("133 : chiffres du barème validé (Standard, sans ajustement d'axe)", () => {
  assert.equal(prix("citadine", 30), 245);
  assert.equal(prix("citadine", 300), 420);
  assert.equal(prix("berline", 550), 722);
  assert.equal(prix("grand", 900), 1212);
  assert.equal(prix("utilitaire", 550), 983);
  assert.equal(prix("utilitaire", 900), 1527);
  assert.equal(prix("caravane", 150), 450);
  assert.equal(prix("caravane", 900), 1358);
  assert.equal(prix("moto", 30), 220);
});

test("133 : réglages en base fidèles à la décision", () => {
  for (const s of ["'marge_min_eur', 75", "'citadine',    jsonb_build_object('coef', 1.00, 'minimum_eur', 245",
    "'utilitaire',  jsonb_build_object('coef', 1.40, 'minimum_eur', 450", "'caravane',    jsonb_build_object('coef', 1.40, 'minimum_eur', 450",
    "'camping_car', jsonb_build_object('coef', 1.40, 'minimum_eur', 450", "'poids_majore_kg', 3000, 'poids_majoration_pct', 20",
    "'longueur_majoree_m', 7, 'longueur_majoration_pct', 10", "'axe_pct', -5", "'hors_zone_pct', 5", "'berline',     jsonb_build_object('coef', 1.10, 'minimum_eur', 265, 'non_roulant_eur', 70, 'eco_plafond_eur', 600)"]) {
    assert.ok(sql.includes(s), s);
  }
  assert.match(sql, /sur_devis_poids_lourd/);
  assert.match(sql, /sur_devis_plus_3_5_t/);
});

test("133 : Éco toujours proposée, jamais pour caravane / camping-car, moto seulement sur l'axe", () => {
  assert.doesNotMatch(sql.split("create or replace function secoto_private.calculer_offres")[1], /v_seuil/);
  assert.match(sql, /'coef', jsonb_build_object\('citadine', 1\.0, 'berline', 1\.0, 'grand', 1\.2, 'utilitaire', 1\.2, 'moto', 0\.8\)/);
  assert.match(sql, /v_gab = 'moto' and not secoto_private\.plafond_applicable\('moto'/);
  assert.match(sql, /Vous déposez|vous déposez votre véhicule/);
});

test("133 : formulaire — types de véhicule et dimensions obligatoires", () => {
  assert.equal(classeDuGabarit("caravane"), "autre");
  assert.equal(classeDuGabarit("citadine"), "voiture");
  assert.ok(GABARITS.some((g) => g.label.includes("Twingo")));
  assert.match(erreurDimensions({ gabarit: "caravane" }), /poids/);
  assert.match(erreurDimensions({ gabarit: "camping_car", weight_kg: "2800" }), /longueur/);
  assert.match(erreurDimensions({ gabarit: "caravane", weight_kg: "1600", length_m: "7" }), /hauteur/);
  assert.equal(erreurDimensions({ gabarit: "caravane", weight_kg: "1600", length_m: "7", height_m: "2,6" }), "");
  assert.equal(erreurDimensions({ gabarit: "berline" }), "");
  assert.match(readFileSync(new URL("../src/lib/onDemand.js", import.meta.url), "utf8"), /sur_devis_poids_lourd:/);
});
