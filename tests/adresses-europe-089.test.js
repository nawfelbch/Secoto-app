import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import { chercherAdressesEtrangeres, codePays, depuisGeoapify, depuisOrs, fournisseur } from "../netlify/lib/adresses-internationales.js";
import { computeRoute, estInternational, paysAdresse } from "../netlify/lib/secoto-server.js";
import { SCORE_FRANCE_SUR, doitChercherEtranger, nomPays } from "../src/lib/adressesUtil.js";

const lire = (f) => readFileSync(new URL(`../${f}`, import.meta.url), "utf8");
const reponse = (body, ok = true) => ({ ok, json: async () => body });

test("pays : codes à deux et trois lettres, France par défaut", () => {
  assert.equal(codePays("de"), "DE");
  assert.equal(codePays("DEU"), "DE");
  assert.equal(codePays("XYZ"), null);
  assert.equal(codePays(""), null);
  assert.equal(paysAdresse({}), "FR");
  assert.equal(paysAdresse({ country: "ch" }), "CH");
  assert.equal(estInternational({ postcode: "92260" }, { country: "FR" }), false);
  assert.equal(estInternational({ country: "DE" }, {}), true);
  assert.equal(nomPays("FR"), "");
  assert.ok(nomPays("DE").length > 0);
});

test("Geoapify : résultats ramenés au format SECOTO, France et données douteuses écartées", () => {
  const items = depuisGeoapify({ results: [
    { formatted: "Teststraße 1, 10115 Berlin, Allemagne", city: "Berlin", postcode: "10115", country_code: "de", lat: 52.53, lon: 13.38, result_type: "building", housenumber: "1" },
    { formatted: "1 rue X, 75001 Paris, France", city: "Paris", postcode: "75001", country_code: "fr", lat: 48.86, lon: 2.34, result_type: "building" },
    { formatted: "<b>Zürich</b>", city: "Zürich", postcode: "<x>", country_code: "ch", lat: 47.37, lon: 8.54, result_type: "city" },
    { formatted: "Nulle part", country_code: "de", lat: 999, lon: 0 },
  ] });
  assert.equal(items.length, 2);
  assert.deepEqual(items[0], { label: "Teststraße 1, 10115 Berlin, Allemagne", city: "Berlin", postcode: "10115", country: "DE", lat: 52.53, lng: 13.38, kind: "housenumber" });
  assert.equal(items[1].label, "bZürich/b");
  assert.equal(items[1].postcode, null, "code postal non conforme retiré");
  assert.equal(items[1].kind, "city");
});

test("OpenRouteService : pays en trois lettres accepté", () => {
  const items = depuisOrs({ features: [
    { geometry: { coordinates: [8.54, 47.37] }, properties: { label: "Bahnhofstrasse 1, Zürich, Switzerland", locality: "Zürich", postalcode: "8001", country_a: "CHE", layer: "address" } },
    { geometry: { coordinates: [2.3, 48.8] }, properties: { label: "Paris, France", country_a: "FRA", layer: "locality" } },
  ] });
  assert.equal(items.length, 1);
  assert.equal(items[0].country, "CH");
  assert.equal(items[0].kind, "housenumber");
});

test("recherche : Geoapify d'abord, sinon la clé OpenRouteService déjà en place, jamais d'erreur levée", async () => {
  assert.equal(fournisseur({ GEOAPIFY_API_KEY: "g", ORS_API_KEY: "o" }), "geoapify");
  assert.equal(fournisseur({ ORS_API_KEY: "o" }), "ors");
  assert.equal(fournisseur({}), null);
  let url = "";
  const g = await chercherAdressesEtrangeres("Berlin", { env: { GEOAPIFY_API_KEY: "cle" }, fetchImpl: async (u) => { url = u; return reponse({ results: [] }); } });
  assert.match(url, /api\.geoapify\.com\/v1\/geocode\/autocomplete\?text=Berlin&lang=fr/);
  assert.deepEqual(g, { items: [], provider: "geoapify", ok: true });
  let entetes = null;
  await chercherAdressesEtrangeres("Zürich", { env: { ORS_API_KEY: "ors" }, fetchImpl: async (u, o) => { url = u; entetes = o.headers; return reponse({ features: [] }); } });
  assert.match(url, /heigit\.org\/openrouteservice\/geocode\/autocomplete\?text=Z%C3%BCrich/);
  assert.equal(entetes.Authorization, "ors");
  const panne = await chercherAdressesEtrangeres("Madrid", { env: { ORS_API_KEY: "o" }, fetchImpl: async () => { throw new Error("réseau"); } });
  assert.deepEqual(panne, { items: [], provider: "ors", ok: false });
  assert.deepEqual(await chercherAdressesEtrangeres("ab", { env: { ORS_API_KEY: "o" } }), { items: [], provider: "ors", ok: true });
});

test("itinéraire : France inchangé (GET), étranger sans ferry (POST)", async () => {
  const env = { ROUTING_PROVIDER: "ors", ORS_API_KEY: "k" };
  const appels = [];
  const fetchImpl = async (u, o) => {
    appels.push({ u, o });
    if (o.method === "POST") return reponse({ routes: [{ summary: { distance: 1052340, duration: 38400 } }] });
    return reponse({ features: [{ properties: { summary: { distance: 465000, duration: 16800 } } }] });
  };
  const fr = await computeRoute({ lat: 48.79, lng: 2.29 }, { lat: 45.76, lng: 4.83 }, { env, fetchImpl });
  assert.equal(fr.distance_km, 465);
  assert.equal(appels[0].o.method, undefined, "France : même appel qu'avant");
  const de = await computeRoute({ lat: 52.53, lng: 13.38, country: "DE" }, { lat: 48.79, lng: 2.29 }, { env, fetchImpl, profile: "hgv" });
  assert.equal(de.distance_km, 1052.3);
  assert.match(de.provider, /sans-ferry/);
  const corps = JSON.parse(appels[1].o.body);
  assert.deepEqual(corps.options, { avoid_features: ["ferries"] });
  assert.match(appels[1].u, /driving-hgv$/);
  // Pas de route terrestre (île, Royaume-Uni) : null → devis établi par SECOTO.
  const ile = await computeRoute({ lat: 39.57, lng: 2.65, country: "ES" }, { lat: 48.79, lng: 2.29 }, { env, fetchImpl: async () => reponse({}, false) });
  assert.equal(ile, null);
});

test("app : la recherche à l'étranger part seulement si la France n'a rien de sûr", () => {
  assert.equal(SCORE_FRANCE_SUR, 0.6);
  assert.equal(doitChercherEtranger("12 rue de la Paix Paris", [{ score: 0.92 }], false), false);
  assert.equal(doitChercherEtranger("Hauptstraße 5 Kappelen", [{ score: 0.31 }], false), true);
  assert.equal(doitChercherEtranger("Bern", [], false), false, "trop court : pas d'appel inutile");
  assert.equal(doitChercherEtranger("Bern", [], true), true, "« Adresse hors de France » choisie");
  const champ = lire("src/ondemand/VerifiedAddressField.jsx");
  assert.match(champ, /Adresse hors de France \?/);
  assert.match(champ, /Powered by Geoapify/);
  assert.match(champ, /country: "FR"/);
  assert.match(lire("src/lib/onDemand.js"), /getServerFunctionUrl\("adresse-internationale"\)/);
});

test("migration 089 : additive, France inchangée, interrupteur", () => {
  const m = lire("supabase/migrations/202610110089_adresses_europe.sql");
  assert.doesNotMatch(m, /\b(drop table|drop column|alter column|drop policy|truncate|delete from)\b/i);
  assert.match(m, /'adresses_internationales'/);
  assert.match(m, /then coalesce\(p_adresse ->> 'postcode', ''\) ~ '\^\[0-9\]\{5\}\$'/);
  assert.match(m, /'international_hors_zone'/);
  const f = lire("netlify/functions/adresse-internationale.js");
  assert.doesNotMatch(f, /export const handler/);
  assert.match(f, /export default withLambda\(withCors\(traiter\)\)/);
});
