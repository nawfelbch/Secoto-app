// ============================================================================
// SECOTO — Module de tarification centralise (source unique de verite).
// ----------------------------------------------------------------------------
// SECOTO exerce DEUX activites juridiquement distinctes. Elles ne doivent
// jamais etre melangees, ni dans l'app, ni dans les documents, ni en compta.
//
//  CONVOYAGE AUTO — SECOTO est PRESTATAIRE (sous-traitance).
//    Prix impose par la grille SECOTO, paliers CUMULATIFS :
//      forfait minimum      115,00 EUR
//      0 - 300 km           1,00 EUR/km
//      301 - 600 km         0,90 EUR/km
//      au-dela de 600 km    0,88 EUR/km
//    Chaque tarif ne s'applique QU'AUX KILOMETRES DE SA PROPRE TRANCHE.
//    Ne JAMAIS appliquer un tarif unique a la distance totale.
//    Aucun supplément week-end ou gabarit/premium n'est appliqué.
//    Remuneration convoyeur : 0,55 EUR/km. Frais de retour a sa charge.
//    Carburant et peages a la charge de SECOTO, rembourses a l'euro pres,
//    sans aucune marge, et refactures au client a l'identique.
//    SECOTO encaisse la TOTALITE du prix client, a la livraison.
//
//  PLATEAU / MOTO — SECOTO est INTERMEDIAIRE (mise en relation).
//    Le transporteur fixe LIBREMENT son tarif : l'application ne suggere,
//    n'impose et ne recommande aucun prix.
//    SECOTO n'encaisse QUE la commission de 20 %, ajoutee au tarif du
//    transporteur et reglee a la reservation.
//    Le prix du transport ne transite JAMAIS par SECOTO.
//      transportAmount  = tarif du transporteur (regle en direct)
//      commission       = 20 % de ce tarif (seul montant encaisse par SECOTO)
//      clientTotalDue   = transportAmount + commission
//
// Le meme calcul existe cote base (secoto_compute_*, colonnes generees), pour
// que le prix client ne puisse pas etre falsifie depuis le front. Ne JAMAIS
// dupliquer une constante tarifaire ailleurs.
// ============================================================================

/** Forfait minimum convoyage, applique avant les suppléments. */
export const CONVOYAGE_MINIMUM = 115.0;

/** Paliers cumulatifs du convoyage : [borne haute de la tranche, EUR/km]. */
export const CONVOYAGE_TIERS = Object.freeze([
  { upTo: 300, rate: 1.0 },
  { upTo: 600, rate: 0.9 },
  { upTo: Infinity, rate: 0.88 },
]);

/** Rémunération du convoyeur, par kilomètre parcouru. */
export const CONVOYEUR_RATE = 0.55;

/** Ancien supplément urgence, conservé uniquement pour la compatibilité. */
export const SURCHARGE_URGENT_PCT = 30;

/** Taux de commission SECOTO sur les missions plateau / moto. */
export const PLATEAU_COMMISSION_PCT = 20;

/** Arrondi à 2 décimales, sûr vis-à-vis des flottants. */
export function round2(value) {
  return Math.round((Number(value) + Number.EPSILON) * 100) / 100;
}

/** Format documentaire SECOTO : « XX.00 € » (TVA non applicable, art. 293 B). */
export function formatAmount(value) {
  return `${round2(value).toFixed(2)} €`;
}

function num(v) {
  const n = Number(v);
  return Number.isFinite(n) && n >= 0 ? n : 0;
}

function bool(v) {
  return v === true || v === "true" || v === 1 || v === "1";
}

/**
 * Prix de base du convoyage : somme des paliers cumulatifs, plancher 115 €.
 * 80 km -> 115,00 · 400 km -> 390,00 · 935 km -> 864,80
 */
export function computeConvoyageBase(distanceKm) {
  const distance = num(distanceKm);
  let remaining = distance;
  let previous = 0;
  let total = 0;
  for (const tier of CONVOYAGE_TIERS) {
    if (remaining <= 0) break;
    const span = tier.upTo - previous;
    const inTier = Math.min(remaining, span);
    total += inTier * tier.rate;
    remaining -= inTier;
    previous = tier.upTo;
  }
  return Math.max(CONVOYAGE_MINIMUM, round2(total));
}

/** Coefficient historique : week-end et gabarit/premium sont neutralisés. */
export function computeSurchargeCoefficient(m) {
  return bool(m && m.surchargeUrgent) ? 1 + SURCHARGE_URGENT_PCT / 100 : 1;
}

/**
 * Montant réellement ENCAISSÉ PAR SECOTO auprès du client.
 *  - convoyage : la totalité de la prestation (barème + suppléments)
 *  - plateau   : uniquement la commission de 20 %
 */
export function computeClientPrice(m) {
  if (!m) return 0;
  if (m.type === "plateau") {
    return round2(num(m.carrierCost) * (PLATEAU_COMMISSION_PCT / 100));
  }
  if (m.type === "convoyage") {
    return round2(computeConvoyageBase(m.distanceKm) * computeSurchargeCoefficient(m));
  }
  return 0;
}

/** Commission SECOTO. Nulle en convoyage : SECOTO y est prestataire. */
export function computeCommission(m) {
  if (!m || m.type !== "plateau") return 0;
  return round2(num(m.carrierCost) * (PLATEAU_COMMISSION_PCT / 100));
}

/** Prix du transport plateau, réglé DIRECTEMENT au transporteur. Hors SECOTO. */
export function computeTransportAmount(m) {
  if (!m || m.type !== "plateau") return 0;
  return round2(num(m.carrierCost));
}

/** Total déboursé par le client, toutes lignes confondues. */
export function computeClientTotalDue(m) {
  return round2(computeClientPrice(m) + computeTransportAmount(m));
}

/**
 * Rémunération de la prestation revenant au prestataire.
 *  - convoyage : 0,55 €/km, versés par SECOTO
 *  - plateau   : son tarif intégral, que SECOTO ne verse PAS (réglé en direct)
 */
export function computeCarrierPay(m) {
  if (!m) return 0;
  if (m.type === "plateau") return round2(num(m.carrierCost));
  if (m.type === "convoyage") return round2(num(m.distanceKm) * CONVOYEUR_RATE);
  return 0;
}

/** Marge nette SECOTO. En plateau, c'est la commission (SECOTO ne verse rien). */
export function computeMargin(m) {
  if (!m) return 0;
  if (m.type === "plateau") return computeCommission(m);
  return round2(computeClientPrice(m) - computeCarrierPay(m));
}

/** Frais réels refacturés au client (= remboursés au convoyeur). Neutres. */
export function computeReinvoicedExpenses(m) {
  return round2(num(m && m.reinvoicedExpenses));
}

/** Total encaissé auprès du client = prestation + frais refacturés. */
export function computeClientTotal(m) {
  return round2(computeClientPrice(m) + computeReinvoicedExpenses(m));
}

/** Total versé au transporteur = rémunération + remboursement des frais. */
export function computeCarrierTotal(m) {
  return round2(computeCarrierPay(m) + computeReinvoicedExpenses(m));
}

/** Vue client : jamais le coût transporteur en convoyage, jamais la marge. */
export function clientView(m) {
  if (m && m.type === "plateau") {
    return {
      commission: computeCommission(m),
      transport: computeTransportAmount(m),
      fraisRefactures: 0,
      total: computeClientTotalDue(m),
    };
  }
  return {
    prestation: computeClientPrice(m),
    fraisRefactures: computeReinvoicedExpenses(m),
    total: computeClientTotal(m),
  };
}

/** Vue transporteur : uniquement sa rémunération, jamais le prix client. */
export function carrierView(m) {
  return {
    remuneration: computeCarrierPay(m),
    remboursementFrais: computeReinvoicedExpenses(m),
    total: computeCarrierTotal(m),
  };
}
