// SECOTO 099 — Trois offres : petites aides partagées (sans React).

// Badge de l'offre Standard. « Le plus choisi » ne sera vrai qu'une fois
// prouvé par la mesure (espace admin) : en attendant, « Recommandé ».
export const BADGE_STANDARD = "Recommandé";

// Choix retenu avant la création du compte (réservation sans compte) : il
// survit au passage par l'écran de compte, jamais au-delà de la session.
const cle = (quoteId) => `secoto_offre_${quoteId}`;
export function offreMemorisee(quoteId) {
  try { return quoteId ? sessionStorage.getItem(cle(quoteId)) : null; } catch { return null; }
}
export function memoriserOffre(quoteId, offre) {
  try { if (quoteId && offre) sessionStorage.setItem(cle(quoteId), offre); } catch { /* indisponible */ }
}
export function offreParDefaut(offres, quoteId) {
  if (!offres?.length) return null;
  const memo = offreMemorisee(quoteId);
  if (memo && offres.some((o) => o.cle === memo)) return memo;
  return (offres.find((o) => o.recommande) || offres[0]).cle;
}
