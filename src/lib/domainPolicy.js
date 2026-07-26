export const PUBLIC_SIGNUP_ROLES = Object.freeze(["client", "transporter"]);
export const CLIENT_TYPES = Object.freeze(["particulier", "pro"]);
export const TRANSPORTER_TYPE_VALUES = Object.freeze(["convoyeur", "vl", "pl"]);
export const PAYMENT_METHODS = Object.freeze(["virement", "especes"]);

export const MISSION_STATUS_TRANSITIONS = Object.freeze({
  published: Object.freeze(["assigned", "cancelled"]),
  assigned: Object.freeze(["completed", "cancelled"]),
  completed: Object.freeze([]),
  cancelled: Object.freeze([]),
});

export const REQUEST_STATUS_TRANSITIONS = Object.freeze({
  pending: Object.freeze(["approved", "rejected"]),
  approved: Object.freeze([]),
  rejected: Object.freeze([]),
});

export const APPLICATION_STATUS_TRANSITIONS = Object.freeze({
  pending: Object.freeze(["accepted", "rejected"]),
  accepted: Object.freeze([]),
  rejected: Object.freeze([]),
});

export const TRACKING_EVENT_TO_PROGRESS = Object.freeze({
  pickup_inspection: "pickup_completed",
  road_incident: "incident_reported",
  delivery_inspection: "delivery_completed",
});

export function isPublicSignupRole(role) {
  return PUBLIC_SIGNUP_ROLES.includes(role);
}

export function normalizePublicSignupMetadata(input = {}) {
  const role = isPublicSignupRole(input.role) ? input.role : "client";
  const clientType =
    role === "client" && CLIENT_TYPES.includes(input.client_type)
      ? input.client_type
      : role === "client"
        ? "particulier"
        : null;
  const transporterType =
    role === "transporter" && TRANSPORTER_TYPE_VALUES.includes(input.transporter_type)
      ? input.transporter_type
      : null;

  return {
    full_name: typeof input.full_name === "string" ? input.full_name.trim() : "",
    company_name: typeof input.company_name === "string" ? input.company_name.trim() : "",
    phone: typeof input.phone === "string" ? input.phone.trim() : "",
    city: typeof input.city === "string" ? input.city.trim() : "",
    role,
    client_type: clientType,
    transporter_type: transporterType,
  };
}

export function canTransition(transitionMap, from, to) {
  return Boolean(transitionMap[from]?.includes(to));
}

export function progressFromTrackingEvent(eventType) {
  return TRACKING_EVENT_TO_PROGRESS[eventType] || null;
}
