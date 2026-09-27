// ============================================================================
// SECOTO 056 — le groupage client rend 40 % de la marge SECOTO sur chaque
// vehicule a partir de deux, en plateau seulement, sans jamais toucher a la
// remuneration du transporteur.
// ============================================================================
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const SQL = readFileSync(
  new URL("../supabase/migrations/202609270056_groupage_client_plateau.sql", import.meta.url),
  "utf8",
);

test("la fonction de groupage existe et reste additive", () => {
  assert.match(SQL, /create or replace function secoto_private\.price_group_with_grid\(/);
  // price_with_grid n'est pas redefinie : aucun appel existant n'est touche.
  assert.doesNotMatch(SQL, /create or replace function secoto_private\.price_with_grid\(/);
  assert.doesNotMatch(SQL, /drop function/i);
});

test("la remise vaut 40 % de la marge et ne s'applique qu'en plateau", () => {
  assert.match(SQL, /'group_margin_give_pct'\)::numeric, 40\)/);
  assert.match(SQL, /v_groupe := \(p_mode = 'plateau' and v_give_pct > 0\)/);
  assert.match(SQL, /v_reduction := floor\(\(v_unitaire ->> 'margin_cents'\)::numeric \* v_give_pct \/ 100\)::integer/);
});

test("la remuneration du transporteur n'est jamais reduite", () => {
  // La part transporteur est additionnee telle quelle, sans v_reduction.
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

test("les montants attendus sont controles a l'application de la migration", () => {
  for (const attendu of [
    "60000", // 1 voiture 500 km, client
    "112000", // 2 voitures 500 km, client
    "100000", // 2 voitures 500 km, transporteur : inchange
    "8000", // 2 voitures 500 km, remise rendue au client
    "168000", // 3 voitures 500 km, client
    "72000", // 2 motos 500 km, client (plafonds appliques avant la remise)
    "92000", // 1 voiture + 1 moto 500 km, client
  ]) {
    assert.ok(SQL.includes(attendu), `le controle doit verifier le montant ${attendu}`);
  }
});
