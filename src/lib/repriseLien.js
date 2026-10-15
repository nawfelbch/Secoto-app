// SECOTO 093 — Lien de paiement d'un devis établi sans compte.
// ----------------------------------------------------------------------------
// La page de paiement renvoie ici avec ?reprendre=<jeton>&trajet=…&prix=… .
// On garde le jeton (même clé que le devis sans compte de 049) : dès que le
// compte existe, l'app rattache le devis et ouvre directement le paiement.

// Même clé que CLE_DEVIS_ANONYME (src/lib/onDemand.js) : un seul circuit de reprise.
export const CLE_DEVIS_ANONYME = "secoto:devis-anonyme";
const CLE_REPRISE = "secoto:reprise-lien";

function stockage() {
  try { return typeof localStorage === "undefined" ? null : localStorage; } catch { return null; }
}

export function capterRepriseDepuisLien(loc = typeof window === "undefined" ? null : window.location,
  hist = typeof window === "undefined" ? null : window.history, s = stockage()) {
  if (!loc) return lireReprise(s);
  try {
    const q = new URLSearchParams(loc.search || "");
    const jeton = q.get("reprendre") || "";
    if (!/^[0-9a-f]{32,128}$/i.test(jeton)) return lireReprise(s);
    const prix = Number(q.get("prix"));
    const info = {
      trajet: String(q.get("trajet") || "").slice(0, 120),
      prixCents: Number.isFinite(prix) && prix > 0 ? Math.round(prix) : null,
    };
    try { s?.setItem(CLE_DEVIS_ANONYME, jeton); } catch { /* navigation privée */ }
    try { sessionStorage.setItem(CLE_DEVIS_ANONYME, jeton); } catch { /* idem */ }
    try { s?.setItem(CLE_REPRISE, JSON.stringify(info)); } catch { /* idem */ }
    for (const k of ["reprendre", "trajet", "prix"]) q.delete(k);
    const reste = q.toString();
    hist?.replaceState?.(null, "", `${loc.pathname || "/"}${reste ? `?${reste}` : ""}${loc.hash || ""}`);
    return info;
  } catch {
    return lireReprise(s);
  }
}

export function lireReprise(s = stockage()) {
  try { return JSON.parse(s?.getItem(CLE_REPRISE) || "null"); } catch { return null; }
}

export function oublierReprise(s = stockage()) {
  try { s?.removeItem(CLE_REPRISE); } catch { /* indisponible */ }
}

// Demande faite à l'instant sans compte : même rappel (trajet, prix) sur
// l'écran de compte. Sans prix (devis personnalisé), seul le trajet s'affiche.
export function repriseDepuisDevis(quote) {
  if (!quote) return null;
  const trajet = [quote.pickup?.city, quote.delivery?.city].filter(Boolean).join(" → ").slice(0, 120);
  const avecPrix = ["priced", "manual_priced"].includes(quote.status) && Number(quote.client_price_cents) > 0;
  return { trajet, prixCents: avecPrix ? Math.round(Number(quote.client_price_cents)) : null };
}
