// ============================================================================
// SECOTO — Transport à la demande, offres partenaires, abonnement, suivi.
// ----------------------------------------------------------------------------
// Toutes les décisions (prix, rémunération, marge, attribution, quotas) sont
// prises côté serveur. Ce module ne fait qu'appeler les RPC et formater.
// ============================================================================
import { supabase } from "../supabaseClient";
import { getServerFunctionUrl } from "../platform/runtime";
import { humanizeError } from "./humanError";
import { randomIdempotencyKey } from "./fileSafety";

export const VEHICLE_CLASSES = [
  { value: "voiture", label: "Voiture" },
  { value: "utilitaire", label: "Utilitaire" },
  { value: "moto", label: "Moto" },
  { value: "autre", label: "Autre" },
];

export const VEHICLE_CONSTRAINTS = [
  { value: "sans_cle", label: "Clé indisponible" },
  { value: "garde_au_sol_basse", label: "Garde au sol basse" },
  { value: "gabarit_hors_norme", label: "Gabarit hors norme" },
  { value: "non_immatricule", label: "Non immatriculé" },
  { value: "acces_difficile", label: "Accès difficile au lieu de prise en charge" },
  { value: "batterie_faible", label: "Batterie faible" },
];

export const SLOTS = [
  { value: "matin", label: "Matin (8 h – 12 h)" },
  { value: "apres_midi", label: "Après-midi (13 h – 18 h)" },
  { value: "journee", label: "Journée entière" },
];

export const MANUAL_REASONS = {
  prix_automatique_desactive: "Le prix de ce trajet est établi par SECOTO.",
  aucun_bareme_actif: "Ce mode de transport fait l’objet d’un devis personnalisé.",
  itineraire_indisponible: "L’itinéraire n’a pas pu être calculé automatiquement.",
  distance_indisponible: "L’itinéraire n’a pas pu être calculé automatiquement.",
  categorie_vehicule_hors_bareme: "Cette catégorie de véhicule demande une étude personnalisée.",
  distance_hors_bareme_automatique: "Sur cette distance, SECOTO établit un devis personnalisé.",
  vehicule_prestige: "Les véhicules de prestige font l’objet d’un devis personnalisé.",
  contraintes_particulieres: "Les contraintes signalées demandent une étude personnalisée.",
  vehicule_non_roulant: "Un véhicule non roulant demande une étude personnalisée.",
  supplement_non_roulant_non_defini: "Ce trajet fait l’objet d’un devis personnalisé.",
  convoyage_impossible_vehicule_non_roulant: "Un véhicule non roulant ne peut pas être convoyé.",
  delai_trop_court: "Le délai demandé est trop court pour un prix automatique.",
  remuneration_partenaire_non_definie: "Ce trajet fait l’objet d’un devis personnalisé.",
  marge_insuffisante: "Ce trajet fait l’objet d’un devis personnalisé.",
};

export * from "./orderCopy";
import { OFFER_WINDOW_HOURS, ORDER_STATUS_LABEL } from "./orderCopy";

// Étape suivante lisible par le client, sans jamais annoncer ce qui n'est pas acquis.
export function orderHeadline(order) {
  if (!order) return "";
  if (order.status === "awaiting_payment") return order.funding === "subscription" ? "Réservation du forfait en cours" : "Validez votre moyen de paiement pour diffuser la demande";
  if (order.status === "searching_partner" || order.status === "partner_locked") {
    return order.payment_status === "capture_failed"
      ? "L’encaissement a échoué : mettez à jour votre moyen de paiement"
      : `Votre demande est proposée à tous nos transporteurs compatibles (${OFFER_WINDOW_HOURS} h)`;
  }
  return ORDER_STATUS_LABEL[order.status] || order.status;
}

export function freshnessLabel(view) {
  if (!view || view.sharing !== "active") return null;
  const age = Number(view.age_seconds);
  if (view.freshness === "live") return "Position à jour";
  if (view.freshness === "recent") return `Dernière position il y a ${Math.max(1, Math.round(age / 60))} min`;
  if (view.freshness === "stale") {
    const minutes = Math.round(age / 60);
    return minutes >= 60 ? `Position ancienne (il y a ${Math.floor(minutes / 60)} h ${String(minutes % 60).padStart(2, "0")})` : `Position ancienne (il y a ${minutes} min) — connexion du transporteur interrompue`;
  }
  return "En attente de la première position";
}

export function departmentsFromText(text) {
  return Array.from(new Set(String(text || "")
    .toUpperCase()
    .split(/[\s,;]+/)
    .map((z) => z.trim())
    .filter((z) => /^([0-9]{2}|2A|2B|97[1-6])$/.test(z))));
}

function explain(error, fallback) {
  return new Error(humanizeError(error, fallback));
}

async function rpc(name, args, fallback = "Action impossible pour le moment.") {
  const { data, error } = await supabase.rpc(name, args);
  if (error) throw explain(error, fallback);
  return data;
}

async function callFunction(name, body) {
  const { data: sessionData } = await supabase.auth.getSession();
  const token = sessionData?.session?.access_token;
  if (!token) throw new Error("Session expirée. Reconnectez-vous puis réessayez.");
  const res = await fetch(getServerFunctionUrl(name), {
    method: "POST",
    headers: { "Content-Type": "application/json", Authorization: `Bearer ${token}` },
    body: JSON.stringify(body),
  });
  const payload = await res.json().catch(() => ({}));
  if (!res.ok) {
    // Motif technique renvoye par le serveur (Stripe, configuration) : invisible
    // pour l'utilisateur, mais lisible dans la console pour le diagnostic.
    if (payload.detail) console.error("[SECOTO] %s: %s", name, payload.detail);
    const message = payload.message ? humanizeError({ message: payload.message }, payload.message) : null;
    throw new Error(message || (res.status === 503 ? "Service momentanément indisponible." : "La demande n’a pas abouti."));
  }
  return payload;
}

export const featureFlags = () => rpc("secoto_feature_flags", {});

// ---- Client ----------------------------------------------------------------
export const requestQuote = (payload) => callFunction("quote-transport", { payload });
export const myQuotes = () => rpc("secoto_my_quotes", {});
export const myOrders = () => rpc("secoto_od_my_orders", {});
export const bookQuote = (quoteId, useSubscription = false) =>
  rpc("secoto_od_book_quote", { p_quote_id: quoteId, p_use_subscription: useSubscription, p_idempotency_key: randomIdempotencyKey() });
export const cancelOrder = (orderId) => rpc("secoto_od_cancel_order", { p_order_id: orderId, p_idempotency_key: randomIdempotencyKey() });
export const cancelPreview = (orderId) => rpc("secoto_od_cancel_quote_preview", { p_order_id: orderId });

// ---- Partenaire ------------------------------------------------------------
export const myDispatchPreferences = () => rpc("secoto_my_dispatch_preferences", {});
export const updateDispatchPreferences = (payload) => rpc("secoto_update_dispatch_preferences", { p_payload: payload });
export const myOffers = () => rpc("secoto_my_offers", {});
export const getOffer = (offerId) => rpc("secoto_offer_get", { p_offer_id: offerId });
export const markOfferSeen = (offerId) => rpc("secoto_offer_mark_seen", { p_offer_id: offerId }).catch(() => null);
export const declineOffer = (offerId) => rpc("secoto_offer_decline", { p_offer_id: offerId });
export const acceptOffer = (offerId, idempotencyKey) => callFunction("offer-accept", { offerId, idempotencyKey });
// Missions publiées hors commande : la rémunération est affichée, on accepte ou on refuse.
export const acceptMission = (missionId) =>
  rpc("secoto_mission_accept", { p_mission_id: missionId, p_idempotency_key: randomIdempotencyKey() });
export const declineMission = (missionId) => rpc("secoto_mission_decline", { p_mission_id: missionId });
// Compte de versement Stripe Connect : "status", "link" ou "dashboard".
export const connectOnboarding = (action) => callFunction("connect-onboarding", { action });

// ---- Suivi -----------------------------------------------------------------
export const liveView = (missionId) => rpc("secoto_live_view", { p_mission_id: missionId });
export const liveStart = (missionId) => rpc("secoto_live_start", { p_mission_id: missionId, p_consent: true });
export const liveStop = (missionId) => rpc("secoto_live_stop", { p_mission_id: missionId });
export const livePush = (missionId, points) => rpc("secoto_live_push_positions", { p_mission_id: missionId, p_points: points });

// ---- Abonnement --------------------------------------------------------------
export const subscriptionOverview = () => rpc("secoto_sub_my_overview", {});
export const startEligibility = (name, siren) => rpc("secoto_eligibility_start", { p_company_name: name, p_siren: siren || null });
export const saveQuestionnaire = (applicationId, answers) => rpc("secoto_eligibility_save_questionnaire", { p_application_id: applicationId, p_answers: answers });
export const replaceHistoryRows = (applicationId, rows) => rpc("secoto_eligibility_replace_rows", { p_application_id: applicationId, p_rows: rows });
export const historyRows = (applicationId) => rpc("secoto_eligibility_rows", { p_application_id: applicationId });
export const registerEligibilityFile = (args) => rpc("secoto_eligibility_register_file", args);
export const submitEligibility = (applicationId) => rpc("secoto_eligibility_submit", { p_application_id: applicationId });
export const acceptProposal = (id) => rpc("secoto_sub_accept_proposal", { p_proposal_id: id });
export const declineProposal = (id) => rpc("secoto_sub_decline_proposal", { p_proposal_id: id });
export const startSubscriptionCheckout = (subscriptionId) => callFunction("subscription-checkout", { subscriptionId, action: "checkout" });
export const requestExtension = (subscriptionId, category, quantity, extraKm, note) =>
  rpc("secoto_sub_request_extension", { p_subscription_id: subscriptionId, p_category: category, p_quantity: quantity, p_extra_km: extraKm, p_note: note });
export const acceptExtension = (id) => rpc("secoto_sub_accept_extension", { p_extension_id: id });

export async function uploadEligibilityFile({ businessId, applicationId, file, kind }) {
  const safeName = String(file.name || "fichier").replace(/[^a-zA-Z0-9._-]/g, "_").slice(-80);
  const path = `${businessId}/${applicationId}/${Date.now()}-${safeName}`;
  const { error } = await supabase.storage.from("business-private").upload(path, file, { contentType: file.type || undefined, upsert: false });
  if (error) throw explain(error, "Envoi du fichier impossible.");
  return registerEligibilityFile({ p_application_id: applicationId, p_kind: kind, p_path: path, p_file_name: file.name, p_mime: file.type || null, p_size: file.size });
}

// ---- Administration ----------------------------------------------------------
export const admin = {
  setFlag: (key, enabled) => rpc("secoto_admin_set_feature_flag", { p_key: key, p_enabled: enabled }),
  orders: (status = null) => rpc("secoto_admin_od_orders", { p_status: status }),
  quotes: (status = null) => rpc("secoto_admin_quotes", { p_status: status }),
  priceQuote: (id, clientCents, partnerCents, hours, note, override) =>
    rpc("secoto_admin_price_quote", { p_quote_id: id, p_client_price_cents: clientCents, p_partner_pay_cents: partnerCents, p_validity_hours: hours, p_note: note, p_override_margin: override }),
  // Lien de paiement du devis : le client paie sans compte, et le paiement
  // vaut reservation.
  quotePaymentLink: (quoteId, days = 30) =>
    rpc("secoto_admin_devis_link_quote", { p_quote: quoteId, p_validity_days: days }),
  rebroadcast: (id) => rpc("secoto_admin_od_rebroadcast", { p_order_id: id }),
  setPartnerPay: (id, cents, override, note) => rpc("secoto_admin_od_set_partner_pay", { p_order_id: id, p_partner_pay_cents: cents, p_override: override, p_note: note }),
  lockForPartner: (orderId, partnerId) => callFunction("offer-accept", { adminOrderId: orderId, partnerId }),
  replacePartner: (id, reason) => rpc("secoto_admin_od_replace_partner", { p_order_id: id, p_reason: reason }),
  cancelOrder: (id, reason, refund) => rpc("secoto_admin_od_cancel_order", { p_order_id: id, p_reason: reason, p_refund: refund }),
  updateConditions: (id, payload, note) => rpc("secoto_admin_od_update_conditions", { p_order_id: id, p_payload: payload, p_note: note }),
  grids: () => rpc("secoto_admin_pricing_grids", {}),
  createGrid: (mode, params, note) => rpc("secoto_admin_create_grid_version", { p_mode: mode, p_params: params, p_source_note: note }),
  activateGrid: (id) => rpc("secoto_admin_activate_grid", { p_grid_id: id }),
  simulate: (id, km, vehicle, hours) => rpc("secoto_admin_simulate_price", { p_grid_id: id, p_distance_km: km, p_vehicle: vehicle, p_hours_to_pickup: hours }),
  compliance: () => rpc("secoto_admin_partner_compliance", {}),
  setDocumentValidity: (id, date) => rpc("secoto_admin_set_document_validity", { p_document_id: id, p_valid_until: date }),
  payouts: (status = "to_pay") => rpc("secoto_admin_partner_payouts", { p_status: status }),
  markPayout: (id, reference) => rpc("secoto_admin_mark_payout_paid", { p_payout_id: id, p_reference: reference }),
  audit: (entity = null, entityId = null) => rpc("secoto_admin_audit_log", { p_entity: entity, p_entity_id: entityId, p_limit: 200 }),
  accountingExport: (from, to) => rpc("secoto_admin_accounting_export", { p_from: from, p_to: to }),
  eligibilityList: () => rpc("secoto_admin_eligibility_list", {}),
  eligibilitySummary: (id) => rpc("secoto_admin_eligibility_summary", { p_application_id: id }),
  setApplicationStatus: (id, status, note) => rpc("secoto_admin_set_application_status", { p_application_id: id, p_status: status, p_note: note }),
  saveProposal: (payload) => rpc("secoto_admin_save_proposal", { p_payload: payload }),
  sendProposal: (id) => rpc("secoto_admin_send_proposal", { p_proposal_id: id }),
  subscriptions: () => rpc("secoto_admin_subscriptions", {}),
  priceExtension: (id, cents, hours) => rpc("secoto_admin_price_extension", { p_extension_id: id, p_price_cents: cents, p_valid_hours: hours }),
};

// Export CSV sûr : neutralise les cellules qui seraient interprétées comme
// des formules par un tableur (=, +, -, @).
export function toCsv(rows) {
  if (!rows?.length) return "";
  const headers = Object.keys(rows[0]);
  const cell = (value) => {
    let text = value === null || value === undefined ? "" : String(value);
    if (/^[=+\-@\t\r]/.test(text) && !/^-?\d+([.,]\d+)?$/.test(text)) text = `'${text}`;
    return /[";\n\r]/.test(text) ? `"${text.replace(/"/g, '""')}"` : text;
  };
  return `\uFEFF${[headers.join(";"), ...rows.map((r) => headers.map((h) => cell(r[h])).join(";"))].join("\r\n")}`;
}
