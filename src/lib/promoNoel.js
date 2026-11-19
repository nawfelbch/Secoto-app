// SECOTO 153 — Remise de Noël : dates d'affichage (logo à bonnet, bandeau).
// Le montant réel de la remise vient TOUJOURS du devis calculé en base
// (offre.remise_cents) ; ce fichier ne calcule aucun prix.
export const PROMO_NOEL = { debut: "2026-12-01", fin: "2027-01-01", pct: 5, plafondEur: 40, finAffichee: "31/12" };

// Date du jour à Paris, au format AAAA-MM-JJ.
export function jourParis(date = new Date()) {
  return new Intl.DateTimeFormat("fr-CA", { timeZone: "Europe/Paris", year: "numeric", month: "2-digit", day: "2-digit" }).format(date);
}

export function promoNoelActive(date = new Date()) {
  const j = jourParis(date);
  return j >= PROMO_NOEL.debut && j < PROMO_NOEL.fin;
}

export const texteRemise = (cents) => `−${Math.round(Number(cents || 0) / 100)} €`;
