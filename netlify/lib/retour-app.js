// ============================================================================
// SECOTO — Retour vers l'application iPhone / Android après une page Stripe.
// ----------------------------------------------------------------------------
// Dans l'application native, une page Stripe hébergée (validation bancaire 3D
// Secure, inscription Stripe du transporteur) s'ouvre dans Safari ou Chrome.
// Sans passerelle, la fin du parcours ramènerait la personne sur le site web,
// déconnectée, au lieu de l'application. La page /retour-app.html la renvoie
// dans l'application (lien secoto://) avec un bouton de secours.
// Sur le web, rien ne change : retour direct sur le site, comme avant.
// ============================================================================

export const PLATEFORMES_NATIVES = new Set(["ios", "android"]);

export function estNatif(platform) {
  return PLATEFORMES_NATIVES.has(String(platform || "").toLowerCase());
}

/**
 * Adresse de retour d'une page Stripe.
 * @param {string} base   origine de l'app web (SECOTO_APP_URL)
 * @param {string} query  paramètres déjà encodés, sans « ? »
 * @param {string} platform  "web" | "ios" | "android"
 */
export function urlRetour(base, query, platform) {
  const origine = String(base || "https://app.secoto-transport.fr").replace(/\/+$/, "");
  const q = String(query || "").replace(/^[?&]+/, "");
  return estNatif(platform)
    ? `${origine}/retour-app.html${q ? `?${q}` : ""}`
    : `${origine}/${q ? `?${q}` : ""}`;
}
