import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const sql = readFileSync(new URL("../supabase/migrations/202611170149_grille_lourds_pro_multi.sql", import.meta.url), "utf8");

// Copie JS de lourds_offre_cents (vérifiée en production : 985 / 1 085 / 900 / 990 à 447 km).
const cinq = (n) => Math.ceil(Math.round(n * 100) / 100 / 5) * 5;
function lourds(pay, km, pro, express, std) {
  const k = pro ? 0.015 : 0.05, u = 0.212;
  const rate = pro ? (express ? 2.2 : 2.0) : (express ? 2.4 : 2.2);
  const plancher = cinq((75 + (1 - u) * pay) / (1 - k - u));
  if (express) return Math.max(plancher, cinq(km * rate), cinq(std * 1.1));
  return Math.max(plancher, cinq(km * rate), pro ? 500 : 550);
}

test("149 : réglages de la grille (2,20 / 2,40 particulier, 2,00 / 2,20 pro, minimums, voitures)", () => {
  for (const k of ["'client_eur_km', 2.20", "'client_express_eur_km', 2.40", "'client_min_eur', 550", "'pro_eur_km', 2.00",
    "'pro_express_eur_km', 2.20", "'pro_min_eur', 500", "'express_transporteur_coef', 1.10", "'groupe_remise_pct', 10",
    "'eur_km', 0.98", "'eur_km', 0.85", "'eur_km', 0.75"]) assert.ok(sql.includes(k), k);
});

test("149 : prix lourds identiques à l'aperçu en production, toujours ≥ 75 € nets", () => {
  assert.equal(lourds(785, 447, false, false), 985);
  assert.equal(lourds(Math.round(785 * 1.1), 447, false, true, 985), 1085);
  assert.equal(lourds(785, 447, true, false), 900);
  assert.equal(lourds(Math.round(785 * 1.1), 447, true, true, 900), 990);
  assert.equal(lourds(375, 100, false, false), 550);
  for (const [pay, km] of [[375, 100], [700, 345], [785, 447], [1571, 930]]) {
    const p = lourds(pay, km, false, false);
    assert.ok(p * 0.95 - pay - 0.212 * (p - pay) >= 75 - 1e-9, `${km} km`);
  }
});

test("149 : plusieurs véhicules au barème v3 avec −10 % dès le 2e, rustine 148 en secours", () => {
  assert.match(sql, /create or replace function secoto_private\.bareme_v3_groupe/);
  assert.match(sql, /if v\.rang > 1 then/);
  assert.match(sql, /if c2 - p2 < v_marge_min then p2 := c2 - v_marge_min; end if;/);
  assert.match(sql, /if not coalesce\(\(v_price ->> 'groupe_v3'\)::boolean, false\) then v_reason := 'sur_devis_plusieurs_lourds'/);
  assert.match(sql, /if v_pro then v_std_client := secoto_private\.lourds_offre_cents\(v_std_pay, v_km, true, false\)/);
});
