// SECOTO 088 — Consentement cookies et balises publicitaires (web uniquement).
// ----------------------------------------------------------------------------
// • Refus par défaut : Google Consent Mode v2 démarre « refusé » partout.
// • Aucune balise (Google, Meta) n'est chargée avant un clic sur « Accepter ».
// • Le choix est gardé six mois, puis redemandé. Il se change dans le Profil.
// • Applications iPhone / Android : jamais de bandeau, jamais de traceur
//   (Apple exigerait sinon la demande de suivi ATT).
// • Aperçus de test Netlify : balises chargées seulement si
//   VITE_TRACKING_PREVIEW=1, pour ne pas fausser les campagnes.
// Les identifiants viennent des variables Vite (aucun n'est secret) :
//   VITE_GA4_ID (G-…), VITE_GADS_ID (AW-…), VITE_META_PIXEL_ID.

export const CLE_COOKIES = "secoto:cookies";
export const VERSION_COOKIES = 1;
export const DUREE_CHOIX_MS = 182 * 24 * 3600 * 1000; // six mois

const env = (typeof import.meta !== "undefined" && import.meta.env) || {};
export const IDS = Object.freeze({
  ga4: env.VITE_GA4_ID || "",
  ads: env.VITE_GADS_ID || "",
  meta: env.VITE_META_PIXEL_ID || "",
});

// --------------------------------------------------------------- calculs purs
export function choixValide(v, maintenant = Date.now()) {
  return Boolean(v && (v.choix === "accepte" || v.choix === "refuse")
    && v.version === VERSION_COOKIES && Number(v.at) + DUREE_CHOIX_MS > maintenant);
}

export function hoteAutorise(hostname, preview = env.VITE_TRACKING_PREVIEW === "1") {
  if (hostname === "app.secoto-transport.fr" || hostname === "www.app.secoto-transport.fr") return true;
  return Boolean(preview && /\.netlify\.app$/.test(hostname || ""));
}

export function estNatif() {
  if (typeof window === "undefined") return true;
  const p = window.location?.protocol;
  if (p === "capacitor:" || p === "file:") return true;
  try { return Boolean(window.Capacitor?.isNativePlatform?.()); } catch { return false; }
}

// ------------------------------------------------------------------ stockage
function stockage() {
  try { return window.localStorage; } catch { return null; }
}
export function lireChoix(maintenant = Date.now()) {
  try {
    const v = JSON.parse(stockage()?.getItem(CLE_COOKIES) || "null");
    return choixValide(v, maintenant) ? v : null;
  } catch {
    return null;
  }
}
function ecrireChoix(choix) {
  try { stockage()?.setItem(CLE_COOKIES, JSON.stringify({ choix, at: Date.now(), version: VERSION_COOKIES })); } catch { /* indisponible */ }
}

// ------------------------------------------------------------ état partagé
const ecouteurs = new Set();
let charge = { google: false, meta: false };

/** Le bandeau doit-il s'afficher ? (web, pas encore de choix valide) */
export function bandeauRequis() {
  return !estNatif() && !lireChoix();
}
export function consentementPub() {
  if (estNatif()) return null;
  const c = lireChoix();
  return c ? c.choix === "accepte" : null;
}
export function surChangement(fn) {
  ecouteurs.add(fn);
  return () => ecouteurs.delete(fn);
}
export function ouvrirReglagesCookies() {
  try { window.dispatchEvent(new CustomEvent("secoto:cookies-ouvrir")); } catch { /* ancien navigateur */ }
}

function gtag() {
  window.dataLayer = window.dataLayer || [];
  window.dataLayer.push(arguments);
}

function ajouterScript(src) {
  const s = document.createElement("script");
  s.async = true;
  s.src = src;
  document.head.appendChild(s);
}

function chargerGoogle() {
  if (charge.google || !(IDS.ga4 || IDS.ads)) return;
  charge.google = true;
  ajouterScript(`https://www.googletagmanager.com/gtag/js?id=${encodeURIComponent(IDS.ga4 || IDS.ads)}`);
  gtag("js", new Date());
  if (IDS.ga4) gtag("config", IDS.ga4);
  if (IDS.ads) gtag("config", IDS.ads);
}

function chargerMeta() {
  if (charge.meta || !IDS.meta) return;
  charge.meta = true;
  /* Code officiel du Pixel Meta, chargé seulement après accord. */
  !function(f,b,e,v,n,t,s){if(f.fbq)return;n=f.fbq=function(){n.callMethod?
  n.callMethod.apply(n,arguments):n.queue.push(arguments)};if(!f._fbq)f._fbq=n;
  n.push=n;n.loaded=!0;n.version='2.0';n.queue=[];t=b.createElement(e);t.async=!0;
  t.src=v;s=b.getElementsByTagName(e)[0];s.parentNode.insertBefore(t,s)}(window,
  document,'script','https://connect.facebook.net/en_US/fbevents.js');
  window.fbq("consent", "grant");
  // Pas d'événements devinés par Meta (« Subscribe » sur un clic de bouton) :
  // seuls les événements envoyés par l'app comptent.
  window.fbq("set", "autoConfig", false, IDS.meta);
  window.fbq("init", IDS.meta);
  window.fbq("track", "PageView");
}

function appliquer(accepte) {
  if (typeof window === "undefined" || estNatif()) return;
  const etat = accepte ? "granted" : "denied";
  gtag("consent", "update", { ad_storage: etat, analytics_storage: etat, ad_user_data: etat, ad_personalization: etat });
  if (!accepte) {
    try { window.fbq?.("consent", "revoke"); } catch { /* rien */ }
    return;
  }
  if (!hoteAutorise(window.location.hostname)) return;
  chargerGoogle();
  chargerMeta();
}

/** À appeler une fois, avant le premier affichage. */
export function initialiserConsentement() {
  if (typeof window === "undefined" || estNatif()) return;
  gtag("consent", "default", {
    ad_storage: "denied", analytics_storage: "denied", ad_user_data: "denied", ad_personalization: "denied",
    wait_for_update: 500,
  });
  const c = lireChoix();
  if (c?.choix === "accepte") appliquer(true);
}

export function enregistrerChoix(accepte) {
  ecrireChoix(accepte ? "accepte" : "refuse");
  appliquer(accepte);
  for (const fn of ecouteurs) { try { fn(accepte); } catch { /* écouteur fautif ignoré */ } }
}

// ----------------------------------------------------------------- événements
/**
 * prix_affiche, compte_cree, commande_payee. Envoyés seulement après accord.
 * commande_payee part vers Google Analytics uniquement : Meta et Google Ads la
 * reçoivent du serveur (valeur = commission, jamais affichée dans le navigateur),
 * avec le même event_id.
 */
export function evenement(nom, params = {}, { eventId } = {}) {
  try {
    if (estNatif() || consentementPub() !== true || !hoteAutorise(window.location.hostname)) return false;
    const p = { ...params, ...(eventId ? { event_id: eventId } : {}) };
    if (IDS.ga4) gtag("event", nom, p);
    if (IDS.meta && typeof window.fbq === "function") {
      const options = eventId ? { eventID: eventId } : undefined;
      if (nom === "compte_cree") window.fbq("track", "CompleteRegistration", {}, options);
      else if (nom === "prix_affiche") window.fbq("trackCustom", "prix_affiche", params, options);
    }
    return true;
  } catch {
    return false;
  }
}
