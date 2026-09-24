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
  return `${amount} sont encaissés dès la validation et gardés en réserve ${OFFER_WINDOW_HOURS} h, `
    + `le temps qu’un transporteur accepte la mission. Si aucun transporteur ne se rend disponible, `
    + `le remboursement intégral est lancé sous ${NO_PARTNER_REFUND_HOURS} h ; ${BANK_REFUND_DELAY}.`;
}

// Règle d'annulation, écrite exactement comme elle est appliquée en base.
export function cancellationPolicy() {
  return `Annulation : remboursement intégral jusqu’à ${FREE_CANCEL_HOURS} h avant la prise en charge, `
    + `même si un transporteur a confirmé. Au-delà, ${LATE_CANCEL_RETAINED_PCT} % sont retenus.`;
}

export function cancellationNotice(preview) {
  if (!preview) return "";
  if (!preview.cancellable) return "Cette commande ne peut plus être annulée depuis l’application.";
  if (!preview.late) return `Annulation sans frais : vous êtes remboursé intégralement, ${BANK_REFUND_DELAY}.`;
  return `Annulation à moins de ${FREE_CANCEL_HOURS} h de la prise en charge : `
    + `${preview.retained_pct} % sont retenus, ${formatCents(preview.refund_cents)} vous sont remboursés, `
    + `${BANK_REFUND_DELAY}.`;
}

