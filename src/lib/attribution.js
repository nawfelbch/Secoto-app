// SECOTO 088 — Provenance du visiteur (campagne publicitaire).
// ----------------------------------------------------------------------------
// À l'arrivée sur l'application, on lit utm_source, utm_medium, utm_campaign,
// utm_content, gclid et fbclid dans l'adresse, et on les garde 30 jours.
// Une visite sans ces paramètres n'efface rien ; une nouvelle visite venue
// d'une publicité remplace l'ancienne (le dernier clic publicitaire compte).
// Rien n'est envoyé aux régies ici : ces valeurs servent à nos statistiques,
// et ne partent chez Google ou Meta qu'avec l'accord du visiteur.

export const CLE_ATTRIBUTION = "secoto:attribution";
export const DUREE_ATTRIBUTION_MS = 30 * 24 * 3600 * 1000;
export const PARAMS_ATTRIBUTION = Object.freeze(["utm_source", "utm_medium", "utm_campaign", "utm_content", "gclid", "fbclid"]);

const propre = (v) => {
  const s = String(v || "").trim().replace(/[^A-Za-z0-9 _.~:/+@%=|,()-]/g, "").slice(0, 200);
  return s || null;
};

/** Paramètres de provenance présents dans une adresse (objet vide sinon). */
export function lireParametres(search) {
  const p = new URLSearchParams(search || "");
  const out = {};
  for (const k of PARAMS_ATTRIBUTION) {
    const v = propre(p.get(k));
    if (v) out[k] = v;
  }
  return out;
}

function stockage() {
  try { return typeof window !== "undefined" ? window.localStorage : null; } catch { return null; }
}

// Référencement naturel : un visiteur venu de Google sans clic publicitaire
// (pas de gclid). Directement sur l'app (referrer google.*), ou via une page du
// site vitrine qui le signale par utm_content=google-naturel. La page du site
// reste visible en campagne (utm_campaign = adresse de la page).
export const SOURCE_GOOGLE_NATUREL = "google-naturel";
const REFERRER_GOOGLE = /^https?:\/\/(www\.)?google\.[a-z.]{2,8}(\/|$)/i;

export function provenanceNaturelle(params, referrer) {
  if (params.gclid) return params;
  if (params.utm_source === "site" && params.utm_content === SOURCE_GOOGLE_NATUREL) {
    return { ...params, utm_source: SOURCE_GOOGLE_NATUREL };
  }
  if (Object.keys(params).length === 0 && REFERRER_GOOGLE.test(String(referrer || ""))) {
    return { utm_source: SOURCE_GOOGLE_NATUREL, utm_medium: "organic" };
  }
  return params;
}

export function capterAttribution(search = typeof window !== "undefined" ? window.location.search : "", maintenant = Date.now(),
  referrer = typeof document !== "undefined" ? document.referrer : "") {
  const params = provenanceNaturelle(lireParametres(search), referrer);
  if (Object.keys(params).length === 0) return lireAttribution(maintenant);
  const valeur = { ...params, at: new Date(maintenant).toISOString(), expire: maintenant + DUREE_ATTRIBUTION_MS };
  try { stockage()?.setItem(CLE_ATTRIBUTION, JSON.stringify(valeur)); } catch { /* navigation privée */ }
  return valeur;
}

export function lireAttribution(maintenant = Date.now()) {
  try {
    const s = stockage();
    const brut = s?.getItem(CLE_ATTRIBUTION);
    if (!brut) return null;
    const v = JSON.parse(brut);
    if (!v || typeof v !== "object" || !(Number(v.expire) > maintenant)) {
      s?.removeItem(CLE_ATTRIBUTION);
      return null;
    }
    return v;
  } catch {
    return null;
  }
}

/** Ce que l'on transmet au serveur (sans la date d'expiration). */
export function attributionPourEnvoi(maintenant = Date.now()) {
  const v = lireAttribution(maintenant);
  if (!v) return null;
  const out = {};
  for (const k of [...PARAMS_ATTRIBUTION, "at"]) if (v[k]) out[k] = v[k];
  return Object.keys(out).length ? out : null;
}
