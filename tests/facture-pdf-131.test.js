import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { PDFDocument } from "pdf-lib";
import { buildFacturePdf, euros, libelleReglement, nomFichierFacture } from "../netlify/lib/facture-pdf.js";
import { moyenDePaiement, corpsEmailFacture } from "../netlify/lib/facture-donnees.js";
import { commandeDeFacture, preparerFacture } from "../netlify/functions/send-transactional-email.js";

const base = {
  numero: "FAC-202610-0001", dateEmission: "2026-10-01T16:12:41Z", ref: "CMD-2026-80EB7CF7", montantCents: 115412,
  client: { nom: "Cyrille Caujolle", type: "Particulier", adresse: "", email: "c@example.com", telephone: "0668609505" },
  transport: { vehicule: "Grand Cherokee (non roulant)", mode: "plateau", priseEnCharge: "2026-10-02T07:50:57Z", livraison: "2026-10-07T11:33:42Z", transporteur: "BAD MOTORS" },
  adresseDepart: "ZA les Trussots 85570 L'Hermenault", adresseArrivee: "Rue Gabriel Fauré 13010 Marseille", distanceKm: 895.1,
  trajetCourt: "L'Hermenault (85) - Marseille (13)",
  reglement: { type: "carte", moyen: "Carte Visa débit •••• 6206 (France)", troisDS: true, codeAutorisation: "566397", date: new Date(1790871158000),
    intentId: "pi_test", chargeId: "ch_test", statut: "Paiement réussi · aucun remboursement", libelleReleve: "SECOTO", recuUrl: "https://pay.stripe.com/receipts/payment/xyz",
    payeur: { nom: "Cyrille Caujolle", email: "c@example.com" } },
};

const pages = async (bytes) => (await PDFDocument.load(bytes)).getPageCount();

test("131 : paiement en ligne = facture + justificatif (2 pages A4)", async () => {
  const bytes = await buildFacturePdf(base);
  assert.equal(await pages(bytes), 2);
  const doc = await PDFDocument.load(bytes);
  const { width, height } = doc.getPage(0).getSize();
  assert.ok(Math.abs(width - 595.28) < 1 && Math.abs(height - 841.89) < 1);
  assert.equal(doc.getTitle(), "Facture FAC-202610-0001 — SECOTO");
});

test("131 : espèces et virement = facture seule, sans page 2", async () => {
  assert.equal(await pages(await buildFacturePdf({ ...base, reglement: { type: "especes", date: "2026-11-12T15:00:00Z" } })), 1);
  assert.equal(await pages(await buildFacturePdf({ ...base, reglement: { type: "virement", date: "2026-11-12T15:00:00Z" } })), 1);
  assert.equal(libelleReglement({ type: "especes" }), "en espèces auprès du transporteur");
  assert.equal(libelleReglement({ type: "virement" }), "par virement bancaire");
});

test("131 : caractères hors police (emoji, flèche) ne bloquent jamais la facture", async () => {
  const bytes = await buildFacturePdf({ ...base, client: { ...base.client, nom: "Zoë 🚗 Łukasz → Ğ" } });
  assert.equal(await pages(bytes), 2);
});

test("131 : données incomplètes refusées, montants au format français", async () => {
  await assert.rejects(() => buildFacturePdf({ ...base, numero: null }), /facture_donnees_incompletes/);
  assert.equal(euros(115412), "1 154,12 €");
  assert.equal(nomFichierFacture("FAC-202610-0001"), "Facture-FAC-202610-0001-SECOTO.pdf");
});

test("131 : moyen de paiement lu dans Stripe, sans rien inventer", () => {
  const carte = moyenDePaiement({ type: "card", card: { brand: "visa", funding: "debit", last4: "6206", country: "FR", authorization_code: "566397", three_d_secure: { result: "authenticated" } } });
  assert.deepEqual(carte, { type: "carte", moyen: "Carte Visa débit •••• 6206 (France)", troisDS: true, codeAutorisation: "566397" });
  assert.equal(moyenDePaiement({ type: "card", card: { brand: "mastercard", last4: "1111", wallet: { type: "apple_pay" } } }).moyen, "Carte Mastercard •••• 1111 via Apple Pay");
  assert.deepEqual(moyenDePaiement({ type: "klarna", klarna: { payment_method_category: "pay_in_installments" } }), { type: "klarna", moyen: "Klarna" });  // 143 : CCD2
  assert.equal(moyenDePaiement({ type: "card", card: { brand: "visa", last4: "4242" } }).troisDS, false);
});

test("131 : l'e-mail de facture est repéré par sa clé, les autres e-mails ne changent pas", async () => {
  const id = "2791ad58-552c-493b-85bc-ca1cbc3fa355";
  assert.equal(commandeDeFacture(`od-invoice:${id}`), id);
  assert.equal(commandeDeFacture("od-etape:delivered:x"), null);
  assert.equal(commandeDeFacture("od-invoice:pas-un-uuid"), null);
  const autre = { event_key: "relance-auto:x", body_text: "t" };
  assert.equal(await preparerFacture(autre, { admin: null, stripe: null, dernierEssai: false }), autre);
});

test("131 : PDF impossible = nouvel essai, puis e-mail texte seul au dernier essai", async () => {
  const row = { event_key: "od-invoice:2791ad58-552c-493b-85bc-ca1cbc3fa355", body_text: "texte" };
  await assert.rejects(() => preparerFacture(row, { admin: null, stripe: null, dernierEssai: false }), /FACTURE_PDF/);
  assert.equal(await preparerFacture(row, { admin: null, stripe: null, dernierEssai: true }), row);
});

test("131 : corps de l'e-mail et migration espèces", () => {
  const corps = corpsEmailFacture(base);
  assert.match(corps, /facture acquittée FAC-202610-0001/);
  assert.match(corps, /reçu officiel émis par Stripe/);
  assert.match(corps, /L'Équipe SECOTO/);
  assert.doesNotMatch(corps, /garanti|assuré/i);
  const sql = readFileSync(new URL("../supabase/migrations/202611090131_facture_pdf_acquittee.sql", import.meta.url), "utf8");
  assert.match(sql, /perform secoto_private\.od_issue_invoice\(v_order\.id\); -- 131/);
});
