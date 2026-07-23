// SECOTO — mappers Supabase <-> app + libellés FR.

export const emptyMissionForm = {
  type: "convoyage",
  fromCity: "",
  toCity: "",
  pickupAddress: "",
  deliveryAddress: "",
  missionDate: "",
  vehicle: "",
  plate: "",
  distanceKm: "",
  carrierCost: "",
  clientName: "",
  clientContact: "",
  clientPhone: "",
  priceMode: "fixed",
  proposedPrice: "",
  paymentMethod: "virement",
  notes: "",
};

export const TRANSPORTER_TYPES = [
  { value: "convoyeur", label: "Convoyeur", hint: "Conduit le véhicule par la route" },
  { value: "vl", label: "Transporteur VL", hint: "Véhicules légers sur plateau / remorque" },
  { value: "pl", label: "Transporteur PL", hint: "Poids lourds & gros porteurs" },
];

export function generatePublicRef(prefix = "SECOTO") {
  return `${prefix}-${new Date().getFullYear()}-${Math.floor(1000 + Math.random() * 9000)}`;
}

export function accountFromDb(row) {
  return {
    id: row.id,
    role: row.role,
    fullName: row.full_name,
    companyName: row.company_name,
    email: row.email,
    phone: row.phone,
    city: row.city,
    status: row.status,
    docsCount: row.docs_count,
    isVerified: row.is_verified,
    transporterType: row.transporter_type || null,
    clientType: row.client_type || null,
  };
}

export function missionFromDb(row) {
  return {
    id: row.id,
    publicRef: row.public_ref,
    type: row.type,
    status: row.status,
    progressStatus: row.progress_status,
    fromCity: row.from_city,
    toCity: row.to_city,
    pickupAddress: row.pickup_address,
    deliveryAddress: row.delivery_address,
    missionDate: row.mission_date,
    vehicle: row.vehicle,
    plate: row.plate,
    distanceKm: row.distance_km,
    carrierCost: row.carrier_cost,
    // Montants calcules par la base (colonnes generees). Peuvent etre absents
    // selon les droits de lecture (cloisonnement RLS/colonnaire).
    clientPrice: row.client_price,
    carrierPay: row.carrier_pay,
    margin: row.margin,
    clientName: row.client_name,
    clientContact: row.client_contact,
    clientPhone: row.client_phone,
    priceMode: row.price_mode,
    proposedPrice: row.proposed_price,
    paymentMethod: row.payment_method || "virement",
    notes: row.notes,
    createdByRole: row.created_by_role,
    clientAccountId: row.client_account_id || null,
    assignedTransporterId: row.assigned_transporter_id,
    assignedTransporterName: row.assigned_transporter_name,
    sourceRequestId: row.source_request_id,
    createdAt: row.created_at,
  };
}

export function publicMissionFromDb(row) {
  return {
    id: row.id,
    publicRef: row.public_ref,
    type: row.type,
    status: row.status,
    progressStatus: row.progress_status,
    fromCity: row.from_city,
    toCity: row.to_city,
    pickupAddress: row.pickup_address,
    deliveryAddress: row.delivery_address,
    vehicle: row.vehicle,
    distanceKm: row.distance_km,
    createdAt: row.created_at,
  };
}

export function applicationFromDb(row) {
  return {
    id: row.id,
    missionId: row.mission_id,
    transporterId: row.transporter_id,
    transporterName: row.transporter_name,
    transporterCompany: row.transporter_company,
    transporterStatus: row.transporter_status,
    message: row.message,
    proposedPrice: row.proposed_price,
    priceNote: row.price_note,
    status: row.status,
    createdAt: row.created_at,
  };
}

export function documentFromDb(row) {
  return {
    id: row.id,
    missionId: row.mission_id,
    accountId: row.account_id,
    type: row.type,
    fileName: row.file_name,
    filePath: row.file_path,
    fileUrl: row.file_url,
    status: row.status,
    createdAt: row.created_at,
  };
}

export function trackingEventFromDb(row) {
  return {
    id: row.id,
    missionId: row.mission_id,
    transporterId: row.transporter_id,
    eventType: row.event_type,
    title: row.title,
    comment: row.comment,
    odometerKm: row.odometer_km,
    fuelLevel: row.fuel_level,
    issueType: row.issue_type,
    issueSeverity: row.issue_severity,
    createdAt: row.created_at,
  };
}

export function trackingPhotoFromDb(row) {
  return {
    id: row.id,
    trackingEventId: row.tracking_event_id,
    missionId: row.mission_id,
    transporterId: row.transporter_id,
    photoType: row.photo_type,
    fileName: row.file_name,
    filePath: row.file_path,
    fileUrl: row.file_url,
    createdAt: row.created_at,
  };
}

export function requestFromDb(row) {
  return {
    id: row.id,
    publicRef: row.public_ref,
    status: row.status,
    requesterId: row.requester_id,
    requesterName: row.requester_name,
    requesterCompany: row.requester_company,
    type: row.type,
    fromCity: row.from_city,
    toCity: row.to_city,
    pickupAddress: row.pickup_address,
    deliveryAddress: row.delivery_address,
    missionDate: row.mission_date,
    vehicle: row.vehicle,
    plate: row.plate,
    distanceKm: row.distance_km,
    clientName: row.client_name,
    clientContact: row.client_contact,
    clientPhone: row.client_phone,
    priceMode: row.price_mode,
    proposedPrice: row.proposed_price,
    notes: row.notes,
    createdByRole: row.created_by_role,
    approvedMissionId: row.approved_mission_id,
    createdAt: row.created_at,
  };
}

export function notificationFromDb(row) {
  return {
    id: row.id,
    accountId: row.account_id,
    type: row.type,
    title: row.title,
    body: row.body,
    missionId: row.mission_id,
    audience: row.audience,
    isRead: row.is_read,
    createdAt: row.created_at,
  };
}

export function missionToDb(form, extra = {}) {
  return {
    public_ref: extra.publicRef || generatePublicRef("MIS"),
    type: form.type || "convoyage",
    status: extra.status || "published",
    from_city: form.fromCity || null,
    to_city: form.toCity || null,
    pickup_address: form.pickupAddress || null,
    delivery_address: form.deliveryAddress || null,
    mission_date: form.missionDate || null,
    vehicle: form.vehicle || null,
    plate: form.plate || null,
    distance_km: form.distanceKm ? Number(form.distanceKm) : null,
    carrier_cost: form.carrierCost ? Number(form.carrierCost) : null,
    client_name: form.clientName || null,
    client_contact: form.clientContact || null,
    client_phone: form.clientPhone || null,
    price_mode: form.priceMode || "fixed",
    proposed_price: form.proposedPrice ? Number(form.proposedPrice) : null,
    payment_method: form.paymentMethod || "virement",
    notes: form.notes || null,
    created_by_role: extra.createdByRole || "admin",
    client_account_id: extra.clientAccountId || null,
    assigned_transporter_id: extra.assignedTransporterId || null,
    assigned_transporter_name: extra.assignedTransporterName || null,
    source_request_id: extra.sourceRequestId || null,
  };
}

// IMPORTANT : mission_requests n'a PAS les colonnes de missions
// (assigned_transporter_id, carrier_cost, payment_method, client_account_id,
// source_request_id...). On liste donc EXPLICITEMENT les colonnes valides pour
// eviter l'erreur "Could not find the '...' column of 'mission_requests'".
export function requestToDb(form, account = null, extra = {}) {
  return {
    public_ref: extra.publicRef || generatePublicRef("REQ"),
    type: form.type || "convoyage",
    status: "pending",
    from_city: form.fromCity || null,
    to_city: form.toCity || null,
    pickup_address: form.pickupAddress || null,
    delivery_address: form.deliveryAddress || null,
    mission_date: form.missionDate || null,
    vehicle: form.vehicle || null,
    plate: form.plate || null,
    distance_km: form.distanceKm ? Number(form.distanceKm) : null,
    client_name: form.clientName || null,
    client_contact: form.clientContact || null,
    client_phone: form.clientPhone || null,
    price_mode: form.priceMode || "fixed",
    proposed_price: form.proposedPrice ? Number(form.proposedPrice) : null,
    notes: form.notes || null,
    created_by_role: extra.createdByRole || (account ? account.role || "transporter" : "guest"),
    requester_id: account ? account.id : null,
    requester_name: (account && account.fullName) || form.clientName || null,
    requester_company: (account && account.companyName) || null,
    approved_mission_id: null,
  };
}

// ---------- Libellés ----------

export function labelTransporterType(type) {
  const found = TRANSPORTER_TYPES.find((t) => t.value === type);
  return found ? found.label : "Transporteur";
}

export function labelTrackingEventType(type) {
  if (type === "pickup_inspection") return "État des lieux départ";
  if (type === "road_incident") return "Incident / problème";
  if (type === "delivery_inspection") return "État des lieux arrivée";
  return type || "Suivi mission";
}

export function labelFuelLevel(level) {
  const labels = {
    reserve: "Réserve",
    "1/4": "1/4",
    "1/2": "1/2",
    "3/4": "3/4",
    full: "Plein",
    unknown: "Non renseigné",
  };
  return labels[level] || "Non renseigné";
}

export function labelStatus(status) {
  const labels = {
    published: "Publiée",
    pending: "En attente",
    assigned: "Attribuée",
    completed: "Terminée",
    accepted: "Acceptée",
    approved: "Validée",
    rejected: "Refusée",
    cancelled: "Annulée",
    active: "Actif",
    verified: "Vérifié",
    suspended: "Suspendu",
    uploaded: "Envoyé",
    validated: "Validé",
  };
  return labels[status] || status || "Statut";
}

export function labelMissionType(type) {
  return type === "plateau" ? "Transport par plateau" : "Convoyage";
}

export function labelProgress(progressStatus) {
  const labels = {
    assigned_pending: "En attente de prise en charge",
    pickup_completed: "Véhicule pris en charge",
    incident_reported: "Incident signalé",
    delivery_completed: "Livré",
    completed: "Livré",
  };
  return labels[progressStatus] || "En attente de prise en charge";
}

export function formatDateTime(value) {
  if (!value) return "Non renseignée";
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return value;
  return date.toLocaleString("fr-FR", {
    day: "2-digit",
    month: "2-digit",
    year: "numeric",
    hour: "2-digit",
    minute: "2-digit",
  });
}
