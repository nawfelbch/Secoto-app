import { withLambda } from "@netlify/aws-lambda-compat";
// SECOTO — heure estimée d'arrivée des missions suivies en direct (toutes les
// 2 minutes) et purge des positions devenues inutiles (une fois par heure).
// L'heure est TOUJOURS présentée comme une estimation. Sans service
// d'itinéraire configuré, aucune estimation n'est affichée.
import { computeRoute, geocodeFrenchAddress, json, serviceClient, validCoordinate } from "../lib/secoto-server.js";

export async function refreshEtas({ admin, now = new Date(), route = computeRoute, geocode = geocodeFrenchAddress }) {
  const { data: targets, error } = await admin.rpc("secoto_live_eta_targets");
  if (error) return { error: error.message };
  let updated = 0;
  for (const t of targets || []) {
    let destination = t.destination;
    if (!validCoordinate(destination)) destination = await geocode(destination?.label);
    if (!destination) continue;
    const r = await route({ lat: t.lat, lng: t.lng }, destination);
    if (!r) continue;
    const eta = new Date(now.getTime() + r.duration_min * 60000).toISOString();
    await admin.rpc("secoto_live_set_eta", {
      p_mission_id: t.mission_id, p_eta_at: eta, p_remaining_km: r.distance_km, p_provider: r.provider,
      p_based_on: t.recorded_at, p_multi: Boolean(t.multi_mission),
    });
    updated += 1;
  }
  return { targets: (targets || []).length, updated };
}

const handler = async () => {
  const admin = serviceClient();
  if (!admin) return json(503, { error: "server_not_configured" });
  const report = await refreshEtas({ admin });
  if (new Date().getUTCMinutes() < 2) {
    const purge = await admin.rpc("secoto_live_purge");
    report.purge = purge.error ? { error: purge.error.message } : purge.data;
  }
  return json(report.error ? 500 : 200, report);
};

export default withLambda(handler);
