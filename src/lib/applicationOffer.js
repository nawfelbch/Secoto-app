// SECOTO — construction et validation d'une candidature transporteur.
// La migration 010 exige deux fenêtres de disponibilité complètes. Les dates
// saisies avec <input type="datetime-local"> sont converties en UTC avant
// l'appel RPC afin d'éviter tout décalage entre le navigateur et PostgreSQL.

export const EMPTY_APPLICATION_OFFER = Object.freeze({
  proposedPrice: "",
  proposedPriceGrouped: "",
  pickupEarliestAt: "",
  pickupLatestAt: "",
  deliveryEarliestAt: "",
  deliveryLatestAt: "",
  message: "",
});

function requiredDateTime(value, label) {
  if (!value) throw new Error(`Renseignez ${label}.`);
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) throw new Error(`${label} est invalide.`);
  return date;
}

function positivePrice(value, label, { optional = false } = {}) {
  if (optional && (value === "" || value === null || value === undefined)) {
    return null;
  }
  const amount = Number(value);
  if (!Number.isFinite(amount) || amount <= 0 || amount > 1_000_000) {
    throw new Error(`${label} est invalide.`);
  }
  return amount;
}

export function buildApplicationRpcPayload({
  missionId,
  idempotencyKey,
  proposedPrice,
  proposedPriceGrouped,
  pickupEarliestAt,
  pickupLatestAt,
  deliveryEarliestAt,
  deliveryLatestAt,
  message,
}) {
  const pickupEarliest = requiredDateTime(
    pickupEarliestAt,
    "la disponibilité d’enlèvement au plus tôt",
  );
  const pickupLatest = requiredDateTime(
    pickupLatestAt,
    "la disponibilité d’enlèvement au plus tard",
  );
  const deliveryEarliest = requiredDateTime(
    deliveryEarliestAt,
    "la disponibilité de livraison au plus tôt",
  );
  const deliveryLatest = requiredDateTime(
    deliveryLatestAt,
    "la disponibilité de livraison au plus tard",
  );

  if (pickupEarliest > pickupLatest) {
    throw new Error("La fin de disponibilité d’enlèvement doit suivre son début.");
  }
  if (deliveryEarliest > deliveryLatest) {
    throw new Error("La fin de disponibilité de livraison doit suivre son début.");
  }

  const trimmedMessage = String(message || "").trim();
  if (trimmedMessage.length > 2_000) {
    throw new Error("Le message de candidature est trop long.");
  }

  return {
    p_mission_id: missionId,
    p_proposed_price: positivePrice(proposedPrice, "Le tarif proposé"),
    p_message: trimmedMessage || null,
    p_idempotency_key: idempotencyKey,
    p_pickup_earliest_at: pickupEarliest.toISOString(),
    p_pickup_latest_at: pickupLatest.toISOString(),
    p_delivery_earliest_at: deliveryEarliest.toISOString(),
    p_delivery_latest_at: deliveryLatest.toISOString(),
    p_proposed_price_grouped: positivePrice(
      proposedPriceGrouped,
      "Le tarif si groupé",
      { optional: true },
    ),
  };
}
