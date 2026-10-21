// ============================================================================
// SECOTO — libellés et règles annoncées au client.
// ----------------------------------------------------------------------------
// Module volontairement sans dépendance : ce qui est écrit à l'écran doit
// pouvoir être vérifié par un test, sans base ni réseau. Les valeurs ci-dessous
// répètent la politique appliquée en base (migration 035) ; si l'une change là-bas,
// elle doit changer ici, et le test de non-régression le rappelle.
// ============================================================================

// Transport et paiement sont deux états distincts, jamais confondus.
export const ORDER_STATUS_LABEL = {
  awaiting_payment: "Demande reçue — paiement à valider",
  searching_partner: "Recherche d’un transporteur",
  partner_locked: "Confirmation du transporteur en cours",
  partner_confirmed: "Transporteur confirmé",
  picked_up: "Véhicule récupéré",
  delivered: "Livraison effectuée",
  no_partner: "Aucun transporteur disponible — remboursement en cours",
  cancelled: "Annulée",
};

// Fenêtres annoncées au client, alignées sur la politique en base (035).
export const OFFER_WINDOW_HOURS = 48;
export const NO_PARTNER_REFUND_HOURS = 24;
export const FREE_CANCEL_HOURS = 24;
export const LATE_CANCEL_RETAINED_PCT = 50;
export const TVA_MENTION = "TVA non applicable, article 293 B du CGI.";

export const PAYMENT_STATE_LABEL = {
  pending: "Paiement à valider",
  processing: "Paiement en cours de validation",
  requires_capture: "Paiement autorisé (non débité)",
  paid: "Paiement encaissé",
  capture_failed: "Encaissement refusé — moyen de paiement à mettre à jour",
  failed: "Paiement refusé",
  cancelled: "Autorisation libérée",
  refund_pending: "Remboursement en cours",
  refunded: "Remboursé",
};

// 074 : paiement direct (plateau et moto) — la carte est validée sans débit,
// le client est débité au nom du transporteur qui accepte la mission.
export const LAST_MINUTE_HOURS = 2;
export const DIRECT_PAYMENT_STATE_LABEL = {
  ...PAYMENT_STATE_LABEL,
  processing: "Carte en cours de validation",
  requires_capture: "Carte validée (non débitée)",
  paid: "Payé au transporteur",
  capture_failed: "Débit refusé — carte à mettre à jour",
  cancelled: "Aucun débit",
};

export function isDirectOrder(order) {
  return order?.payment_circuit === "direct";
}

// ---- 099 : trois offres (Express, Standard, Éco) ------------------------------
// Commande passée sur une offre : carte enregistrée, débit à la confirmation
// d'un transporteur, sur le compte SECOTO.
export function isDiffereOrder(order) {
  return order?.debit_a_confirmation === true;
}
export const OFFRE_LIBELLE = { express: "Express", standard: "Standard", eco: "Éco" };

// 105 : mention Klarna sous le prix (règlement à l'arrivée). Klarna décide
// seul de l'acceptation et du nombre d'échéances : « par exemple », jamais promis.
export function klarnaSousPrix(cents) {
  const total = Number(cents || 0);
  if (!(total >= 3500)) return "";
  return `ou en plusieurs fois avec Klarna, par exemple 3 × ${formatCents(Math.ceil(total / 3))}, à la livraison`;
}

// ---- 100 : règlement à l'arrivée du véhicule ----------------------------------
// Carte enregistrée à la réservation (0 € prélevé), règlement à la livraison
// selon le mode choisi. Délais alignés sur app_settings['reglement_arrivee'].
export const PLAFOND_ESPECES_EUR = 1000;
export const DELAI_KLARNA_H = 24;
export const DELAI_VIREMENT_H = 48;
export function isReglementArrivee(order) {
  return order?.debit_a_livraison === true;
}
export const MODES_REGLEMENT = [
  { cle: "carte", libelle: "Carte bancaire", detail: "Prélevée automatiquement à l’arrivée du véhicule." },
  { cle: "klarna", libelle: "Klarna — en plusieurs fois", detail: `À l’arrivée, vous réglez en plusieurs fois avec Klarna (sous réserve d’acceptation). Sans paiement sous ${DELAI_KLARNA_H} h, la carte est prélevée.` },
  { cle: "virement", libelle: "Virement bancaire", detail: `À l’arrivée, vous virez à SECOTO (IBAN et référence envoyés par e-mail). Sans virement reçu sous ${DELAI_VIREMENT_H} h, la carte est prélevée.` },
  { cle: "especes", libelle: "Espèces", detail: `Vous payez le transporteur en main propre à l’arrivée (${PLAFOND_ESPECES_EUR.toLocaleString("fr-FR")} € maximum). La carte n’est prélevée que si le paiement n’est pas fait.` },
];
export const MODE_REGLEMENT_LIBELLE = Object.fromEntries(MODES_REGLEMENT.map((m) => [m.cle, m.libelle]));
// 111 : mode de règlement choisi, lisible d'un coup d'œil (admin et transporteur).
const REGLEMENT_COURT = {
  carte: "💳 Carte bancaire (prélevée à l’arrivée)",
  klarna: "💳 Klarna en plusieurs fois",
  virement: "🏦 Virement bancaire",
  especes: "💶 Espèces au transporteur",
};
export function libelleReglement(cle) {
  return REGLEMENT_COURT[cle] || (cle ? String(cle) : "Non renseigné");
}
// Modes proposés pour cette commande : espèces dans la limite légale, virement si l'IBAN SECOTO est renseigné.
export function modesReglementPossibles(order) {
  return MODES_REGLEMENT.filter((m) => (m.cle !== "especes" || order?.especes_possible !== false)
    && (m.cle !== "virement" || order?.virement_possible !== false));
}
// Ce que le client doit faire une fois le véhicule livré.
export function reglementLivraisonTexte(order) {
  if (!isReglementArrivee(order) || order?.status !== "delivered") return "";
  const montant = formatCents(order.client_price_cents ?? order.collect_cents);
  if (order.payment_status === "paid") return `${montant} réglés. Merci !`;
  if (order.mode_reglement === "especes" && order.especes_statut === "recu") return `${montant} réglés en espèces au transporteur. Rien n’a été prélevé sur votre carte.`;
  if (order.mode_reglement === "especes" && order.especes_statut !== "non_recu") return `Réglez ${montant} en espèces au transporteur. Rien n’est prélevé sur votre carte tant qu’il confirme votre paiement.`;
  if (order.mode_reglement === "especes") return `Le transporteur indique ne pas avoir reçu votre paiement : votre carte sera prélevée de ${montant}${order.reglement_echeance ? ` le ${formatDateTime(order.reglement_echeance)}` : ""}. Déjà payé ? Contactez SECOTO.`;
  if (order.payment_status === "capture_failed") return `Le prélèvement de ${montant} n’a pas abouti. Réglez maintenant (carte ou Klarna en plusieurs fois).`;
  if (order.mode_reglement === "klarna") return `Réglez ${montant} en plusieurs fois avec Klarna${order.reglement_echeance ? ` avant le ${formatDateTime(order.reglement_echeance)}` : ""} ; sinon votre carte enregistrée est prélevée.`;
  if (order.mode_reglement === "virement") return `Virez ${montant} à SECOTO${order.reglement_echeance ? ` avant le ${formatDateTime(order.reglement_echeance)}` : ""} ; sinon votre carte enregistrée est prélevée.`;
  return `${montant} vont être prélevés sur votre carte enregistrée.`;
}
// « Prise en charge sous 48 h » / « sous 5 jours » : une fenêtre, jamais un délai garanti.
export function fenetreLibelle(heures) {
  const h = Number(heures);
  if (!Number.isFinite(h) || h <= 0) return "";
  if (h <= 72) return `sous ${Math.round(h)} h`;
  const j = Math.round(h / 24);
  return `sous ${j} jour${j > 1 ? "s" : ""}`;
}
export function transporteursLibelle(n) {
  const k = Number(n) || 0;
  return `${k} transporteur${k > 1 ? "s" : ""} vérifié${k > 1 ? "s" : ""} couvre${k > 1 ? "nt" : ""} ce trajet`;
}

// 081 : décomposition affichée au client (plateau en paiement direct) :
// prix réservé au transporteur + commission de mise en relation SECOTO.
export function decompositionPrix(totalCents, commissionCents) {
  const total = Number(totalCents);
  const commission = Number(commissionCents);
  if (commissionCents === null || commissionCents === undefined || totalCents === null || totalCents === undefined) return null;
  if (!Number.isFinite(total) || !Number.isFinite(commission) || commission < 0 || commission > total) return null;
  return { transport: total - commission, commission };
}

export function paymentStateLabel(order) {
  if (isReglementArrivee(order)) {
    if (order?.payment_status === "paid") return "Payé";
    if (order?.especes_statut === "recu") return "Réglé en espèces";
    if (order?.payment_status === "capture_failed") return "Paiement à régler";
    if (order?.payment_status === "requires_capture") return order?.status === "delivered" ? "Règlement à l’arrivée en cours" : "Carte enregistrée — 0 € prélevé";
    if (order?.payment_status === "cancelled") return "Aucun débit";
  }
  if (isDiffereOrder(order) && order?.payment_status === "requires_capture") return "Carte enregistrée (non débitée)";
  if (isDiffereOrder(order) && order?.payment_status === "cancelled") return "Aucun débit";
  const labels = isDirectOrder(order) ? DIRECT_PAYMENT_STATE_LABEL : PAYMENT_STATE_LABEL;
  return labels[order?.payment_status] || order?.payment_status || "";
}

export const MILESTONES = [
  { key: "demande_recue", label: "Demande reçue" },
  { key: "paiement_encaisse", label: "Paiement encaissé" },
  { key: "partenaire_confirme", label: "Transporteur confirmé" },
  { key: "vehicule_recupere", label: "Véhicule récupéré" },
  { key: "livraison_effectuee", label: "Livraison effectuée" },
];

export function formatCents(cents) {
  if (cents === null || cents === undefined || Number.isNaN(Number(cents))) return "—";
  const value = Number(cents) / 100;
  return value.toLocaleString("fr-FR", { style: "currency", currency: "EUR", minimumFractionDigits: value % 1 ? 2 : 0 });
}

export function formatDateTime(value) {
  if (!value) return "—";
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return "—";
  return date.toLocaleString("fr-FR", { weekday: "short", day: "2-digit", month: "short", hour: "2-digit", minute: "2-digit" });
}

// Un remboursement Stripe part tout de suite, mais c'est la banque du client
// qui le credite : annoncer « rembourse sous 24 h » sans le dire ferait croire
// a un retard, et generait des relances inutiles.
const BANK_REFUND_DELAY = "votre banque le crédite sous 5 à 10 jours";

export function paymentExplanation(order) {
  if (!order) return "";
  if (order.funding === "subscription") {
    return "Mission incluse dans votre forfait : aucun paiement supplémentaire. Le droit est réservé et vous est restitué si aucun transporteur ne confirme.";
  }
  const amount = formatCents(order.client_price_cents ?? order.collect_cents);
  if (isReglementArrivee(order)) {
    return `0 € prélevé aujourd’hui. Vous enregistrez votre carte bancaire en garantie et vous réglez ${amount} `
      + `à l’arrivée du véhicule, avec le mode de votre choix : carte, Klarna en plusieurs fois, virement ou espèces.`;
  }
  if (isDiffereOrder(order)) {
    return `Vous enregistrez votre carte maintenant, sans aucun débit. Vous n’êtes débité de ${amount} `
      + `qu’au moment où un transporteur professionnel indépendant confirme votre transport. `
      + `Si aucun transporteur ne confirme dans la fenêtre choisie, aucun débit : la demande est annulée automatiquement.`;
  }
  if (isDirectOrder(order)) {
    return `Vous validez votre carte maintenant, sans aucun débit. Vous n’êtes débité de ${amount} `
      + `que lorsqu’un transporteur indépendant accepte votre transport, directement sur son compte. `
      + `Sans acceptation sous ${OFFER_WINDOW_HOURS} h, la demande est annulée, sans aucun débit.`;
  }
  return `${amount} sont encaissés dès la validation et gardés en réserve ${OFFER_WINDOW_HOURS} h, `
    + `le temps qu’un transporteur accepte la mission. Si aucun transporteur ne se rend disponible, `
    + `le remboursement intégral est lancé sous ${NO_PARTNER_REFUND_HOURS} h ; ${BANK_REFUND_DELAY}.`;
}

// Règle d'annulation, écrite exactement comme elle est appliquée en base.
export function cancellationPolicy(order) {
  if (isReglementArrivee(order)) {
    return "Annulation sans frais tant que le véhicule n’est pas pris en charge : rien n’est prélevé avant son arrivée.";
  }
  if (isDiffereOrder(order)) {
    return `Annulation : sans frais tant qu’aucun transporteur n’a confirmé. Ensuite, remboursement intégral `
      + `jusqu’à ${FREE_CANCEL_HOURS} h avant la prise en charge ; au-delà, ${LATE_CANCEL_RETAINED_PCT} % sont retenus.`;
  }
  if (isDirectOrder(order)) {
    return `Annulation : sans frais tant qu’aucun transporteur n’a accepté. Ensuite, remboursement intégral `
      + `jusqu’à ${FREE_CANCEL_HOURS} h avant la prise en charge, ${LATE_CANCEL_RETAINED_PCT} % retenus entre `
      + `${FREE_CANCEL_HOURS} h et ${LAST_MINUTE_HOURS} h, aucun remboursement à moins de ${LAST_MINUTE_HOURS} h.`;
  }
  return `Annulation : remboursement intégral jusqu’à ${FREE_CANCEL_HOURS} h avant la prise en charge, `
    + `même si un transporteur a confirmé. Au-delà, ${LATE_CANCEL_RETAINED_PCT} % sont retenus.`;
}

export function cancellationNotice(preview, order = null) {
  if (!preview) return "";
  if (!preview.cancellable) return "Cette commande ne peut plus être annulée depuis l’application.";
  // 100 : rien n'a été prélevé avant l'arrivée du véhicule.
  if (isReglementArrivee(order)) return "Rien n’a été prélevé : annulation sans frais.";
  if (preview.circuit === "direct") {
    if (!preview.charged) return "Votre carte n’a pas été débitée : annulation sans frais.";
    if (preview.last_minute) {
      return `Annulation à moins de ${LAST_MINUTE_HOURS} h de la prise en charge : frais d’annulation de dernière minute, `
        + "aucun remboursement.";
    }
  }
  if (!preview.late) return `Annulation sans frais : vous êtes remboursé intégralement, ${BANK_REFUND_DELAY}.`;
  return `Annulation à moins de ${FREE_CANCEL_HOURS} h de la prise en charge : `
    + `${preview.retained_pct} % sont retenus, ${formatCents(preview.refund_cents)} vous sont remboursés, `
    + `${BANK_REFUND_DELAY}.`;
}

