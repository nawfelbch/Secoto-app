import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { arretsDepuisPayload, itineraireAvecArrets } from "../netlify/lib/arrets.js";

const sql = readFileSync(new URL("../supabase/migrations/202611190155_livraisons_multi_adresses.sql", import.meta.url), "utf8");
const A = (label, lat, lng) => ({ label, city: label, postcode: "00000", lat, lng, verified: true });
const modane = A("Modane", 45.2, 6.66), juvisy = A("Juvisy-sur-Orge", 48.69, 2.37), lisses = A("Lisses", 48.6, 2.42);
const payload = (extra = {}) => ({
  mode: "plateau", pickup: modane, delivery: juvisy,
  vehicles: [{ model: "Peugeot 2008" }, { model: "Mini Cooper SE", livraison: lisses }],
  ...extra,
});

test("155 : arrêts tirés des véhicules suivants, sans doublon ni adresse principale, plateau seulement", () => {
  assert.deepEqual(arretsDepuisPayload(payload()).map((a) => [a.city, a.vehicule]), [["Lisses", 1]]);
  assert.equal(arretsDepuisPayload(payload({ mode: "convoyage" })).length, 0);
  assert.equal(arretsDepuisPayload(payload({ vehicles: [{ model: "A" }, { model: "B", livraison: juvisy }] })).length, 0);
  assert.equal(arretsDepuisPayload(payload({ vehicles: [{ model: "A" }, { model: "B", livraison: { ...lisses, verified: false } }] })).length, 0);
});

test("155 : itinéraire complet = départ → livraison principale → autres adresses", async () => {
  const appels = [];
  const route = async (a, b) => { appels.push(`${a.city}>${b.city}`); return a.city === "Modane" ? { distance_km: 650, duration_min: 400, provider: "t" } : { distance_km: 14, duration_min: 20, provider: "t" }; };
  const r = await itineraireAvecArrets(payload(), route);
  assert.deepEqual(appels, ["Modane>Juvisy-sur-Orge", "Juvisy-sur-Orge>Lisses"]);
  assert.equal(r.distance_km, 664);
  assert.equal(r.distance_principale_km, 650);
  assert.equal(r.arrets[0].distance_km, 14);
  // Un tronçon incalculable : jamais de distance inventée.
  assert.equal(await itineraireAvecArrets(payload(), async (a) => (a.city === "Modane" ? { distance_km: 650 } : null)), null);
  // Sans arrêt : itinéraire habituel, inchangé.
  const simple = await itineraireAvecArrets({ ...payload(), vehicles: undefined }, async () => ({ distance_km: 650 }));
  assert.deepEqual(simple, { distance_km: 650 });
});

test("155 : forfait par arrêt (40 € dont 30 € transporteur), pas d'Éco ni de Navette Pro, missions à la bonne adresse", () => {
  assert.match(sql, /'client_eur', 40, 'transporteur_eur', 30/);
  assert.match(sql, /e ->> 'cle' in \('express', 'standard'\)/);
  assert.match(sql, /coalesce\(v_veh -> 'livraison', v_quote\.delivery\) ->> 'label'/);
  assert.match(sql, /TOURNÉE : autre\(s\) livraison\(s\)/);
  assert.doesNotMatch(sql, /drop /i);
});

test("155 : écran — case « Livrer ce véhicule à une autre adresse », convoyage bloqué, −10 % affiché", () => {
  const ecran = readFileSync(new URL("../src/ondemand/OnDemandBooking.jsx", import.meta.url), "utf8");
  assert.match(ecran, /Livrer ce véhicule à une autre adresse/);
  assert.match(ecran, /disabled=\{!toutRoule \|\| multiAdresses\}/);
  assert.doesNotMatch(ecran, /−25 %/);
});
