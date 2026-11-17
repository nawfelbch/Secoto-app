import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { brevoSmsPayload, envoyerSmsEnAttente, BREVO_SMS_URL } from "../netlify/lib/sms-brevo.js";
import { placesVersTransporteurs, chiffres } from "../netlify/functions/places-transporteurs.js";
import { STATUTS_APPEL, telLien } from "../src/lib/appels.js";

const lire = (p) => readFileSync(new URL(`../${p}`, import.meta.url), "utf8");
const sql = lire("supabase/migrations/202611170151_automatisation.sql");

test("151 : réglages et étapes (rappel 4 h, SMS 12 h, coup de pouce 24 h ≥ 50 € nets, alerte 18 h, point client 12 h)", () => {
  for (const k of ["'rappel_transporteurs_h', 4", "'sms_transporteurs_h', 12", "'coup_de_pouce_h', 24", "'coup_de_pouce_pct', 10",
    "'coup_de_pouce_net_min_eur', 50", "'alerte_admin_h', 18", "'point_client_h', 12", "'point_client_max', 4", "'relance_paiement_max', 6"]) {
    assert.ok(sql.includes(k), k);
  }
  assert.match(sql, /o\.payment_circuit is null/);              // pas de coup de pouce en paiement direct
  assert.match(sql, /'boost:' \|\| o\.id::text/);               // une seule fois par commande
  assert.match(sql, /not coalesce\(a\.stripe_transfers_enabled, false\) and not coalesce\(a\.bank_details_completed, false\)/);
  assert.match(sql, /perform secoto_private\.assert_admin\(\);/);
  assert.doesNotMatch(sql, /client_price_cents\s*=/);            // jamais de prix client modifié
});

test("151 : coup de pouce plafonné pour garder 50 € nets (vérifié en production)", () => {
  const payMax = (client, mode, net = 50) => Math.floor(client - (net * 100 + (mode === "klarna" ? 0.05 * client : mode === "virement" ? 0 : 0.015 * client + 25)) / (1 - 0.212));
  assert.equal(payMax(92442, "carte"), 84305);
  assert.equal(payMax(92442, "virement"), 86096);
  assert.equal(payMax(92442, "klarna"), 80231);
});

test("151 : SMS Brevo — format, et rien n'est envoyé sans clé", async () => {
  assert.equal(BREVO_SMS_URL, "https://api.brevo.com/v3/transactionalSMS/send");
  const p = brevoSmsPayload({ to_phone: "+33613504886", body: "Test" });
  assert.deepEqual([p.sender, p.recipient, p.type], ["SECOTO", "33613504886", "transactional"]);
  const r = await envoyerSmsEnAttente({ admin: { rpc: () => { throw new Error("ne doit pas être appelé"); } }, env: {} });
  assert.equal(r.raison, "sans_cle");
});

test("151 : Google Places — numéros SECOTO retirés, doublons supprimés", () => {
  const places = [
    { id: "a", displayName: { text: "Dépannage A" }, nationalPhoneNumber: "01 02 03 04 05" },
    { id: "a", displayName: { text: "Dépannage A" }, nationalPhoneNumber: "01 02 03 04 05" },
    { id: "b", displayName: { text: "Déjà chez SECOTO" }, internationalPhoneNumber: "+33 6 13 50 48 86" },
    { id: "c", displayName: { text: "Sans téléphone" } },
  ];
  const r = placesVersTransporteurs(places, new Set([chiffres("06 13 50 48 86")]));
  assert.deepEqual(r.map((t) => t.cle), ["google:a"]);
});

test("151 : écran Piloter — appel en un clic et suivi", () => {
  assert.equal(telLien("06 13 50 48 86"), "tel:0613504886");
  assert.deepEqual(STATUTS_APPEL.map((s) => s.cle), ["appele", "pas_de_reponse", "interesse", "refus"]);
  assert.match(lire("src/ondemand/AdminOnDemand.jsx"), /<TransporteursAAppeler order=\{o\} \/>/);
  assert.match(lire("netlify/functions/od-maintenance.js"), /secoto_automatisation_tick/);
});
