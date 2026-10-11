// SECOTO 089 — Recherche d'adresses hors de France.
// ----------------------------------------------------------------------------
// La France reste sur la Base Adresse Nationale (appelée par l'app). Ici, on
// ne cherche que les adresses À L'ÉTRANGER, par le premier fournisseur
// configuré :
//   1. Geoapify        (GEOAPIFY_API_KEY, 3 000 requêtes/jour gratuites)
//   2. OpenRouteService (ORS_API_KEY déjà en place, 1 000 requêtes/jour)
// Les clés restent sur le serveur : jamais dans l'app.
// Toute réponse est ramenée au même format que la Base Adresse Nationale :
//   { label, city, postcode, country, lat, lng, kind }

// Pelias (ORS) peut renvoyer le pays en trois lettres.
const ISO3_ISO2 = {
  DEU: "DE", BEL: "BE", LUX: "LU", NLD: "NL", CHE: "CH", LIE: "LI", AUT: "AT", ITA: "IT", ESP: "ES",
  PRT: "PT", AND: "AD", MCO: "MC", SMR: "SM", VAT: "VA", GBR: "GB", IRL: "IE", DNK: "DK", SWE: "SE",
  NOR: "NO", FIN: "FI", ISL: "IS", POL: "PL", CZE: "CZ", SVK: "SK", HUN: "HU", SVN: "SI", HRV: "HR",
  ROU: "RO", BGR: "BG", GRC: "GR", EST: "EE", LVA: "LV", LTU: "LT", MLT: "MT", CYP: "CY", SRB: "RS",
  BIH: "BA", MNE: "ME", ALB: "AL", MKD: "MK", MDA: "MD", UKR: "UA", TUR: "TR", MAR: "MA", DZA: "DZ",
  TUN: "TN", USA: "US", CAN: "CA", FRA: "FR",
};

export function codePays(valeur) {
  const v = String(valeur || "").trim().toUpperCase();
  if (/^[A-Z]{2}$/.test(v)) return v;
  if (/^[A-Z]{3}$/.test(v)) return ISO3_ISO2[v] || null;
  return null;
}

function nettoyerTexte(v, max = 200) {
  return String(v || "").replace(/[<>]/g, "").replace(/\s+/g, " ").trim().slice(0, max);
}
function codePostal(v) {
  const cp = nettoyerTexte(v, 12);
  return /^[A-Za-z0-9][A-Za-z0-9 -]{1,11}$/.test(cp) ? cp : null;
}
function coordonnee(lat, lng) {
  const a = Number(lat);
  const o = Number(lng);
  return Number.isFinite(a) && Number.isFinite(o) && Math.abs(a) <= 90 && Math.abs(o) <= 180 ? { lat: a, lng: o } : null;
}

/** Résultats Geoapify (format=json) → format SECOTO, sans la France. */
export function depuisGeoapify(body) {
  return (body?.results || []).map((r) => {
    const pos = coordonnee(r.lat, r.lon);
    const country = codePays(r.country_code);
    if (!pos || !country || country === "FR") return null;
    return {
      label: nettoyerTexte(r.formatted),
      city: nettoyerTexte(r.city || r.town || r.village || r.county, 120) || null,
      postcode: codePostal(r.postcode),
      country,
      ...pos,
      kind: r.result_type === "building" || r.housenumber ? "housenumber" : nettoyerTexte(r.result_type, 30) || "place",
    };
  }).filter((x) => x && x.label);
}

/** Résultats OpenRouteService (Pelias, GeoJSON) → format SECOTO, sans la France. */
export function depuisOrs(body) {
  return (body?.features || []).map((f) => {
    const p = f?.properties || {};
    const [lng, lat] = f?.geometry?.coordinates || [];
    const pos = coordonnee(lat, lng);
    const country = codePays(p.country_code) || codePays(p.country_a);
    if (!pos || !country || country === "FR") return null;
    return {
      label: nettoyerTexte(p.label),
      city: nettoyerTexte(p.locality || p.localadmin || p.county, 120) || null,
      postcode: codePostal(p.postalcode),
      country,
      ...pos,
      kind: p.layer === "address" ? "housenumber" : nettoyerTexte(p.layer, 30) || "place",
    };
  }).filter((x) => x && x.label);
}

export function fournisseur(env = process.env) {
  if (env.GEOAPIFY_API_KEY) return "geoapify";
  if (env.ORS_API_KEY) return "ors";
  return null;
}

/**
 * Cherche des adresses à l'étranger. Ne lève jamais d'erreur : en cas de
 * panne, renvoie une liste vide (l'app affiche « recherche indisponible »).
 */
export async function chercherAdressesEtrangeres(texte, { env = process.env, fetchImpl = fetch, limite = 6 } = {}) {
  const q = nettoyerTexte(texte, 200);
  const qui = fournisseur(env);
  if (q.length < 3 || !qui) return { items: [], provider: qui, ok: Boolean(qui) };
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), 6000);
  try {
    if (qui === "geoapify") {
      const url = `https://api.geoapify.com/v1/geocode/autocomplete?text=${encodeURIComponent(q)}&lang=fr&limit=${limite + 2}&format=json&apiKey=${encodeURIComponent(env.GEOAPIFY_API_KEY)}`;
      const res = await fetchImpl(url, { signal: controller.signal });
      if (!res.ok) return { items: [], provider: qui, ok: false };
      return { items: depuisGeoapify(await res.json()).slice(0, limite), provider: qui, ok: true };
    }
    const base = String(env.ORS_BASE_URL || "https://api.heigit.org/openrouteservice").replace(/\/+$/, "");
    const url = `${base}/geocode/autocomplete?text=${encodeURIComponent(q)}&size=${limite + 2}&lang=fr`;
    const res = await fetchImpl(url, { headers: { Authorization: env.ORS_API_KEY, Accept: "application/json" }, signal: controller.signal });
    if (!res.ok) return { items: [], provider: qui, ok: false };
    return { items: depuisOrs(await res.json()).slice(0, limite), provider: qui, ok: true };
  } catch {
    return { items: [], provider: qui, ok: false };
  } finally {
    clearTimeout(timer);
  }
}
