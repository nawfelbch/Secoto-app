// ============================================================================
// SECOTO 057-058 — le plafond client moto est a 382 EUR, et le groupage rend
// une part de la marge SECOTO sur chaque vehicule a partir de deux, en plateau
// seulement, sans jamais toucher a la remuneration du transporteur.
// ============================================================================
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const PLAFOND = readFileSync(
  new URL("../supabase/migrations/202609280057_plafond_client_moto_382.sql", import.meta.url),
  "utf8",
);
const SQL = readFileSync(
  new URL("../supabase/migrations/202609280058_groupage_client_plateau.sql", import.meta.url),
  "utf8",
);

test("le plafond client moto passe a 382 EUR sans toucher a la remuneration", () => {
  assert.match(PLAFOND, /'\{class_rates,moto,client_cap_eur\}', to_jsonb\(382::numeric\)/);
  assert.match(PLAFOND, /<> 38200/); // prix client plafonne
  assert.match(PLAFOND, /<> 30000/); // remuneration transporteur inchangee
  assert.doesNotMatch(PLAFOND, /partner_cap_eur/); // le plafond partenaire n'est pas retouche
});

test("la fonction de groupage existe et reste additive", () => {
  assert.match(SQL, /create or replace function secoto_private\.price_group_with_grid\(/);
  assert.doesNotMatch(SQL, /create or replace function secoto_private\.price_with_grid\(/);
  assert.doesNotMatch(SQL, /drop function/i);
});

test("la remise vaut 40 %, 20 % sur utilitaire, et ne s'applique qu'en plateau", () => {
  assert.match(SQL, /case when v_classe = 'utilitaire' then 20 else 40 end/);
  assert.match(SQL, /v_groupe := \(p_mode = 'plateau'\)/);
  assert.match(SQL, /v_reduction := floor\(\(v_unitaire ->> 'margin_cents'\)::numeric \* v_give_pct \/ 100\)::integer/);
});

test("les pourcentages restent surchargeables par la grille", () => {
  assert.match(SQL, /'group_margin_give_by_class' ->> v_classe/);
  assert.match(SQL, /'group_margin_give_pct'\)::numeric/);
});

test("la remuneration du transporteur n'est jamais reduite", () => {
  assert.match(SQL, /v_partner := v_partner \+ \(v_unitaire ->> 'partner_cents'\)::integer;/);
  assert.doesNotMatch(SQL, /v_partner := v_partner \+ \(v_unitaire ->> 'partner_cents'\)::integer - v_reduction/);
});

test("plancher et seuil de marge sont neutralises sur les vehicules suivants", () => {
  assert.match(SQL, /v_params_suite := p \|\| jsonb_build_object\('minimum_eur', 0, 'min_margin_pct', 0\)/);
});

test("la commande est plafonnee a trois vehicules", () => {
  assert.match(SQL, /'group_max_vehicles'\)::integer, 3\)/);
  assert.match(SQL, /manual_reason', 'trop_de_vehicules'/);
});

test("une commande ne peut jamais couter plus qu'elle ne rapporte", () => {
  assert.match(SQL, /if v_client < v_partner then/);
  assert.match(SQL, /'marge_negative_groupage'/);
});

test("le groupage refuse de s'appliquer sur un plafond moto perime", () => {
  assert.match(SQL, /'client_cap_eur'\)::numeric <> 382/);
});

test("les montants attendus sont controles a l'application de la migration", () => {
  for (const [montant, cas] of [
    ["60000", "1 voiture 500 km, client"],
    ["112000", "2 voitures 500 km, client"],
    ["100000", "2 voitures 500 km, transporteur inchange"],
    ["8000", "2 voitures 500 km, remise rendue"],
    ["168000", "3 voitures 500 km, client"],
    ["69840", "2 motos 500 km, client (plafond 382 applique avant la remise)"],
    ["90920", "1 voiture + 1 moto 500 km, client"],
    ["122000", "2 utilitaires 500 km, client (remise de 20 % seulement)"],
    ["3000", "2 utilitaires 500 km, remise rendue"],
  ]) {
    assert.ok(SQL.includes(montant), `le controle doit verifier ${cas} : ${montant}`);
  }
});
