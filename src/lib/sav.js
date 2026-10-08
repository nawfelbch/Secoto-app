// SECOTO 084 — SAV : le client écrit, SECOTO rappelle.
import { supabase } from "../supabaseClient";
import { humanizeError } from "./humanError";

async function rpc(name, args, fallback) {
  const { data, error } = await supabase.rpc(name, args);
  if (error) throw new Error(humanizeError(error, fallback));
  return data;
}

export const SAV_MOTIFS = Object.freeze([
  { key: "retard", label: "Retard" },
  { key: "transporteur_injoignable", label: "Transporteur injoignable" },
  { key: "dommage", label: "Dommage" },
  { key: "paiement", label: "Paiement ou facture" },
  { key: "annulation", label: "Annulation" },
  { key: "autre", label: "Autre" },
]);
export const SAV_STATUTS = Object.freeze({ ouverte: "Reçue", en_cours: "En cours", resolue: "Traitée" });

/** Le client a-t-il déjà validé une course ? En cas d'incident : non (contact affiché). */
export async function clientHasCourse() {
  const { data, error } = await supabase.rpc("secoto_client_has_course");
  return error ? false : Boolean(data);
}
export const savCourses = () => rpc("secoto_sav_courses", {}, "Vos courses n’ont pas pu être chargées.");
export const savMyRequests = () => rpc("secoto_sav_my_requests", {}, "Vos demandes n’ont pas pu être chargées.");
export const savCreate = ({ orderId = null, missionId = null, motif, message, callbackPhone = null }) =>
  rpc("secoto_sav_create", { p_order_id: orderId, p_mission_id: missionId, p_motif: motif, p_message: message, p_callback_phone: callbackPhone },
    "Votre demande n’a pas pu être envoyée. Réessayez dans un instant.");
export const adminSavList = (status = null) => rpc("secoto_admin_sav_list", { p_status: status }, "Demandes SAV indisponibles.");
export const adminSavUpdate = (id, status, note = null) =>
  rpc("secoto_admin_sav_update", { p_id: id, p_status: status, p_note: note }, "Mise à jour impossible.");
