// ============================================================================
// SECOTO — Module de tarification centralise (source unique de verite).
// ----------------------------------------------------------------------------
// Regles metier (non negociables) :
//  - Plateau   : prix client = cout transporteur x 1,20 (marge 20 %),
//                marge LINEAIRE, SANS plancher minimum.
//  - Convoyage : tarif UNIQUE impose. Client 1,00 EUR/km, remuneration
//                0,55 EUR/km, marge 0,45 EUR/km.
//  - Les frais essence/peage sont NEUTRES pour la marge : refactures au
//    client a l'identique du montant rembourse au convoyeur.
//
// Le meme calcul existe cote base (fonctions SQL secoto_compute_*) via des
// colonnes generees, pour que le prix client ne puisse pas etre falsifie
// depuis le front. Ne JAMAIS dupliquer une constante tarifaire ailleurs.
// ============================================================================

/** Bareme convoyage automobile (EUR/km), impose. */
export const CONVOYAGE_RATES = { client: 1.0, carrier: 0.55, margin: 0.45 };

/** Coefficient de marge plateau : prix client = cout x ce coefficient. */
export const PLATEAU_MARGIN_COEF = 1.2; // +20 %, sans plancher

/** Arrondi a 2 decimales, sur vis-a-vis des flottants. */
export function round2(value) {
  return Math.round((Number(value) + Number.EPSILON) * 100) / 100;
}

/** Format documentaire SECOTO : "XX.00 EUR" (sans HT/TTC, TVA non applicable). */
export function formatAmount(value) {
  return `${round2(value).toFixed(2)} €`;
}

function num(v) {
  const n = Number(v);
  return Number.isFinite(n) && n >= 0 ? n : 0;
}

/**
 * Prix de la prestation facture au client (hors frais reels refactures, qui
 * figurent sur une ligne distincte). Seul montant visible par le client.
 * @param {{type:string, distanceKm?:number|string, carrierCost?:number|string}} m
 */
export function computeClientPrice(m) {
  if (!m) return 0;
  if (m.type === 'plateau') return round2(num(m.carrierCost) * PLATEAU_MARGIN_COEF);
  if (m.type === 'convoyage') return round2(num(m.distanceKm) * CONVOYAGE_RATES.client);
  return 0;
}

/**
 * Remuneration de la prestation reversee au transporteur (hors remboursement
 * des frais reels). Seul montant visible par le transporteur.
 */
export function computeCarrierPay(m) {
  if (!m) return 0;
  if (m.type === 'plateau') return round2(num(m.carrierCost));
  if (m.type === 'convoyage') return round2(num(m.distanceKm) * CONVOYAGE_RATES.carrier);
  return 0;
}

/** Marge SECOTO = prix client - remuneration transporteur (frais exclus). */
export function computeMargin(m) {
  return round2(computeClientPrice(m) - computeCarrierPay(m));
}

/** Frais reels refactures au client (= rembourses au convoyeur). Neutres. */
export function computeReinvoicedExpenses(m) {
  return round2(num(m && m.reinvoicedExpenses));
}

/** Total encaisse aupres du client = prestation + frais refactures. */
export function computeClientTotal(m) {
  return round2(computeClientPrice(m) + computeReinvoicedExpenses(m));
}

/** Total verse au transporteur = remuneration + remboursement des frais. */
export function computeCarrierTotal(m) {
  return round2(computeCarrierPay(m) + computeReinvoicedExpenses(m));
}

/** Vue client : jamais le cout transporteur ni la marge. */
export function clientView(m) {
  return {
    prestation: computeClientPrice(m),
    fraisRefactures: computeReinvoicedExpenses(m),
    total: computeClientTotal(m),
  };
}

/** Vue transporteur : uniquement sa remuneration, jamais le prix client. */
export function carrierView(m) {
  return {
    remuneration: computeCarrierPay(m),
    remboursementFrais: computeReinvoicedExpenses(m),
    total: computeCarrierTotal(m),
  };
}
