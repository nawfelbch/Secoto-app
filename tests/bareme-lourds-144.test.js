import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const sql = readFileSync(new URL("../supabase/migrations/202611140144_bareme_lourds_rentabilite.sql", import.meta.url), "utf8");

// Copie JS des formules SQL (lourds_transporteur_eur / lourds_client_cents) pour vérifier la rentabilité.
function transporteur(km) {
  if (km <= 200) return 375;
  if (km <= 345) return 375 + (700 - 375) * (km - 200) / (345 - 200);
  if (km <= 465) return 700 + (800 - 700) * (km - 345) / (465 - 345);
  return 800 + 1.66 * (km - 465);
}
function client(pay) {
  const u = 0.212, k = 0.05;
  return Math.ceil(((75 + (1 - u) * pay) / (1 - k - u)) / 5) * 5;
}
const net = (prix, pay) => prix * (1 - 0.05) - pay - 0.212 * (prix - pay);

test("144 : paliers transporteur demandés (700 € à 345 km, 800 € à 465 km, 375 € minimum)", () => {
  assert.equal(transporteur(80), 375);
  assert.equal(transporteur(345), 700);
  assert.equal(transporteur(465), 800);
  for (const k of ["'transporteur_min_eur', 375", "'palier_1_eur', 700", "'palier_2_eur', 800", "'eur_km_au_dela', 1.66",
    "'net_min_eur', 75", "'urssaf_pct', 21.2", "'frais_paiement_pct', 5", "'express_coef', 1.2", "'eco', false"]) {
    assert.ok(sql.includes(k), k);
  }
});

test("144 : au moins 75 € nets après URSSAF et frais Klarna, sur toutes les distances", () => {
  for (let km = 10; km <= 1500; km += 5) {
    const pay = transporteur(km), prix = client(pay);
    assert.ok(net(prix, pay) >= 75 - 1e-9, `${km} km : ${prix} € pour ${pay} €`);
    assert.equal(prix % 5, 0);
  }
  // Valeurs vérifiées en production (aperçu annulé).
  assert.equal(client(transporteur(345)), 850);
  assert.equal(client(transporteur(465)), 960);
});

test("144 : Express ×1,2 et pas d'Éco pour utilitaire, caravane, camping-car ; site recalculé", () => {
  assert.match(sql, /'gabarits', jsonb_build_array\('utilitaire', 'caravane', 'camping_car'\)|'utilitaire', 'caravane', 'camping_car'/);
  assert.match(sql, /est_lourd\(v_gab\) and not coalesce/);
  assert.match(sql, /'bareme_secoto_v3_lourds'/);
  assert.match(sql, /bareme_v3_public_rafraichir\(\)/);
  assert.match(sql, /and not \(value \? 'lourds'\)/);
});
