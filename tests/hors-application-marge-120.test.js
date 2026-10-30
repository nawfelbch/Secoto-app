// SECOTO 120 — course de l'app réglée hors application : seule la marge est comptée.
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const sql = readFileSync(new URL("../supabase/migrations/202610280120_hors_application_marge_reelle.sql", import.meta.url), "utf8");

test("120 : déclaration — encaissé, part transporteur et marge pour une course issue d'une commande", () => {
  assert.match(sql, /dirigeant_lignes\(\)/);
  assert.match(sql, /then coalesce\(m\.client_total_due, m\.client_price, 0\)/);
  assert.match(sql, /then round\(coalesce\(m\.carrier_pay, 0\) \* 100\)::bigint else 0::bigint end/);
  assert.match(sql, /then coalesce\(m\.margin, 0\) else coalesce\(nullif\(m\.commission_amount, 0\), m\.margin, 0\) end/);
  // Le lien mission ↔ commande passe par transport_orders.mission_id (od_order_id est presque toujours vide).
  assert.doesNotMatch(sql.replace(/--.*$/gm, ""), /od_order_id/);
});

test("120 : tableau de bord et relances — la marge, et plus de double suivi des espèces", () => {
  assert.equal((sql.match(/secoto_dirigeant_tableau\(integer\)/g) || []).length, 2);
  assert.match(sql, /trg_commission_especes_due\(\)/);
  assert.match(sql, /if exists \(select 1 from public\.transport_orders o where o\.mission_id = new\.id\) then return new; end if;/);
});
