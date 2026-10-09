import { timingSafeEqual } from "node:crypto";
import { withLambda } from "@netlify/aws-lambda-compat";
// SECOTO 088 — Conversions Google Ads par gclid (commandes payées).
// ----------------------------------------------------------------------------
// Google Ads vient chercher ce fichier tout seul (Outils › Conversions ›
// Importations › « Programmer » depuis une URL HTTPS). Protégé par un
// identifiant et un mot de passe que seul Nawfal saisit dans Netlify et dans
// Google Ads. Contenu : uniquement les commandes payées avec consentement
// publicitaire et un gclid ; valeur = commission SECOTO.
import { serviceClient } from "../lib/secoto-server.js";
import { csvGoogle } from "../lib/conversions.js";

function egal(a, b) {
  const x = Buffer.from(String(a || ""));
  const y = Buffer.from(String(b || ""));
  return x.length === y.length && x.length > 0 && timingSafeEqual(x, y);
}

export function authentifie(headers, env = process.env) {
  const user = env.GADS_CSV_USER;
  const pass = env.GADS_CSV_PASSWORD;
  if (!user || !pass) return false;
  const brut = headers?.authorization || headers?.Authorization || "";
  if (!brut.startsWith("Basic ")) return false;
  const [u, ...reste] = Buffer.from(brut.slice(6), "base64").toString("utf8").split(":");
  return egal(u, user) && egal(reste.join(":"), pass);
}

const handler = async (event) => {
  if (event.httpMethod !== "GET") return { statusCode: 405, body: "" };
  if (!authentifie(event.headers)) {
    return { statusCode: 401, headers: { "WWW-Authenticate": 'Basic realm="SECOTO"' }, body: "" };
  }
  const admin = serviceClient();
  if (!admin) return { statusCode: 503, body: "" };
  const { data, error } = await admin.rpc("secoto_conversions_google");
  if (error) return { statusCode: 500, body: "" };
  return {
    statusCode: 200,
    headers: { "Content-Type": "text/csv; charset=utf-8", "Cache-Control": "no-store" },
    body: csvGoogle(data, process.env.GADS_CONVERSION_NAME || "commande_payee"),
  };
};

export default withLambda(handler);
