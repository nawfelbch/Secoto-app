import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";

const source = (p) => readFile(new URL(p, import.meta.url), "utf8");

// 25/11/2026 : carburant et péages à la charge de SECOTO (158) -> le prix au km
// du convoyage doit les couvrir (utilitaire à 1 €/km = perte dès 60 km).
test("161 : nouvelle grille convoyage (voiture 1,15 / utilitaire 1,40 / moto 1,00 €/km)", async () => {
  const sql = await source("../supabase/migrations/202611250161_convoyage_frais_dans_le_prix.sql");
  assert.match(sql, /'\{class_rates,voiture,client_eur_per_km\}', to_jsonb\(1\.15\)/);
  assert.match(sql, /'\{class_rates,utilitaire,client_eur_per_km\}', to_jsonb\(1\.40\)/);
  assert.match(sql, /'\{class_rates,moto,client_eur_per_km\}', to_jsonb\(1\.00\)/);
  assert.doesNotMatch(sql, /partner_eur_per_km'?\}?', to_jsonb/, "rémunération des convoyeurs inchangée");
  assert.match(sql, /validate_grid_params\('convoyage'/);
  assert.match(sql, /<> 115000/);  // contrôle bloquant voiture 1 000 km
  assert.match(sql, /<> 84000/);   // contrôle bloquant utilitaire 600 km
  assert.match(sql, /<> 6000/);    // plancher 60 € inchangé
  const copie = await source("../deliverables/SECOTO-161-convoyage-frais-dans-le-prix-a-coller-dans-Supabase.sql");
  assert.equal(copie, sql);
});
