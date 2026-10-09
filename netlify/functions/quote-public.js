import { createHash } from "node:crypto";
import { withLambda } from "@netlify/aws-lambda-compat";
// SECOTO — devis etabli SANS compte.
// ----------------------------------------------------------------------------
// C'est la premiere chose que voit un visiteur venu d'une publicite : il donne
// un trajet et un vehicule, il obtient un prix. Aucune donnee personnelle n'est
// demandee, et rien de nominatif n'est conserve tant qu'il n'a pas de compte.
//
// Le prix est calcule PAR LA BASE, avec le meme barème et les memes
// validations que le parcours identifie : un seul chemin de prix, pas deux qui
// finiraient par diverger. Le visiteur ne transmet aucun montant.
import { computeRoute, json, parseBody, serviceClient, withCors } from "../lib/secoto-server.js";
import { enregistrerAttribution } from "../lib/attribution-serveur.js";

const { SECOTO_IP_SALT = "" } = process.env;

// L'adresse du visiteur ne sert qu'a compter ses demandes. On n'en garde qu'une
// empreinte, salee et changee chaque jour : impossible de relier deux jours, ni
// de retrouver l'adresse d'origine.
export function empreinteVisiteur(event, jour = new Date().toISOString().slice(0, 10)) {
  const brut = String(
    event?.headers?.["x-nf-client-connection-ip"]
      || event?.headers?.["x-forwarded-for"]
      || event?.headers?.["client-ip"]
      || "",
  ).split(",")[0].trim();
  if (!brut) return null;
  return createHash("sha256").update(`${SECOTO_IP_SALT}|${jour}|${brut}`).digest("hex");
}

const handler = async (event) => {
  if (event.httpMethod !== "POST") return json(405, { error: "method_not_allowed" });
  const admin = serviceClient();
  if (!admin) return json(503, { error: "server_not_configured" });

  const body = parseBody(event);
  if (!body || typeof body.payload !== "object") return json(400, { error: "invalid_json" });

  const payload = body.payload;
  // Toute cle de montant envoyee par le navigateur est ignoree.
  for (const key of Object.keys(payload)) {
    if (/price|cents|amount|pay|margin|distance/i.test(key)) delete payload[key];
  }
  // Un visiteur sans compte n'appartient a aucune societe.
  delete payload.business_id;

  const empreinte = empreinteVisiteur(event);
  if (!empreinte) return json(400, { error: "invalid_request" });

  const route = await computeRoute(payload.pickup, payload.delivery, {
    profile: payload.mode === "plateau" ? "hgv" : "car",
  });

  const { data, error } = await admin.rpc("secoto_anon_quote_create", {
    p_payload: payload,
    p_route: route,
    p_ip_hash: empreinte,
  });
  if (error) return json(422, { error: "quote_rejected", message: error.message });
  // 088 : provenance du visiteur (utm, gclid, fbclid) et son choix de cookies.
  await enregistrerAttribution(admin, data?.quote?.id, body);

  return json(200, { token: data?.token, quote: data?.quote, routing: route ? "ok" : "unavailable" });
};

export default withLambda(withCors(handler));
