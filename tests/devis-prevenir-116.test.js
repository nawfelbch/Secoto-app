// SECOTO 116 — devis « téléphone seul » : message prédéfini, tracé, puis appel.
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { lienSms, lienWhatsApp, numeroWhatsApp } from "../src/lib/messageDevis.js";

const lire = (f) => readFileSync(new URL(`../${f}`, import.meta.url), "utf8");

test("WhatsApp : numéro international sans « + », texte encodé", () => {
  assert.equal(numeroWhatsApp("+33637554175"), "33637554175");
  assert.equal(numeroWhatsApp("06 37 55 41 75"), "33637554175");
  assert.equal(numeroWhatsApp("0033637554175"), "33637554175");
  assert.equal(lienWhatsApp("+33637554175", "Bonjour,\nvotre prix"), "https://wa.me/33637554175?text=Bonjour%2C%0Avotre%20prix");
});

test("SMS : destinataire nettoyé, texte prérempli", () => {
  assert.equal(lienSms("+33 6 37 55 41 75", "Prix : 924,70 €"), "sms:+33637554175?&body=Prix%20%3A%20924%2C70%20%E2%82%AC");
  assert.equal(lienSms("", "x"), "sms:?&body=x");
});

test("écran admin : à prévenir, trace de l'envoi, appel juste après, bilan du chiffrage", () => {
  const ecran = lire("src/ondemand/AdminOnDemand.jsx");
  assert.match(ecran, /admin\.preparerMessage\(quote\.id\)/);
  for (const canal of ["sms", "whatsapp", "appel"]) assert.match(ecran, new RegExp(`tracer\\("${canal}"\\)`));
  assert.match(ecran, /admin\.messageEnvoye\(l\.quoteId, canal\)/);
  assert.match(ecran, /À prévenir par message/);
  assert.match(ecran, /email_envoye/);
  assert.match(ecran, /Date d’enlèvement passée/);
  const api = lire("src/lib/onDemand.js");
  assert.match(api, /secoto_admin_devis_message_preparer/);
  assert.match(api, /secoto_admin_devis_message_envoye/);
  const sql = lire("supabase/migrations/202610220116_devis_prevenir_client.sql");
  assert.match(sql, /devis_prevenir_par_email\(p_quote_id\)/);
  assert.match(sql, /euros_lisibles/);
});
