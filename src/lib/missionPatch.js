// SECOTO 101 — modification d'une mission par SECOTO : ce qui part en base.
import { toDateTimeLocal } from "./applicationOffer.js";

// Champs modifiables par SECOTO, dans l'ordre de l'écran.
export const CHAMPS = [
  ["fromCity", "from_city", "Ville de départ"],
  ["toCity", "to_city", "Ville d’arrivée"],
  ["pickupAddress", "pickup_address", "Adresse de départ"],
  ["deliveryAddress", "delivery_address", "Adresse d’arrivée"],
  ["missionDate", "mission_date", "Date / heure", "datetime-local"],
  ["vehicle", "vehicle", "Véhicule"],
  ["plate", "plate", "Immatriculation"],
  ["distanceKm", "distance_km", "Distance km", "number"],
  ["clientName", "client_name", "Nom client"],
  ["clientContact", "client_contact", "Contact client (e-mail)"],
  ["clientPhone", "client_phone", "Téléphone client", "tel"],
];

export function valeurInitiale(mission, cle, type) {
  const v = mission[cle];
  if (v === null || v === undefined) return "";
  return type === "datetime-local" ? toDateTimeLocal(v) : String(v);
}

/** Seules les valeurs réellement changées partent en base. */
export function patchMission(mission, form) {
  const patch = {};
  for (const [cle, colonne, , type] of CHAMPS) {
    const avant = valeurInitiale(mission, cle, type);
    const apres = String(form[cle] ?? "").trim();
    if (apres === avant.trim()) continue;
    patch[colonne] = type === "datetime-local" && apres ? new Date(apres).toISOString() : apres;
  }
  if (String(form.notes ?? "").trim() !== String(mission.notes ?? "").trim()) patch.notes = String(form.notes ?? "").trim();
  if (Boolean(form.urgent) !== Boolean(mission.urgent)) patch.urgent = Boolean(form.urgent);
  return patch;
}

