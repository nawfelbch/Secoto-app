// SECOTO 104 — promesse « transporteurs validés » factuelle et paiement cohérent partout.
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { questionsReservation } from "../src/lib/faqReservation.js";

const lire = (f) => readFileSync(new URL(`../${f}`, import.meta.url), "utf8");

test("accueil : promesse factuelle et lien « Comprendre nos vérifications »", () => {
  const app = lire("src/App.jsx");
  assert.doesNotMatch(app, /vérifiés et assurés/);
  assert.equal((app.match(/✓ Transporteurs validés par SECOTO/g) || []).length, 2);
  assert.match(app, /Comprendre nos vérifications/);
  assert.match(app, /\/verifications\.html/);
});

test("page des vérifications : seulement ce qui est contrôlé, aucune garantie inventée", () => {
  const page = lire("public/verifications.html").replace(/\s+/g, " ");
  for (const attendu of [/validé manuellement par SECOTO/, /validée<\/strong> ou <strong>refusée/, /date de fin de validité/,
    /pas aujourd'hui de nouveau contrôle automatique/, /ne garantit pas que le contrat couvre une mission précise/,
    /plafond, la franchise et les exclusions/, /En cas de dommage/, /ne sont jamais publiés/]) {
    assert.match(page, attendu);
  }
  assert.doesNotMatch(page, /100\s?%|assuré à|tous assurés|garantie totale|certifié/i);
  assert.match(page, /\/legal\/legal\.css/);
  assert.match(page, /noindex/, "hors moteurs tant que les textes ne sont pas validés");
});

test("paiement : réservation et acceptation sans débit, règlement à la livraison — CGU, FAQ, SMS, conditions transporteur", () => {
  const cgu = lire("public/cgu.html").replace(/\s+/g, " ");
  assert.match(cgu, /Aucun montant n'est débité à la réservation, ni lorsqu'un transporteur accepte la mission\./);
  assert.match(cgu, /Le règlement intervient <strong>à la livraison du véhicule<\/strong>/);
  assert.doesNotMatch(cgu, /n'est débité que lorsqu'un transporteur accepte/);
  assert.doesNotMatch(cgu, /vérifie régulièrement/);
  const ct = lire("public/conditions-transporteur.html").replace(/\s+/g, " ");
  assert.match(ct, /le client ne paie rien à la réservation ni à l'acceptation/);
  assert.doesNotMatch(ct, /vérifie régulièrement/);
  const faq = questionsReservation({ mode: "plateau", circuit: "arrivee" });
  const quand = faq.find((q) => q.q === "Quand suis-je débité ?").r;
  assert.match(quand, /À la livraison seulement/);
  assert.match(quand, /0 € prélevé, aussi quand un transporteur accepte/);
  assert.match(faq.find((q) => q.q === "Puis-je annuler ?").r, /rien n’est prélevé avant son arrivée/);
  assert.ok(!faq.some((q) => /Oui\. Chaque transporteur dispose de sa propre assurance/.test(q.r)));
  assert.doesNotMatch(lire("src/lib/messageDevis.js"), /assuré|assurance\)/);
  assert.doesNotMatch(lire("src/ondemand/ReassuranceReservation.jsx"), /permis et assurance contrôlés/);
});
