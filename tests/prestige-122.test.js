// SECOTO 122 — prestige : barème dédié, transport fermé seulement si le client le demande.
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const sql = readFileSync(new URL("../supabase/migrations/202610300122_prestige_bareme_transport_ferme.sql", import.meta.url), "utf8");
const booking = readFileSync(new URL("../src/ondemand/OnDemandBooking.jsx", import.meta.url), "utf8");
const lib = readFileSync(new URL("../src/lib/onDemand.js", import.meta.url), "utf8");

test("122 : barème prestige (ouvert × 1,5 min 250 € ; fermé × 2,1 min 350 €)", () => {
  assert.match(sql, /'ouvert', jsonb_build_object\('coef', 1\.5, 'minimum_eur', 250\)/);
  assert.match(sql, /'ferme',  jsonb_build_object\('coef', 2\.1, 'minimum_eur', 350\)/);
  assert.match(sql, /v_pay := secoto_private\.prix_prestige_cents\(p_vehicle, v_pay\);/);
});

test("122 : camion fermé exigé seulement si demandé (diffusion et vitrine)", () => {
  assert.match(sql, /not secoto_private\.transport_ferme_demande\(q\.vehicle\) or a\.luxury_closed_transport_status = ''approved''/);
  assert.match(sql, /transporter_matches_mission/);
  assert.match(sql, /o\.mission_id = m\.id or o\.id = m\.od_order_id/);
  assert.match(sql, /''batterie_faible'', ''transport_ferme''\)/);
});

test("122 : la case « transport fermé » n'apparaît qu'en prestige", () => {
  assert.match(lib, /\{ value: "transport_ferme", label: "[^"]+", prestige: true \}/);
  assert.match(booking, /form\.vehicle\.category === "luxury" && \(/);
  assert.match(booking, /VEHICLE_CONSTRAINTS\.filter\(\(c\) => !c\.prestige\)/);
  assert.match(booking, /constraints: form\.vehicle\.constraints\.filter\(\(x\) => x !== "transport_ferme"\)/);
});
