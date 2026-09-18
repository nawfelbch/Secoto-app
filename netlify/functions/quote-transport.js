import { withLambda } from "@netlify/aws-lambda-compat";
// SECOTO — calcul d'un devis de transport à la demande.
// Le téléphone envoie des adresses vérifiées (Base Adresse Nationale) et la
// description du véhicule. L'itinéraire routier est calculé ICI, puis le prix,
// la rémunération partenaire et la marge sont calculés PAR LA BASE
// (secoto_quote_create, réservée au service). Le client ne transmet aucun montant.
import { authenticatedUserId, bearer, computeRoute, json, parseBody, serviceClient, withCors } from "../lib/secoto-server.js";

const handler = async (event) => {
  if (event.httpMethod !== "POST") return json(405, { error: "method_not_allowed" });
  const admin = serviceClient();
  if (!admin || !process.env.SUPABASE_ANON_KEY) return json(503, { error: "server_not_configured" });
  const userId = await authenticatedUserId(bearer(event));
  if (!userId) return json(401, { error: "unauthorized" });
  const body = parseBody(event);
  if (!body || typeof body.payload !== "object") return json(400, { error: "invalid_json" });

  const payload = body.payload;
  // Toute clé de montant envoyée par le téléphone est ignorée.
  for (const key of Object.keys(payload)) {
    if (/price|cents|amount|pay|margin|distance/i.test(key)) delete payload[key];
  }
  const route = await computeRoute(payload.pickup, payload.delivery, {
    profile: payload.mode === "plateau" ? "hgv" : "car",
  });

  const { data, error } = await admin.rpc("secoto_quote_create", {
    p_account_id: userId,
    p_payload: payload,
    p_route: route,
  });
  if (error) return json(422, { error: "quote_rejected", message: error.message });
  return json(200, { quote: data, routing: route ? "ok" : "unavailable" });
};

export default withLambda(withCors(handler));
