export const VEHICLE_CATEGORIES = Object.freeze([
  {
    value: "standard",
    label: "Véhicule standard",
    hint: "Transport ou convoyage habituel.",
  },
  {
    value: "luxury",
    label: "Prestige / collection / grande valeur",
    hint: "Protection et sélection renforcées.",
  },
]);

export const LUXURY_CAPACITY_STATUSES = Object.freeze([
  "not_requested",
  "pending",
  "approved",
  "rejected",
  "suspended",
]);

export function normalizeVehicleCategory(value) {
  return value === "luxury" ? "luxury" : "standard";
}

export function missionRoutingKey(mission = {}) {
  const type = mission.type === "plateau" ? "plateau" : "convoyage";
  const category = normalizeVehicleCategory(
    mission.vehicleCategory ?? mission.vehicle_category,
  );

  if (type === "convoyage") return "convoyage";
  return category === "luxury" ? "closed_luxury" : "standard_plateau";
}

export function transporterMatchesMission(account = {}, mission = {}) {
  if (
    account.role !== "transporter"
    || account.status !== "active"
    || !account.isVerified
  ) {
    return false;
  }

  const key = missionRoutingKey(mission);
  const transporterType =
    account.transporterType ?? account.transporter_type ?? null;

  if (key === "convoyage") {
    return transporterType === "convoyeur";
  }

  if (!["vl", "pl"].includes(transporterType)) {
    return false;
  }

  if (key === "standard_plateau") {
    return account.receivesStandardPlateau
      ?? account.receives_standard_plateau
      ?? true;
  }

  return (
    account.luxuryClosedTransportStatus
    ?? account.luxury_closed_transport_status
  ) === "approved";
}

export function labelVehicleCategory(value) {
  return normalizeVehicleCategory(value) === "luxury"
    ? "Véhicule de prestige / collection"
    : "Véhicule standard";
}

export function labelLuxuryCapacityStatus(value) {
  const labels = {
    not_requested: "Non demandée",
    pending: "En attente de validation",
    approved: "Camion fermé validé",
    rejected: "Demande refusée",
    suspended: "Capacité suspendue",
  };
  return labels[value] || labels.not_requested;
}