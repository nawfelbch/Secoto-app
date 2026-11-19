// SECOTO 153 — Remise de Noël : dates d'affichage (logo à bonnet, bandeau).
// Le montant réel de la remise vient TOUJOURS du devis calculé en base
// (offre.remise_cents) ; ce fichier ne calcule aucun prix.
// Remise dès le 19/11 (Black Friday, décision de Nawfal) jusqu'au 30/11, puis Noël jusqu'au 31/12. Bonnet de Noël dès la mise en ligne, jusqu'au 31/12.
export const PROMO_NOEL = { debutBonnet: "2026-11-19", debutRemise: "2026-11-19", debut: "2026-12-01", fin: "2027-01-01", pct: 5, plafondEur: 40, finAffichee: "31/12" };

// Date du jour à Paris, au format AAAA-MM-JJ.
export function jourParis(date = new Date()) {
  return new Intl.DateTimeFormat("fr-CA", { timeZone: "Europe/Paris", year: "numeric", month: "2-digit", day: "2-digit" }).format(date);
}

export function promoNoelActive(date = new Date()) {
  const j = jourParis(date);
  return j >= PROMO_NOEL.debut && j < PROMO_NOEL.fin;
}

// Bonnet de Père Noël sur le dernier O : dès maintenant, jusqu'au 31/12.
export function bonnetNoel(date = new Date()) {
  const j = jourParis(date);
  return j >= PROMO_NOEL.debutBonnet && j < PROMO_NOEL.fin;
}

export const texteRemise = (cents) => `−${Math.round(Number(cents || 0) / 100)} €`;
