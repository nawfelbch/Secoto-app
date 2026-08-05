import { supabase } from "../supabaseClient";

const WEB_APP_URL = "https://app.secoto-transport.fr";

function firstRow(data) {
  return Array.isArray(data) ? data[0] : data;
}

export async function createMissionClaimForAdmin(mission) {
  if (!mission?.id) throw new Error("Mission invalide.");

  const { data, error } = await supabase.rpc("secoto_generate_mission_claim", {
    p_mission_id: mission.id,
    p_expires_in_days: 30,
  });

  if (error) throw error;

  const row = firstRow(data);

  if (!row?.token) {
    throw new Error("Le lien sécurisé n'a pas été généré.");
  }

  return {
    missionId: mission.id,
    publicRef: row.public_ref || mission.publicRef || "Mission SECOTO",
    expiresAt: row.expires_at,
    url: `${WEB_APP_URL}/?claim=${encodeURIComponent(row.token)}`,
  };
}