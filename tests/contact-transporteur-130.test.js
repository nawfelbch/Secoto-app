import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const sql = readFileSync(new URL("../supabase/migrations/202611070130_contact_transporteur_masque_apres_livraison.sql", import.meta.url), "utf8");
const panel = readFileSync(new URL("../src/ondemand/MyOrdersPanel.jsx", import.meta.url), "utf8");
const app = readFileSync(new URL("../src/App.jsx", import.meta.url), "utf8");

test("130 : plus de numéro du transporteur après la livraison (base)", () => {
  assert.match(sql, /\/\* 130 \*\/ or \(false and coalesce\(/);
  assert.match(sql, /and m\.status = 'assigned'\n/);
  assert.doesNotMatch(sql.split("create or replace function")[1], /48 hours/);
});

test("130 : l'écran client ne montre le numéro qu'avant la livraison", () => {
  assert.match(panel, /order\.partner_contact && \["partner_confirmed", "picked_up"\]\.includes\(order\.status\)/);
  assert.match(app, /mission\.transporterContact && mission\.status === "assigned" && <CarteTransporteur/);
});
