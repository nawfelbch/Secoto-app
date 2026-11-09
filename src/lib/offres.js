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

// 132 : départ dans moins de 48 h -> offre Express obligatoire. Les offres
// Standard et Éco restent affichées mais grisées, avec la date à partir de
// laquelle elles redeviennent possibles. La base applique la même règle
// (secoto_od_book_offre refuse Standard/Éco) : l'écran ne fait qu'expliquer.
export const DELAI_EXPRESS_H = 48;

function departDuDevis(quote) {
  if (quote?.pickup_at) return new Date(quote.pickup_at);
  const jour = quote?.schedule?.pickup_date;
  return jour ? new Date(`${jour}T08:00:00`) : null;
}

export function expressObligatoire(quote, now = Date.now()) {
  if (typeof quote?.express_obligatoire === "boolean") return quote.express_obligatoire;
  const depart = departDuDevis(quote);
  return Boolean(depart && !Number.isNaN(depart.getTime()) && depart.getTime() < now + DELAI_EXPRESS_H * 3600000);
}

/** Premier jour (AAAA-MM-JJ) où l'offre Standard redevient possible. */
export function dateMinStandard(quote, now = Date.now()) {
  if (quote?.standard_des) return quote.standard_des;
  const limite = new Date(now + DELAI_EXPRESS_H * 3600000);
  const depart = departDuDevis(quote);
  const jour = new Date(limite);
  if (depart) jour.setHours(depart.getHours(), depart.getMinutes(), 0, 0);
  if (jour.getTime() < limite.getTime()) jour.setDate(jour.getDate() + 1);
  const p = (n) => String(n).padStart(2, "0");
  return `${jour.getFullYear()}-${p(jour.getMonth() + 1)}-${p(jour.getDate())}`;
}

export function dateCourte(iso) {
  const [a, m, j] = String(iso || "").split("-");
  return a && m && j ? `${j}/${m}` : "";
}

/** Offre retenue en tenant compte de l'obligation Express. */
export function offreAutorisee(offres, choix, obligatoire) {
  if (!offres?.length) return null;
  if (!obligatoire) return choix;
  return offres.some((o) => o.cle === "express") ? "express" : null;
}
