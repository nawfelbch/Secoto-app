import { withLambda } from "@netlify/aws-lambda-compat";
// SECOTO 103 — distance routière pour l'administrateur.
// Création de mission (adresses saisies à la main) et devis manuel sans
// itinéraire : le serveur géocode si besoin (Base Adresse Nationale), puis
// calcule le trajet avec les mêmes fournisseurs que les devis (ORS, Geoapify,
// OSRM en secours). Réservé aux administrateurs.
import { authenticatedUserId, bearer, computeRoute, geocodeFrenchAddress, json, parseBody, serviceClient, validCoordinate, withCors } from "../lib/secoto-server.js";

export async function resoudrePoint(point, geocode = geocodeFrenchAddress) {
  if (validCoordinate(point)) return { lat: Number(point.lat), lng: Number(point.lng), country: point.country };
  const label = String(point?.label || "").trim().slice(0, 300);
  return label ? geocode(label) : null;
}

const handler = async (event) => {
  if (event.httpMethod !== "POST") return json(405, { error: "method_not_allowed" });
  const admin = serviceClient();
  if (!admin) return json(503, { error: "server_not_configured" });
  const userId = await authenticatedUserId(bearer(event));
  if (!userId) return json(401, { error: "unauthorized" });
  const { data: compte } = await admin.from("accounts").select("role").eq("id", userId).maybeSingle();
  if (compte?.role !== "admin") return json(403, { error: "forbidden" });
  const body = parseBody(event);
  if (!body) return json(400, { error: "invalid_json" });
  const [from, to] = await Promise.all([resoudrePoint(body.from), resoudrePoint(body.to)]);
  if (!from || !to) return json(422, { error: "adresse_introuvable", message: "Adresse introuvable : précisez la ville et le code postal, ou saisissez la distance." });
  const route = await computeRoute(from, to, { profile: body.mode === "plateau" ? "hgv" : "car" });
  if (!route) return json(422, { error: "itineraire_indisponible", message: "Itinéraire indisponible pour ce trajet : saisissez la distance à la main." });
  return json(200, route);
};

export default withLambda(withCors(handler));
