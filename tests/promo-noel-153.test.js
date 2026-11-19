import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { promoNoelActive, bonnetNoel, jourParis, texteRemise } from "../src/lib/promoNoel.js";

const sql = readFileSync(new URL("../supabase/migrations/202611190153_promo_noel.sql", import.meta.url), "utf8");

// Même règle que secoto_private.appliquer_promo_noel (vérifiée en production le 19/11).
const remise = (client, pay) => Math.floor(Math.max(Math.min(Math.floor(client * 0.05), 4000, client - pay - 7500), 0) / 100) * 100;

test("153 : 5 % plafonnés à 40 €, commission jamais sous 75 €, transporteur inchangé", () => {
  assert.equal(remise(93700, 72000), 4000);   // plafond
  assert.equal(remise(72100, 57500), 3600);   // 5 %
  assert.equal(remise(45000, 37500), 0);      // commission déjà à 75 €
  assert.equal(remise(50000, 41000), 1500);   // garde 75 € de commission
  assert.match(sql, /'pct', 5, 'plafond_cents', 4000, 'commission_min_cents', 7500/);
  assert.doesNotMatch(sql, /partenaire_cents'\s*,\s*v_pay\s*-/);
  assert.match(sql, /appliquer_promo_noel\(secoto_private\.calculer_offres\(new\)\)/);
});

test("153 : pas de prix gonflé — remise affichée sur le prix normal du jour", () => {
  assert.match(sql, /'client_avant_remise_cents', v_client/);
  assert.match(sql, /'client_cents', v_client - v_remise/);
});

test("153 : Black Friday du 27 au 30/11, puis Noël jusqu'au 31/12", () => {
  assert.match(sql, /'debut', '2026-11-27', 'fin', '2027-01-01'/);
  assert.match(sql, /'black_friday_fin', '2026-12-01', 'libelle_black_friday', 'Remise Black Friday'/);
});

test("153 : bonnet du 1er au 31 décembre, heure de Paris", () => {
  assert.equal(promoNoelActive(new Date("2026-11-30T22:59:00Z")), false);
  assert.equal(promoNoelActive(new Date("2026-11-30T23:00:00Z")), true);   // 1er déc. 00 h à Paris
  assert.equal(promoNoelActive(new Date("2026-12-31T22:59:00Z")), true);
  assert.equal(promoNoelActive(new Date("2026-12-31T23:00:00Z")), false);
  assert.equal(jourParis(new Date("2026-12-24T12:00:00Z")), "2026-12-24");
  assert.equal(texteRemise(3600), "−36 €");
  // Bonnet dès maintenant (19/11) jusqu'au 31/12.
  assert.equal(bonnetNoel(new Date("2026-11-20T10:00:00Z")), true);
  assert.equal(bonnetNoel(new Date("2026-12-31T22:59:00Z")), true);
  assert.equal(bonnetNoel(new Date("2026-12-31T23:00:00Z")), false);
});
