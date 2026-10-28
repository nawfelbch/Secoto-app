// SECOTO 121 — barème moto : 1,10 €/km, minimum 150 € (transporteur), en plancher.
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const sql = readFileSync(new URL("../supabase/migrations/202610280121_bareme_moto_110.sql", import.meta.url), "utf8");

test("121 : nouveau tarif moto par défaut", () => {
  assert.match(sql, /'\{defaults,moto,eur_per_km\}', '1\.10'::jsonb/);
  assert.match(sql, /'\{defaults,moto,minimum_eur\}', '150'::jsonb/);
});

test("121 : plancher sur les tarifs moto enregistrés, rien d'autre", () => {
  assert.match(sql, /greatest\(eur_per_km, 1\.10\)/);
  assert.match(sql, /greatest\(minimum_eur, 150\)/);
  assert.match(sql, /where vehicle_class = 'moto' and \(eur_per_km < 1\.10 or minimum_eur < 150\)/);
  assert.doesNotMatch(sql, /\bdelete\b|\bdrop\b|transport_quotes|transport_orders/i);
});
