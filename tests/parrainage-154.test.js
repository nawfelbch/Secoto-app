import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { codeDuLien, normaliserCode, texteInvitation, STATUT_FILLEUL } from "../src/lib/parrainage.js";

const sql = readFileSync(new URL("../supabase/migrations/202611190154_parrainage.sql", import.meta.url), "utf8");

test("154 : montants décidés le 19/11 (20/20 clients, 30/30 pros, 50 € transporteur après 3 missions)", () => {
  for (const k of ["'client_filleul_cents', 2000", "'client_parrain_cents', 2000", "'pro_filleul_cents', 3000", "'pro_parrain_cents', 3000",
    "'transporteur_parrain_cents', 5000", "'transporteur_missions', 3", "'max_filleuls_an', 10", "'net_min_cents', 5000"]) {
    assert.ok(sql.includes(k), k);
  }
});

test("154 : pas de cumul avec la remise des fêtes, commission plancher, récompense après livraison payée", () => {
  assert.match(sql, /appliquer_avantages\(secoto_private\.calculer_offres\(new\), new\)/);
  assert.match(sql, /least\(greatest\(v_r_promo, v_r_par\)/);                            // le meilleur des deux
  assert.match(sql, /remise_max_cents\(v_client, v_pay, v_pro, v_net\)/);                 // net ≥ 50 € dans le pire cas
  assert.match(sql, /o\.status::text = 'delivered'\s+and py\.status = 'paid'/);
  assert.match(sql, /m\.status::text = 'completed'/);
  assert.doesNotMatch(sql, /partner_pay_cents\s*=/);                                       // transporteur jamais touché
  assert.doesNotMatch(sql, /stripe/i);                                                     // aucun mouvement d'argent réel
});

test("154 : anti-fraude et usage unique", () => {
  assert.match(sql, /Vous ne pouvez pas utiliser votre propre code/);
  assert.match(sql, /tel_international\(f\.phone\) = secoto_private\.tel_international\(pa\.phone\)/);
  assert.match(sql, /f\.billing_siren = pa\.billing_siren/);
  assert.match(sql, /filleul_id\s+uuid not null unique/);
  assert.match(sql, /déjà été utilisée sur une autre réservation/);
  assert.match(sql, /motif = 'recredit'/);
});

test("154 : lien ?parrain= et texte d'invitation", () => {
  assert.equal(codeDuLien("?parrain=marie-7k3&utm_source=x"), "MARIE-7K3");
  assert.equal(codeDuLien("?parrain=ab"), "");
  assert.equal(normaliserCode(" ga rage!-1 "), "GARAGE-1");
  const moi = { code: "MARIE-7K3", lien: "https://app.secoto-transport.fr/?parrain=MARIE-7K3", filleul_eur: 20, type: "client" };
  assert.match(texteInvitation(moi), /20 € de remise sur ton premier transport/);
  assert.match(texteInvitation({ ...moi, type: "transporteur" }), /Mon code parrain : MARIE-7K3/);
  assert.equal(STATUT_FILLEUL.prime_a_verser, "Validé : prime en cours de versement");
});

// Même formule que secoto_private.remise_max_cents (vérifiée en production le 19/11).
const remiseMax = (c, p, pro, net = 5000) => Math.max(c - Math.ceil(pro ? (net + 25 + 0.788 * p) / 0.773 : (net + 0.788 * p) / 0.738), 0);
const netKlarna = (c, p) => (c - p) * 0.788 - 0.05 * c;
const netCarte = (c, p) => (c - p) * 0.788 - (0.015 * c + 25);

test("154 : rentabilité — jamais moins de 50 € nets après remise, même avec Klarna", () => {
  // Cas réels du 19/11 : Standard 785 € (transporteur 651 €) → remise plafonnée ≈ 21 €.
  assert.equal(Math.floor(remiseMax(78500, 65100) / 100), 22);   // Standard 785 € / transporteur 651 € : ≈ 22 € au lieu de 39 €
  // Petit Standard déjà à 40 € nets avec Klarna : aucune remise.
  assert.equal(remiseMax(48000, 39900), 0);
  for (const [c, p] of [[78500, 65100], [137200, 113900], [64900, 53800], [106000, 88000], [300000, 250000]]) {
    const r = Math.floor(Math.min(4000, remiseMax(c, p, false)) / 100) * 100;
    if (r > 0) assert.ok(netKlarna(c - r, p) >= 5000 - 1, `${c}/${p}`);
    const rp = Math.floor(Math.min(3000, remiseMax(c, p, true)) / 100) * 100;
    if (rp > 0) assert.ok(netCarte(c - rp, p) >= 5000 - 1, `pro ${c}/${p}`);
  }
});
