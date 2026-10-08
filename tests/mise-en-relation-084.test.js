import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import { contactLinks, phoneDisplay, phoneE164 } from "../src/lib/contactLinks.js";
import { exampleTrip, parseEuros, sameAsDefaults } from "../src/lib/carrierRatesUtil.js";
import { questionsReservation } from "../src/lib/faqReservation.js";

const lire = (f) => readFileSync(new URL(`../${f}`, import.meta.url), "utf8");

test("numéros français : appel, SMS et WhatsApp fonctionnent sur iPhone et Android", () => {
  assert.equal(phoneE164("06 12 34 56 78"), "+33612345678");
  assert.equal(phoneE164("+33 6 12 34 56 78"), "+33612345678");
  assert.equal(phoneE164("0033612345678"), "+33612345678");
  assert.equal(phoneDisplay("+33612345678"), "06 12 34 56 78");
  const l = contactLinks("0612345678", "Bonjour");
  assert.equal(l.tel, "tel:+33612345678");
  assert.match(l.sms, /^sms:\+33612345678\?&body=Bonjour$/);
  assert.equal(l.whatsapp, "https://wa.me/33612345678?text=Bonjour");
  assert.equal(contactLinks(""), null);
  assert.equal(contactLinks("12"), null);
});

test("barème transporteur : saisie à la française, exemple de prix, retour au barème de départ", () => {
  assert.equal(parseEuros("1,05"), 1.05);
  assert.ok(Number.isNaN(parseEuros("")));
  assert.equal(exampleTrip({ eur_per_km: "1,00", minimum_eur: "95,83" }), 300);
  assert.equal(exampleTrip({ eur_per_km: "1", minimum_eur: "400" }), 400);
  const defaults = { voiture: { eur_per_km: 1, minimum_eur: 95.83, non_rolling_eur: 66.67 } };
  assert.equal(sameAsDefaults({ voiture: { eur_per_km: "1,00", minimum_eur: "95,83", non_rolling_eur: "66,67" } }, defaults), true);
  assert.equal(sameAsDefaults({ voiture: { eur_per_km: "1,10", minimum_eur: "95,83", non_rolling_eur: "66,67" } }, defaults), false);
});

test("page de réservation : toutes les réponses avant de payer, fidèles au circuit réel", () => {
  const direct = questionsReservation({ mode: "plateau", circuit: "direct", relation: true });
  const q = (list, start) => list.find((x) => x.q.startsWith(start))?.r || "";
  assert.ok(direct.length >= 8);
  assert.match(q(direct, "Qui est SECOTO"), /mise en relation/);
  assert.match(q(direct, "Qui est SECOTO"), /951 857 531/);
  assert.match(q(direct, "Quand suis-je débité"), /Uniquement quand un transporteur accepte/);
  assert.match(q(direct, "Qui sera mon interlocuteur"), /téléphone/);
  assert.match(q(direct, "Puis-je annuler"), /sans frais tant qu’aucun transporteur/);
  // Ancien circuit : jamais de promesse « aucun débit » ; sans l'interrupteur : pas de coordonnées promises.
  const ancien = questionsReservation({ mode: "plateau", circuit: null, relation: false });
  assert.doesNotMatch(q(ancien, "Quand suis-je débité"), /rien n’est prélevé/);
  assert.doesNotMatch(q(ancien, "Qui sera mon interlocuteur"), /téléphone/);
  // Convoyage : SECOTO reste prestataire, pas de « mise en relation ».
  assert.doesNotMatch(q(questionsReservation({ mode: "convoyage" }), "Qui est SECOTO"), /mise en relation/);
});

test("le client n'est plus renvoyé vers SECOTO après sa première course (SAV), l'administrateur ne modifie plus une course acceptée", () => {
  const app = lire("src/App.jsx");
  assert.match(app, /savClient \? <SavPanel \/> : <ContactPanel \/>/);
  assert.match(app, /label: savClient \? "SAV SECOTO" : "Contact SECOTO"/);
  assert.match(app, /<CarteTransporteur contact=\{mission\.transporterContact\}/);
  assert.match(app, /titre="Votre client"/);
  assert.match(app, /verrouillee=\{Boolean\(flags\.mise_en_relation_v2\)/);
  assert.match(lire("src/ondemand/MyOrdersPanel.jsx"), /<CarteTransporteur contact=\{order\.partner_contact\}/);
  assert.match(lire("src/ondemand/AdminOnDemand.jsx"), /Annuler et rembourser intégralement/);
  assert.match(lire("src/ondemand/OnDemandBooking.jsx"), /<ReassuranceReservation mode=\{quote\.mode\}/);
  assert.doesNotMatch(lire("templates/facture.html"), /07 83 27 82 31/);
  assert.doesNotMatch(lire("templates/facture.html"), /7j\/7/);
});

test("le transporteur fixe son barème avant de recevoir des missions (fenêtre et onglet)", () => {
  const app = lire("src/App.jsx");
  assert.match(app, /<BaremeTransporteur gate status=\{bareme\}/);
  assert.match(app, /key: "bareme", label: "Mon barème"/);
  const comp = lire("src/BaremeTransporteur.jsx");
  assert.match(comp, /Vous fixez librement votre prix/);
  assert.match(comp, /Valider ce barème/);
});
