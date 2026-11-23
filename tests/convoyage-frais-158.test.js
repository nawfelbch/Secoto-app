import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const lire = (p) => readFileSync(new URL(`../${p}`, import.meta.url), "utf8");

test("158 : les convoyeurs savent que carburant et péages sont remboursés par SECOTO", () => {
  const sql = lire("supabase/migrations/202611230158_convoyage_frais_rembourses.sql");
  for (const f of ["od_broadcast", "od_completer_diffusion", "secoto_automatisation_tick"]) assert.match(sql, new RegExp(f));
  assert.equal((sql.match(/Carburant et péages remboursés par SECOTO en plus/g) || []).length, 2);
  assert.match(sql, /when v_order\.mode = 'convoyage'/);
  assert.match(sql, /ne sont pas à votre charge/);
});

test("158 : le client voit « tout compris », plus « au réel, sur justificatifs »", () => {
  const ecran = lire("src/ondemand/OnDemandBooking.jsx");
  assert.doesNotMatch(ecran, /Carburant et péages au réel/);
  assert.match(ecran, /Prix tout compris : carburant et péages inclus/);
});
