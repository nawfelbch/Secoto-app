// SECOTO 085 — Calculs du barème transporteur (sans accès réseau).

export const CLASS_LABEL = Object.freeze({ voiture: "Voiture", moto: "Moto", utilitaire: "Utilitaire" });

/** Saisie « 1,05 » ou « 1.05 » -> 1.05 (NaN si vide ou invalide). */
export function parseEuros(value) {
  const n = Number(String(value ?? "").replace(/\s/g, "").replace(",", "."));
  return String(value ?? "").trim() === "" ? NaN : n;
}

/** Exemple affiché sous chaque ligne : prix pour un trajet de 300 km. */
export function exampleTrip(rate, km = 300) {
  const perKm = parseEuros(rate?.eur_per_km);
  const min = parseEuros(rate?.minimum_eur);
  if (!Number.isFinite(perKm)) return null;
  return Math.max(km * perKm, Number.isFinite(min) ? min : 0);
}

export function formatEuros(n) {
  return Number(n).toLocaleString("fr-FR", { style: "currency", currency: "EUR" });
}

export function sameAsDefaults(rates, defaults) {
  return Object.keys(defaults || {}).every((k) => ["eur_per_km", "minimum_eur", "non_rolling_eur"]
    .every((f) => parseEuros(rates?.[k]?.[f]) === Number(defaults[k][f])));
}
