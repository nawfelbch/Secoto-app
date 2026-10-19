// SECOTO 101 — appels et calculs des propositions et modifications de mission.
import { supabase } from "../supabaseClient";

async function rpc(name, args) {
  const { data, error } = await supabase.rpc(name, args);
  if (error) throw error;
  return data;
}

export const proposerMission = (missionId, { price = null, date, message = "" }) =>
  rpc("secoto_mission_proposer", {
    p_mission_id: missionId,
    p_price: price === null || price === "" ? null : Number(String(price).replace(",", ".")),
    p_date: date ? new Date(date).toISOString() : null,
    p_message: message || null,
  });

export const modifierMissionAdmin = (missionId, patch) =>
  rpc("secoto_admin_update_mission", { p_mission_id: missionId, p_patch: patch });

export const modifierPropositionAdmin = (applicationId, { price = null, date = null }) =>
  rpc("secoto_admin_application_update", {
    p_application_id: applicationId,
    p_price: price === null || price === "" ? null : Number(String(price).replace(",", ".")),
    p_date: date ? new Date(date).toISOString() : null,
  });
