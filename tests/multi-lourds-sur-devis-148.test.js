import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { MANUAL_REASONS } from "../src/lib/onDemand.js";

test("148 : plusieurs véhicules dont un lourd -> devis manuel, motif affiché au client", () => {
  const sql = readFileSync(new URL("../supabase/migrations/202611170148_multi_lourds_sur_devis.sql", import.meta.url), "utf8");
  assert.match(sql, /jsonb_array_length\(v_vehicles\) > 1/);
  assert.match(sql, /secoto_private\.est_lourd\(secoto_private\.gabarit_vehicule\(x\.value\)\)/);
  assert.match(sql, /v_reason := 'sur_devis_plusieurs_lourds'/);
  assert.match(MANUAL_REASONS.sur_devis_plusieurs_lourds, /devis personnalisé/);
});
