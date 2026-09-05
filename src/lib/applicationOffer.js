// ============================================================================
// SECOTO — construction et validation d'une candidature transporteur.
// ----------------------------------------------------------------------------
// LEÇON DE L'INCIDENT DU 05/09/2026
// La charge utile envoyée à `secoto_apply_to_mission` doit TOUJOURS contenir
// les neuf clés attendues, même quand la valeur est `null`. PostgREST résout
// la fonction par les NOMS d'arguments reçus : une charge partielle change la
// signature demandée et produit un « Could not find the function … in schema
// cache » que le transporteur ne peut ni comprendre ni contourner.
//
// Les disponibilités sont désormais FACULTATIVES (la migration 024 les accepte
// nulles) : sur le terrain, un transporteur qui voit passer une mission veut
// pouvoir se positionner en dix secondes avec son tarif. S'il précise ses
// créneaux, il doit les donner en entier — quatre dates cohérentes.
// ============================================================================

export const EMPTY_APPLICATION_OFFER = Object.freeze({
  proposedPrice: "",
  proposedPriceGrouped: "",
  pickupEarliestAt: "",
  pickupLatestAt: "",
  deliveryEarliestAt: "",
  deliveryLatestAt: "",
  message: "",
});

const AVAILABILITY_FIELDS = [
  "pickupEarliestAt",
  "pickupLatestAt",
  "deliveryEarliestAt",
  "deliveryLatestAt",
];

/** Format attendu par <input type="datetime-local"> : YYYY-MM-DDTHH:mm (heure locale). */
export function toDateTimeLocal(date) {
  const value = date instanceof Date ? date : new Date(date);
  if (Number.isNaN(value.getTime())) return "";
  const pad = (n) => String(n).padStart(2, "0");
  return `${value.getFullYear()}-${pad(value.getMonth() + 1)}-${pad(value.getDate())}`
    + `T${pad(value.getHours())}:${pad(value.getMinutes())}`;
}

function shift(hours, { at = null, from = Date.now() } = {}) {
  const date = new Date(from + hours * 3600 * 1000);
  if (at !== null) date.setHours(at, 0, 0, 0);
  return date;
}

/**
 * Créneaux prêts à l'emploi. Un transporteur en station-service ne remplit pas
 * quatre sélecteurs de date : il appuie sur « Dès demain » et il candidate.
 */
export const AVAILABILITY_PRESETS = Object.freeze([
  {
    key: "asap",
    label: "Dès que possible",
    hint: "Enlèvement sous 24 h, livraison sous 3 jours",
    build: () => ({
      pickupEarliestAt: toDateTimeLocal(shift(1)),
      pickupLatestAt: toDateTimeLocal(shift(24)),
      deliveryEarliestAt: toDateTimeLocal(shift(2)),
      deliveryLatestAt: toDateTimeLocal(shift(72)),
    }),
  },
  {
    key: "tomorrow",
    label: "Demain",
    hint: "Enlèvement demain 8 h – 18 h, livraison sous 48 h",
    build: () => ({
      pickupEarliestAt: toDateTimeLocal(shift(24, { at: 8 })),
      pickupLatestAt: toDateTimeLocal(shift(24, { at: 18 })),
      deliveryEarliestAt: toDateTimeLocal(shift(24, { at: 10 })),
      deliveryLatestAt: toDateTimeLocal(shift(72, { at: 18 })),
    }),
  },
  {
    key: "week",
    label: "Cette semaine",
    hint: "Enlèvement sous 5 jours, livraison sous 8 jours",
    build: () => ({
      pickupEarliestAt: toDateTimeLocal(shift(24, { at: 8 })),
      pickupLatestAt: toDateTimeLocal(shift(120, { at: 18 })),
      deliveryEarliestAt: toDateTimeLocal(shift(48, { at: 8 })),
      deliveryLatestAt: toDateTimeLocal(shift(192, { at: 18 })),
    }),
  },
]);

export function applyAvailabilityPreset(key) {
  const preset = AVAILABILITY_PRESETS.find((item) => item.key === key);
  return preset ? preset.build() : null;
}

export function clearAvailability() {
  return {
    pickupEarliestAt: "",
    pickupLatestAt: "",
    deliveryEarliestAt: "",
    deliveryLatestAt: "",
  };
}

/** Nombre de créneaux renseignés — sert à l'affichage comme à la validation. */
export function countAvailability(offer) {
  return AVAILABILITY_FIELDS.filter((field) => String(offer?.[field] || "").trim()).length;
}

function parseDateTime(value, label) {
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) throw new Error(`${label} est invalide.`);
  return date;
}

function positivePrice(value, label, { optional = false } = {}) {
  const raw = typeof value === "string" ? value.replace(",", ".").trim() : value;
  if (optional && (raw === "" || raw === null || raw === undefined)) return null;
  if (raw === "" || raw === null || raw === undefined) {
    throw new Error(`Indiquez ${label.toLowerCase()}.`);
  }
  const amount = Number(raw);
  if (!Number.isFinite(amount) || amount <= 0) {
    throw new Error(`${label} doit être un montant supérieur à 0.`);
  }
  if (amount > 1_000_000) throw new Error(`${label} dépasse la limite autorisée.`);
  return Math.round(amount * 100) / 100;
}

/**
 * Construit la charge utile RPC. Lève une erreur en français, jamais technique.
 * Les neuf clés sont TOUJOURS présentes (cf. entête).
 */
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
  if (!missionId) throw new Error("Mission introuvable : actualisez la liste.");

  const price = positivePrice(proposedPrice, "Votre tarif");
  const grouped = positivePrice(proposedPriceGrouped, "Votre tarif si groupé", { optional: true });

  const raw = { pickupEarliestAt, pickupLatestAt, deliveryEarliestAt, deliveryLatestAt };
  const filled = AVAILABILITY_FIELDS.filter((field) => String(raw[field] || "").trim());

  let windows = null;
  if (filled.length > 0 && filled.length < AVAILABILITY_FIELDS.length) {
    throw new Error(
      "Complétez vos quatre créneaux de disponibilité, ou laissez-les vides si vous vous adaptez.",
    );
  }
  if (filled.length === AVAILABILITY_FIELDS.length) {
    const pickupEarliest = parseDateTime(pickupEarliestAt, "La disponibilité d’enlèvement au plus tôt");
    const pickupLatest = parseDateTime(pickupLatestAt, "La disponibilité d’enlèvement au plus tard");
    const deliveryEarliest = parseDateTime(deliveryEarliestAt, "La disponibilité de livraison au plus tôt");
    const deliveryLatest = parseDateTime(deliveryLatestAt, "La disponibilité de livraison au plus tard");

    if (pickupEarliest > pickupLatest) {
      throw new Error("La fin de votre disponibilité d’enlèvement doit suivre son début.");
    }
    if (deliveryEarliest > deliveryLatest) {
      throw new Error("La fin de votre disponibilité de livraison doit suivre son début.");
    }
    if (deliveryLatest < pickupEarliest) {
      throw new Error("La livraison ne peut pas être proposée avant l’enlèvement.");
    }
    windows = {
      pickupEarliest: pickupEarliest.toISOString(),
      pickupLatest: pickupLatest.toISOString(),
      deliveryEarliest: deliveryEarliest.toISOString(),
      deliveryLatest: deliveryLatest.toISOString(),
    };
  }

  const trimmedMessage = String(message || "").trim();
  if (trimmedMessage.length > 2_000) {
    throw new Error("Votre message est trop long (2000 caractères maximum).");
  }

  return {
    p_mission_id: missionId,
    p_proposed_price: price,
    p_message: trimmedMessage || null,
    p_idempotency_key: idempotencyKey,
    p_pickup_earliest_at: windows?.pickupEarliest ?? null,
    p_pickup_latest_at: windows?.pickupLatest ?? null,
    p_delivery_earliest_at: windows?.deliveryEarliest ?? null,
    p_delivery_latest_at: windows?.deliveryLatest ?? null,
    p_proposed_price_grouped: grouped,
  };
}
