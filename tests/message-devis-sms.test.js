// SECOTO — SMS du lien de paiement : clair, rassurant, lien court.
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { lienCourt, messageDevisSms, prenomClient, urgence } from "../src/lib/messageDevis.js";

const URL_LONGUE = "https://app.secoto-transport.fr/.netlify/functions/devis-pay?t=e0dd6fc8560d43db8afc762c0b94b90ef386fac-da1e248f89687acf2efa40ecb";

test("lien court /payer, jeton intact", () => {
  assert.equal(lienCourt(URL_LONGUE), "https://app.secoto-transport.fr/payer?t=e0dd6fc8560d43db8afc762c0b94b90ef386fac-da1e248f89687acf2efa40ecb");
  assert.equal(lienCourt(lienCourt(URL_LONGUE)), lienCourt(URL_LONGUE));
  const toml = readFileSync(new URL("../netlify.toml", import.meta.url), "utf8");
  assert.match(toml, /from = "\/payer"\s+to = "\/\.netlify\/functions\/devis-pay"\s+status = 200/);
  // La règle doit passer avant la règle « toutes pages → index.html ».
  assert.ok(toml.indexOf('from = "/payer"') < toml.indexOf('from = "/*"'));
});

test("prénom seulement quand c'est un vrai prénom", () => {
  assert.equal(prenomClient("Vincent Besançon"), "Vincent");
  assert.equal(prenomClient("Demande sans compte"), "");
  assert.equal(prenomClient("ESPRIT AUTO"), "");
  assert.equal(prenomClient("client@exemple.fr"), "");
  assert.equal(prenomClient(""), "");
});

test("le SMS donne le prix tout compris, la date, le lien court seul sur sa ligne et la garantie", () => {
  const sms = messageDevisSms({ client: "Demande sans compte", trajet: "Saint-Pol-sur-Ternoise → Illies", amountCents: 11500,
    url: URL_LONGUE, pickupAt: "2026-10-21T06:00:00Z", mode: "plateau", arrivee: false });
  assert.match(sms, /^Bonjour,\n/);
  assert.match(sms, /Votre transport sur plateau Saint-Pol-sur-Ternoise → Illies est prêt : 115 € tout compris/);
  assert.match(sms, /tout compris \(carburant et péages\), prise en charge le mercredi 21 octobre\./);
  assert.match(sms, /Réservez maintenant en 1 minute, paiement sécurisé :\nhttps:\/\/app\.secoto-transport\.fr\/payer\?t=[0-9a-f-]+\n/);
  assert.match(sms, /Remboursé intégralement/);
  assert.match(sms, /Le paiement vaut acceptation du devis\./);
  assert.match(sms, /dans l'app SECOTO/);
  // Aucun appel à téléphoner : l'action unique est le lien.
  assert.doesNotMatch(sms, /appel|07 83|téléphone/i);
  assert.equal((sms.match(/https:\/\//g) || []).length, 1);
  assert.doesNotMatch(sms, /\.netlify/);
  assert.doesNotMatch(sms, /[\u{1F300}-\u{1FAFF}]/u, "aucun emoji");
});

test("centimes, convoyage, plusieurs véhicules, sans date", () => {
  const sms = messageDevisSms({ client: "Vincent Besançon", trajet: "Paris → Lyon", amountCents: 46480, url: URL_LONGUE, mode: "convoyage", vehicules: 2, arrivee: false });
  assert.match(sms, /^Bonjour Vincent,/);
  assert.match(sms, /Votre convoyage Paris → Lyon \(2 véhicules\) est prêt : 464,80 €/);
  assert.doesNotMatch(sms, /prise en charge/);
});

test("100 : règlement à l'arrivée — 0 € aujourd'hui, moyens de paiement, plus de remboursement", async () => {
  const sms = messageDevisSms({ client: "Demande sans compte", trajet: "Rochefort → Quincy-sous-Sénart", amountCents: 69932,
    url: URL_LONGUE, pickupAt: "2026-12-01T07:00:00Z", mode: "plateau", validiteHeures: 48 });
  assert.match(sms, /^Bonjour,\nBonne nouvelle : votre transport sur plateau Rochefort → Quincy-sous-Sénart est prêt\. 699,32 € tout compris \(carburant et péages\), prise en charge le mardi 1 décembre\./);
  assert.match(sms, /0 € à payer aujourd'hui\. Vous ne réglez qu'à l'arrivée de votre véhicule, par carte, en plusieurs fois avec Klarna, par virement ou en espèces\./);
  assert.match(sms, /Les places du mardi 1 décembre sont limitées : nos transporteurs organisent leurs tournées à l'avance\. Ce prix est garanti 48 h seulement\./);
  assert.match(sms, /Bloquez votre date maintenant, en 1 minute :\nhttps:\/\/app\.secoto-transport\.fr\/payer\?t=[0-9a-f-]+\n/);
  assert.match(sms, /La réservation vaut acceptation du devis\./);
  assert.doesNotMatch(sms, /Rembours|paiement sécurisé/i);
  assert.equal((sms.match(/https:\/\//g) || []).length, 1);
  assert.doesNotMatch(sms, /[\u{1F300}-\u{1FAFF}]/u, "aucun emoji");
  // Au-delà de 1 000 € : pas d'espèces (article L112-6).
  const gros = messageDevisSms({ client: "", trajet: "Paris → Nice", amountCents: 132000, url: URL_LONGUE, mode: "plateau" });
  assert.match(gros, /par carte, en plusieurs fois avec Klarna ou par virement\./);
  assert.doesNotMatch(gros, /espèces/);
  const { pageRenonciation } = await import("../netlify/functions/devis-pay.js");
  const page = pageRenonciation("abc123", 69932, "Rochefort → Quincy-sous-Sénart", { arrivee: true });
  assert.match(page, /0 € prélevé aujourd'hui/);
  assert.match(page, /Continuer — 0 € aujourd'hui/);
  assert.doesNotMatch(page, /intégralement remboursé/);
  assert.match(pageRenonciation("abc123", 69932, ""), /Continuer vers le paiement/);
});

test("FOMO : seulement ce qui est vrai (validité réelle, date demandée)", () => {
  assert.equal(urgence(0, ""), "Nos transporteurs organisent leurs tournées à l'avance : les premières réservations sont servies en premier.");
  assert.match(urgence(168, "lundi 2 novembre"), /Ce prix est garanti 7 jours\.$/);
  assert.doesNotMatch(urgence(0, "lundi 2 novembre"), /garanti/);
});
