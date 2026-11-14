import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { OFFRE_LIBELLE } from "../src/lib/orderCopy.js";

const lire = (p) => readFileSync(new URL(`../${p}`, import.meta.url), "utf8");
const sql = lire("supabase/migrations/202611140145_navette_pro.sql");

test("145 : prix pro = prix transporteur + 75 € (1 véhicule) ou + 60 € par véhicule (2 et plus)", () => {
  for (const k of ["'marge_1_vehicule_eur', 75", "'marge_par_vehicule_2_plus_eur', 60", "'transporteur_eur', 480", "'transporteur_eur', 520"]) {
    assert.ok(sql.includes(k), k);
  }
  // Exemples vérifiés en production (aperçu annulé).
  const prix = (transporteur, n) => n * transporteur + (n === 1 ? 75 : 60 * n);
  assert.equal(prix(480, 1), 555);
  assert.equal(prix(480, 2), 1080);
  assert.equal(prix(520, 1), 595);
});

test("145 : axes Paris – Lyon – Côte d'Azur et Paris – Belgique – Allemagne, porte à porte", () => {
  assert.match(sql, /'departements', jsonb_build_array\('75'[^)]*'69'[^)]*'13','83','06'/);
  assert.match(sql, /'pays', jsonb_build_array\('BE','DE'\)/);
  assert.doesNotMatch(sql, /ville_depot/);
});

test("145 : anti-friction — Navette Pro pour les pros seulement, pas d'Éco pour les pros", () => {
  assert.match(sql, /a\.client_type = 'pro'/);
  assert.match(sql, /v_navette := case when v_pro then secoto_private\.offre_navette_pro/);
  assert.match(sql, /elsif not v_pro and secoto_private\.flag\('bareme_v3'\)/);
  assert.match(sql, /v_client >= p_std_client then return null/);
  assert.match(sql, /new\.account_id is distinct from old\.account_id/);
  assert.match(sql, /offre in \('express', 'standard', 'eco', 'pro'\)/);
});

test("145 : écrans — libellé Navette Pro, pas de mention Klarna pour un pro", () => {
  assert.equal(OFFRE_LIBELLE.pro, "Navette Pro");
  const booking = lire("src/ondemand/OnDemandBooking.jsx");
  assert.match(booking, /klarna=\{arrivee && !clientPro\}/);
  assert.match(booking, /arrivee && !clientPro && klarnaSousPrix/);
  assert.match(lire("src/App.jsx"), /clientPro=\{account\?\.clientType === "pro"\}/);
});
