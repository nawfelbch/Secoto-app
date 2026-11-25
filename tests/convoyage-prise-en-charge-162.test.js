import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";

const source = (p) => readFile(new URL(p, import.meta.url), "utf8");

test("162 : forfait de prise en charge 40 € en convoyage, rémunération du convoyeur intacte", async () => {
  const sql = await source("../supabase/migrations/202611250162_convoyage_prise_en_charge_40.sql");
  assert.match(sql, /jsonb_build_object\('prise_en_charge_eur', 40\)/);
  assert.match(sql, /v_client := v_client \+ \(p ->> 'prise_en_charge_eur'\)::numeric;/);
  assert.match(sql, /v_partner := greatest\(v_partner, coalesce\(\(p ->> 'partner_minimum_eur'\)::numeric, 0\)\);/,
    "le plancher de 12 € du convoyeur reste dû quand le forfait dépasse le minimum client");
  assert.doesNotMatch(sql, /v_partner := v_partner \+/, "le forfait ne va jamais au convoyeur");
  assert.match(sql, /'prise_en_charge', coalesce/, "exposé au site vitrine");
  for (const attendu of ["6300 or (v_prix ->> 'partner_cents')::int <> 1200", "<> 15500", "<> 119000", "<> 88000"]) {
    assert.ok(sql.includes(attendu), `contrôle bloquant ${attendu}`);
  }
  assert.match(sql, /Forfait de prise en charge posé sur le plateau par erreur/);
  const copie = await source("../deliverables/SECOTO-162-convoyage-prise-en-charge-40-a-coller-dans-Supabase.sql");
  assert.equal(copie, sql);
});
