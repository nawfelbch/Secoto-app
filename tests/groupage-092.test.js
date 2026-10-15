// SECOTO 092 — 2e véhicule sur le même plateau à −25 % (client et transporteur).
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const SQL = readFileSync(new URL("../supabase/migrations/202610150092_groupage_vehicule_supplementaire.sql", import.meta.url), "utf8");
const ECRAN = readFileSync(new URL("../src/ondemand/OnDemandBooking.jsx", import.meta.url), "utf8");

test("092 : migration additive, réglable dans la grille", () => {
  assert.match(SQL, /create or replace function secoto_private\.price_group_with_grid\(/);
  assert.doesNotMatch(SQL, /drop (function|table|policy)/i);
  assert.doesNotMatch(SQL, /alter policy|disable row level security/i);
  assert.match(SQL, /'group_extra_client_pct'\)::numeric, 25\)/);
  assert.match(SQL, /'group_extra_partner_pct'\)::numeric, 25\)/);
});

test("092 : SECOTO gagne toujours (marge minimale par véhicule, garde-fou global)", () => {
  assert.match(SQL, /v_marge_min/);
  assert.match(SQL, /if v_client <= v_partner then/);
  assert.match(SQL, /'marge_negative_groupage'/);
});

test("092 : contrôles chiffrés bloquants à l'application", () => {
  for (const montant of ["105000", "87500", "314653", "270747", "113000", "121000", "66850", "80000"]) {
    assert.ok(SQL.includes(montant), montant);
  }
});

test("092 : le client voit l'avantage avant d'ajouter un véhicule", () => {
  assert.match(ECRAN, /chaque véhicule en plus est à −25 %/);
});
