// Migration 048 — plafond de rémunération par catégorie.
// Au plafond client de 400 €, la part transporteur suivait la même proportion
// (340 €) : une moto Lille-Nice rapportait 60 € à SECOTO, comme une moto
// Paris-Rouen, pour un risque et un suivi bien supérieurs.
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const SQL48 = readFileSync(new URL("../supabase/migrations/202609270048_plafond_remuneration_moto.sql", import.meta.url), "utf8");

test("le calcul borne la rémunération, après le plancher", () => {
  const calcul = SQL48.slice(SQL48.indexOf("$patch$"), SQL48.indexOf("$garde$"));
  assert.match(calcul, /v_partner > \(v_rule ->> ''partner_cap_eur''\)::numeric/);
  // Repère structurel, pas un commentaire accentué : posé juste avant le bloc
  // « urgence », donc après le plafond client et le forfait minimum.
  assert.match(calcul, /if v_urgent_pct > 0/);
  assert.match(calcul, /correctif non applique/);
});

test("la moto plafonne à 300 € côté transporteur, sans toucher au prix client", () => {
  assert.match(SQL48, /jsonb_build_object\('partner_cap_eur', 300\)/);
  assert.doesNotMatch(SQL48, /client_cap_eur', 3\d\d/);
  // La grille est versionnée, pas écrasée : l'historique des prix est conservé.
  assert.match(SQL48, /update public\.pricing_grids set status = 'archived'/);
  assert.match(SQL48, /coalesce\(max\(version\), 0\) \+ 1/);
});

test("un plafond absurde est refusé à l'écriture", () => {
  assert.match(SQL48, /plafond de remuneration absurde/);
  assert.match(SQL48, />= \(v_rule ->> ''client_cap_eur''\)::numeric/);
});

test("le script est rejouable et refuse de s'appliquer à l'aveugle", () => {
  assert.equal((SQL48.match(/position\('partner_cap_eur' in v_src\) > 0/g) || []).length, 2);
  // Le controle d'ecriture est un confort : il previent au lieu de bloquer.
  assert.match(SQL48, /controle non pose, le plafond reste applique/);
  assert.match(SQL48, /appliquez d''abord la migration 034/);
  assert.match(SQL48, /Point d''insertion introuvable/);
});
