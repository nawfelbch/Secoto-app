import test from "node:test";
import assert from "node:assert/strict";
import { computeRoute } from "../netlify/lib/secoto-server.js";

// 101 : ORS en panne ou hors quota → secours, jamais de devis manuel inutile.
const A = { lat: 48.013, lng: 6.591 };
const B = { lat: 43.302, lng: 5.564 };
const ok = (body) => ({ ok: true, json: async () => body });
const ko = (status = 429) => ({ ok: false, status, text: async () => "quota" });
const silence = () => { const w = console.warn; console.warn = () => {}; return () => { console.warn = w; }; };

test("ORS refusé → Geoapify (camion pour le plateau)", async () => {
  const fin = silence();
  const appels = [];
  const r = await computeRoute(A, B, {
    profile: "hgv",
    env: { ROUTING_PROVIDER: "ors", ORS_API_KEY: "k", GEOAPIFY_API_KEY: "g" },
    fetchImpl: async (url) => {
      appels.push(url);
      if (url.includes("heigit")) return ko();
      return ok({ results: [{ distance: 812345, time: 30000 }] });
    },
  });
  fin();
  assert.deepEqual(r, { distance_km: 812.3, duration_min: 500, provider: "geoapify-truck" });
  assert.match(appels[1], /^https:\/\/api\.geoapify\.com\/v1\/routing\?waypoints=48\.013,6\.591\|43\.302,5\.564&mode=truck&format=json&apiKey=g$/);
});

test("ORS et Geoapify en panne → OSRM public, en France seulement", async () => {
  const fin = silence();
  const appels = [];
  const env = { ROUTING_PROVIDER: "ors", ORS_API_KEY: "k", GEOAPIFY_API_KEY: "g" };
  const fetchImpl = async (url) => {
    appels.push(url);
    if (url.startsWith("https://router.project-osrm.org/")) return ok({ code: "Ok", routes: [{ distance: 790000, duration: 27000 }] });
    throw new Error("down");
  };
  const fr = await computeRoute(A, B, { env, fetchImpl });
  assert.deepEqual(fr, { distance_km: 790, duration_min: 450, provider: "osrm-secours" });
  appels.length = 0;
  const de = await computeRoute({ lat: 50.94, lng: 6.96, country: "DE" }, B, { env, fetchImpl });
  fin();
  assert.equal(de, null, "hors de France : pas d'OSRM public (il prend les ferries)");
  assert.ok(appels.every((u) => !u.includes("project-osrm")));
  assert.match(appels[1], /avoid=ferries/);
});

test("ORS répond → aucun appel de secours ; secours coupable ; sans fournisseur → null", async () => {
  const appels = [];
  const r = await computeRoute(A, B, {
    env: { ROUTING_PROVIDER: "ors", ORS_API_KEY: "k", GEOAPIFY_API_KEY: "g" },
    fetchImpl: async (url) => { appels.push(url); return ok({ features: [{ properties: { summary: { distance: 800000, duration: 28000 } } }] }); },
  });
  assert.equal(r.provider, "ors-driving-car");
  assert.equal(appels.length, 1);
  const fin = silence();
  const coupe = await computeRoute(A, B, { env: { ROUTING_PROVIDER: "ors", ORS_API_KEY: "k", OSRM_SECOURS_URL: "off" }, fetchImpl: async () => ko(503) });
  fin();
  assert.equal(coupe, null);
  assert.equal(await computeRoute(A, B, { env: {}, fetchImpl: async () => { throw new Error("jamais appelé"); } }), null);
});
