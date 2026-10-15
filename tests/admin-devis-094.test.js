// SECOTO — Devis tarifés : tous accessibles, recherche par ville/nom/téléphone.
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { chiffresTelephone, devisTarifesValides, filtrerDevis, DEVIS_AFFICHES } from "../src/lib/devisAdmin.js";

const futur = new Date(Date.now() + 86400000).toISOString();
const passe = new Date(Date.now() - 86400000).toISOString();
const devis = (i, extra = {}) => ({
  id: String(i), status: "priced", valid_until: futur,
  pickup: { city: "Digne-les-Bains" }, delivery: { city: "Ollioules" },
  client_name: "Demande sans compte", client_phone: "0686665286", client_email: "", ...extra,
});

test("plus de plafond à 12 : les 20 devis valides restent dans la liste", () => {
  const l = Array.from({ length: 20 }, (_, i) => devis(i));
  assert.equal(devisTarifesValides(l).length, 20);
  assert.equal(DEVIS_AFFICHES, 12);
});

test("expirés et non tarifés exclus", () => {
  const l = [devis(1), devis(2, { valid_until: passe }), devis(3, { status: "manual_review" }), devis(4, { valid_until: null })];
  assert.deepEqual(devisTarifesValides(l).map((q) => q.id), ["1", "4"]);
});

test("téléphone : formats français et internationaux", () => {
  assert.equal(chiffresTelephone("+33 6 86 66 52 86"), "0686665286");
  assert.equal(chiffresTelephone("0033686665286"), "0686665286");
  assert.equal(chiffresTelephone("06 86 66 52 86"), "0686665286");
});

test("recherche par ville (sans accents), nom, téléphone, e-mail", () => {
  const l = [
    devis(1),
    devis(2, { pickup: { city: "Benissa" }, delivery: { city: "Lyon" }, client_name: "Karim Test", client_phone: "+33 7 11 22 33 44", client_email: "karim@test.invalid" }),
  ];
  assert.deepEqual(filtrerDevis(l, "digne").map((q) => q.id), ["1"]);
  assert.deepEqual(filtrerDevis(l, "OLLIOULES").map((q) => q.id), ["1"]);
  assert.deepEqual(filtrerDevis(l, "benissa lyon").map((q) => q.id), ["2"]);
  assert.deepEqual(filtrerDevis(l, "karim").map((q) => q.id), ["2"]);
  assert.deepEqual(filtrerDevis(l, "07 11 22").map((q) => q.id), ["2"]);
  assert.deepEqual(filtrerDevis(l, "06 86 66").map((q) => q.id), ["1"]);
  assert.deepEqual(filtrerDevis(l, "karim@test").map((q) => q.id), ["2"]);
  assert.equal(filtrerDevis(l, "").length, 2);
  assert.equal(filtrerDevis(l, "marseille").length, 0);
});

test("écran admin : liste complète + recherche + « Voir les N autres », repli si 094 absente", () => {
  const ecran = readFileSync(new URL("../src/ondemand/AdminOnDemand.jsx", import.meta.url), "utf8");
  assert.doesNotMatch(ecran, /\.slice\(0, 12\)/);
  assert.match(ecran, /devisTarifesValides\(quotes\)/);
  assert.match(ecran, /Rechercher un devis/);
  assert.match(ecran, /Voir les \{trouves\.length - affiches\.length\} autres/);
  const od = readFileSync(new URL("../src/lib/onDemand.js", import.meta.url), "utf8");
  assert.match(od, /secoto_admin_quotes_actifs/);
  assert.match(od, /PGRST202/);
  assert.match(od, /return rpc\("secoto_admin_quotes", \{ p_status: status \}\)/);
});
