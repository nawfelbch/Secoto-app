import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { codeDuLien, normaliserCode, texteInvitation, STATUT_FILLEUL } from "../src/lib/parrainage.js";

const sql = readFileSync(new URL("../supabase/migrations/202611190154_parrainage.sql", import.meta.url), "utf8");

test("154 : montants décidés le 19/11 (20/20 clients, 30/30 pros, 50 € transporteur après 3 missions)", () => {
  for (const k of ["'client_filleul_cents', 2000", "'client_parrain_cents', 2000", "'pro_filleul_cents', 3000", "'pro_parrain_cents', 3000",
    "'transporteur_parrain_cents', 5000", "'transporteur_missions', 3", "'max_filleuls_an', 10", "'commission_min_cents', 7500"]) {
    assert.ok(sql.includes(k), k);
  }
});

test("154 : pas de cumul avec la remise des fêtes, commission plancher, récompense après livraison payée", () => {
  assert.match(sql, /appliquer_avantages\(secoto_private\.calculer_offres\(new\), new\)/);
  assert.match(sql, /v_remise > coalesce\(\(op ->> 'remise_cents'\)::int, 0\)/);        // le meilleur des deux
  assert.match(sql, /v_client - v_pay - v_min/);                                          // commission ≥ 75 €
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
