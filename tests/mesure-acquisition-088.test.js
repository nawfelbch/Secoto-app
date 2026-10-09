import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import { DUREE_ATTRIBUTION_MS, lireParametres } from "../src/lib/attribution.js";
import { DUREE_CHOIX_MS, VERSION_COOKIES, choixValide, hoteAutorise } from "../src/lib/consentement.js";
import { DEPARTEMENTS, RACCOURCIS, appliquerRaccourci, basculer, resumeDepartements } from "../src/lib/couvertureUtil.js";
import { derniersJours } from "../src/lib/dirigeantUtil.js";
import { csvGoogle, envoyerConversionsMeta, evenementMeta, fbcDepuisFbclid, heureParis } from "../netlify/lib/conversions.js";
import { attributionPropre } from "../netlify/lib/attribution-serveur.js";
import { authentifie } from "../netlify/functions/conversions-google.js";

const lire = (f) => readFileSync(new URL(`../${f}`, import.meta.url), "utf8");

test("provenance : utm, gclid et fbclid lus dans l'adresse, rien d'autre", () => {
  const p = lireParametres("?utm_source=google&utm_medium=cpc&utm_campaign=plateau%20idf&gclid=Cj0_abc-1&fbclid=Iw1&x=1&utm_term=t");
  assert.deepEqual(p, { utm_source: "google", utm_medium: "cpc", utm_campaign: "plateau idf", gclid: "Cj0_abc-1", fbclid: "Iw1" });
  assert.deepEqual(lireParametres("?utm_campaign=<script>"), { utm_campaign: "script" });
  assert.deepEqual(lireParametres(""), {});
  assert.equal(DUREE_ATTRIBUTION_MS, 30 * 24 * 3600 * 1000);
});

test("cookies : choix valable six mois, refus par défaut, balises seulement sur le vrai domaine", () => {
  const maintenant = Date.now();
  assert.equal(choixValide({ choix: "accepte", at: maintenant, version: VERSION_COOKIES }, maintenant), true);
  assert.equal(choixValide({ choix: "refuse", at: maintenant - DUREE_CHOIX_MS - 1, version: VERSION_COOKIES }, maintenant), false);
  assert.equal(choixValide({ choix: "peut-etre", at: maintenant, version: VERSION_COOKIES }, maintenant), false);
  assert.equal(choixValide(null, maintenant), false);
  assert.equal(hoteAutorise("app.secoto-transport.fr", false), true);
  assert.equal(hoteAutorise("paiement-direct-plateau--appsecoto.netlify.app", false), false);
  assert.equal(hoteAutorise("paiement-direct-plateau--appsecoto.netlify.app", true), true);
  assert.equal(hoteAutorise("localhost", true), false);
});

test("bandeau : Refuser et Accepter au même niveau, aucun traceur dans index.html, pixel OpenAI retiré", () => {
  const b = lire("src/BanniereCookies.jsx");
  const boutons = b.match(/<button type="button" className="btn cookies-btn"/g) || [];
  assert.equal(boutons.length, 2, "deux boutons de même classe");
  assert.ok(b.indexOf("Refuser") < b.indexOf("Accepter"));
  const html = lire("index.html");
  assert.doesNotMatch(html, /oaiq|googletagmanager|fbevents|connect\.facebook/);
  assert.doesNotMatch(lire("src/lib/mesure.js"), /oaiq/);
  assert.doesNotMatch(lire("netlify/functions/stripe-webhook.js"), /mesurerConversion|openai/i);
  const c = lire("src/lib/consentement.js");
  assert.match(c, /ad_storage: "denied", analytics_storage: "denied", ad_user_data: "denied", ad_personalization: "denied"/);
  assert.match(lire("public/politique-confidentialite.html"), /id="cookies"/);
});

test("couverture : départements de métropole et Corse, raccourcis, résumé", () => {
  assert.equal(DEPARTEMENTS.length, 96);
  assert.ok(DEPARTEMENTS.includes("2A") && DEPARTEMENTS.includes("2B") && !DEPARTEMENTS.includes("20"));
  assert.deepEqual(basculer(["92"], "75"), ["75", "92"]);
  assert.deepEqual(basculer(["75", "92"], "92"), ["75"]);
  const idf = RACCOURCIS.find((r) => r.key === "idf").deps;
  assert.equal(appliquerRaccourci([], idf).length, 8);
  assert.deepEqual(appliquerRaccourci(idf, idf), []);
  assert.equal(resumeDepartements(DEPARTEMENTS), "Toute la France");
  assert.equal(resumeDepartements([]), "Aucun département choisi");
  assert.match(lire("src/CouvertureTransporteur.jsx"), /useState\(Boolean\(statusInitial\?\.moto\)\)/);
});

test("Meta : événement Purchase, valeur = commission, données hachées, event_id commun", () => {
  const e = evenementMeta({
    event_id: "cmd-p1", event_time: 1760000000, value: "80.00", currency: "EUR",
    email_sha256: "a".repeat(64), phone_sha256: "b".repeat(64), external_id_sha256: "c".repeat(64),
    fbclid: "IwX", fbclid_at_ms: 1760000000000, order_ref: "CMD-2026-X",
  });
  assert.equal(e.event_name, "Purchase");
  assert.equal(e.event_id, "cmd-p1");
  assert.equal(e.custom_data.value, 80);
  assert.equal(e.user_data.fbc, "fb.1.1760000000000.IwX");
  assert.deepEqual(e.user_data.em, ["a".repeat(64)]);
  assert.equal(fbcDepuisFbclid(null), undefined);
});

test("Meta : rien n'est envoyé sans identifiants ; un échec réseau ne casse rien", async () => {
  assert.deepEqual(await envoyerConversionsMeta({}, { env: {} }), { envoyees: 0, raison: "non_configure" });
  const appels = [];
  const admin = {
    rpc: async (nom, args) => {
      appels.push(nom);
      if (nom === "secoto_conversions_meta_a_envoyer") return { data: [{ id: "1", event_id: "cmd-1", value: 10 }], error: null };
      return { data: null, error: null, args };
    },
  };
  const env = { META_PIXEL_ID: "123", META_CAPI_TOKEN: "t", META_TEST_EVENT_CODE: "TEST1" };
  let corps = null;
  const ok = await envoyerConversionsMeta(admin, { env, fetchImpl: async (_u, o) => { corps = JSON.parse(o.body); return { ok: true }; } });
  assert.equal(ok.envoyees, 1);
  assert.equal(corps.test_event_code, "TEST1");
  const ko = await envoyerConversionsMeta(admin, { env, fetchImpl: async () => { throw new Error("réseau"); } });
  assert.equal(ko.envoyees, 0);
  assert.ok(appels.includes("secoto_conversion_meta_resultat"));
});

test("Google Ads : fichier d'import par gclid, heure de Paris, accès protégé", () => {
  assert.equal(heureParis("2026-10-12T12:05:00Z"), "2026-10-12 14:05:00");
  const csv = csvGoogle([{ gclid: "Cj0", event_time: "2026-10-12T12:05:00Z", value: 80, currency: "EUR" }, { gclid: null, event_time: "2026-10-12T12:05:00Z" }]);
  assert.equal(csv, "Parameters:TimeZone=Europe/Paris\nGoogle Click ID,Conversion Name,Conversion Time,Conversion Value,Conversion Currency\nCj0,commande_payee,2026-10-12 14:05:00,80.00,EUR\n");
  const env = { GADS_CSV_USER: "secoto", GADS_CSV_PASSWORD: "motdepasse" };
  const basic = (u, p) => ({ authorization: `Basic ${Buffer.from(`${u}:${p}`).toString("base64")}` });
  assert.equal(authentifie(basic("secoto", "motdepasse"), env), true);
  assert.equal(authentifie(basic("secoto", "faux"), env), false);
  assert.equal(authentifie({}, env), false);
  assert.equal(authentifie(basic("", ""), {}), false, "sans mot de passe configuré, tout est refusé");
});

test("serveur : provenance filtrée avant la base ; période de 30 jours", () => {
  assert.deepEqual(attributionPropre({ utm_source: " google ", gclid: "x".repeat(300), autre: "y", at: "2026-10-09T10:00:00Z" }),
    { utm_source: "google", gclid: "x".repeat(200), at: "2026-10-09T10:00:00Z" });
  assert.deepEqual(attributionPropre("texte"), {});
  assert.deepEqual(derniersJours(30, new Date(2026, 9, 9, 15)), { debut: "2026-09-10", fin: "2026-10-10" });
});

test("migration 088 : additive, déclencheurs sans risque pour le paiement", () => {
  const m = lire("supabase/migrations/202610100088_mesure_acquisition.sql");
  assert.doesNotMatch(m, /\b(drop table|drop column|alter column|drop policy|truncate)\b/i);
  assert.doesNotMatch(m, /\bdelete from public\./i);
  const trig = m.split("function secoto_private.trg_payment_conversion()")[1].split("$f$;")[0];
  assert.match(trig, /exception when others then/);
  assert.match(m, /revoke all on table public\.ad_conversions from public, anon, authenticated/);
});
