// SECOTO 093 — lien de paiement d'un devis sans compte : compte puis paiement.
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { CLE_DEVIS_ANONYME, capterRepriseDepuisLien, lireReprise, oublierReprise } from "../src/lib/repriseLien.js";

const ONDEMAND = readFileSync(new URL("../src/lib/onDemand.js", import.meta.url), "utf8");
const APP = readFileSync(new URL("../src/App.jsx", import.meta.url), "utf8");
const PAY = readFileSync(new URL("../netlify/functions/devis-pay.js", import.meta.url), "utf8");
const SQL = readFileSync(new URL("../supabase/migrations/202610150093_lien_paiement_devis_sans_compte.sql", import.meta.url), "utf8");

function memoire() {
  const m = new Map();
  return { getItem: (k) => (m.has(k) ? m.get(k) : null), setItem: (k, v) => m.set(k, String(v)), removeItem: (k) => m.delete(k), m };
}
const JETON = "a".repeat(64);

test("même clé que la reprise de devis sans compte (049)", () => {
  assert.match(ONDEMAND, new RegExp(`CLE_DEVIS_ANONYME = "${CLE_DEVIS_ANONYME}"`));
});

test("le lien est capté, mémorisé, puis retiré de l'adresse", () => {
  const s = memoire();
  let nouvelle = null;
  const info = capterRepriseDepuisLien(
    { search: `?reprendre=${JETON}&trajet=Digne-les-Bains%20%E2%86%92%20Ollioules&prix=30452&utm_source=sms`, pathname: "/", hash: "" },
    { replaceState: (_a, _b, url) => { nouvelle = url; } }, s);
  assert.deepEqual(info, { trajet: "Digne-les-Bains → Ollioules", prixCents: 30452 });
  assert.equal(s.getItem(CLE_DEVIS_ANONYME), JETON);
  assert.equal(nouvelle, "/?utm_source=sms");
  assert.deepEqual(lireReprise(s), info);
  oublierReprise(s);
  assert.equal(lireReprise(s), null);
});

test("un jeton invalide est ignoré", () => {
  const s = memoire();
  assert.equal(capterRepriseDepuisLien({ search: "?reprendre=<script>", pathname: "/" }, null, s), null);
  assert.equal(s.getItem(CLE_DEVIS_ANONYME), null);
});

test("la page de paiement envoie vers l'app quand un compte est requis", async () => {
  process.env.STRIPE_SECRET_KEY ||= "sk_test_x";
  const { lienReprise } = await import("../netlify/functions/devis-pay.js");
  assert.equal(lienReprise({ reprendre: JETON, trajet: "Digne-les-Bains → Ollioules", amount_cents: 30452 }, "https://app.secoto-transport.fr/"),
    `https://app.secoto-transport.fr/?reprendre=${JETON}&trajet=Digne-les-Bains+%E2%86%92+Ollioules&prix=30452`);
  assert.match(PAY, /data\?\.error === "compte_requis" && data\.reprendre/);
  assert.match(PAY, /statusCode: 302, headers: \{ Location: lienReprise\(data\)/);
});

test("l'app ouvre la création de compte, puis rattache le devis et ouvre le paiement", () => {
  assert.match(APP, /const \[repriseLien\] = useState\(\(\) => capterRepriseDepuisLien\(\)\);/);
  assert.match(APP, /useState\(claimMode \|\| repriseLien \? "auth" : "landing"\)/);
  assert.match(APP, /useState\(claimMode \? "mission" : repriseLien \? "signup" : "login"\)/);
  assert.match(APP, /oublierReprise\(\);\s+setDevisRepris\(quote\);\s+setReserverAussitot/);
});

test("migration : prix du lien honoré, aucune commande sans compte", () => {
  assert.match(SQL, /'compte_requis'/);
  assert.match(SQL, /valid_until = greatest\(coalesce\(valid_until, now\(\)\), v_link\.expires_at\)/);
  assert.doesNotMatch(SQL, /drop |alter policy|disable row level/i);
});
