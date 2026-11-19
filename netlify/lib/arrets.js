// SECOTO 155 — Livraisons à plusieurs adresses (plateau, plusieurs véhicules).
// Le véhicule 1 va à l'adresse de livraison principale ; un véhicule suivant
// peut avoir sa propre adresse (`livraison`). Le camion fait : départ →
// livraison principale → autres adresses, dans l'ordre des véhicules.
// La distance facturée = trajet complet ; la base ajoute un forfait par arrêt.
import { validCoordinate } from "./secoto-server.js";

const MAX_ARRETS = 2;
const cleAdresse = (a) => String(a?.label || "").trim().toLowerCase();

// Adresses supplémentaires distinctes, dans l'ordre des véhicules.
export function arretsDepuisPayload(payload) {
  if (payload?.mode !== "plateau" || !Array.isArray(payload?.vehicles)) return [];
  const vues = new Set([cleAdresse(payload.delivery)]);
  const arrets = [];
  payload.vehicles.forEach((v, i) => {
    const a = v?.livraison;
    if (i === 0 || !a || !a.verified || !validCoordinate(a)) return;
    const cle = cleAdresse(a);
    if (!cle || vues.has(cle)) return;
    vues.add(cle);
    arrets.push({ label: String(a.label).slice(0, 200), city: a.city || "", postcode: a.postcode || "", country: a.country || "FR", lat: Number(a.lat), lng: Number(a.lng), vehicule: i });
  });
  return arrets.slice(0, MAX_ARRETS);
}

// Itinéraire complet. Sans arrêt : itinéraire habituel. Si un tronçon est
// incalculable, aucune distance n'est inventée : null (prix revu à la main).
export async function itineraireAvecArrets(payload, computeRoute, options = {}) {
  const principal = await computeRoute(payload.pickup, payload.delivery, options);
  const arrets = arretsDepuisPayload(payload);
  if (!principal || !arrets.length) return principal;
  let precedent = payload.delivery;
  let km = Number(principal.distance_km) || 0;
  let minutes = Number(principal.duration_min) || 0;
  const troncons = [];
  for (const a of arrets) {
    const r = await computeRoute(precedent, a, options);
    if (!r) return null;
    km += Number(r.distance_km) || 0;
    minutes += Number(r.duration_min) || 0;
    troncons.push({ ...a, distance_km: r.distance_km });
    precedent = a;
  }
  return {
    ...principal,
    distance_principale_km: principal.distance_km,
    distance_km: Math.round(km * 10) / 10,
    duration_min: Math.round(minutes),
    arrets: troncons,
  };
}
