import { withLambda } from "@netlify/aws-lambda-compat";
// SECOTO 089 — Recherche d'une adresse hors de France (sans compte).
// L'app l'appelle quand l'adresse tapée n'est pas en France. La clé du
// fournisseur reste ici. Aucune donnée n'est conservée.
import { json, parseBody, serviceClient, withCors } from "../lib/secoto-server.js";
import { chercherAdressesEtrangeres } from "../lib/adresses-internationales.js";

// Interrupteur « adresses_internationales » relu au plus toutes les minutes.
let interrupteur = { valeur: true, lu: 0 };
async function actif() {
  if (Date.now() - interrupteur.lu < 60_000) return interrupteur.valeur;
  const admin = serviceClient();
  if (!admin) return interrupteur.valeur;
  try {
    const { data, error } = await admin.rpc("secoto_feature_flags");
    if (!error && data && typeof data === "object") {
      interrupteur = { valeur: data.adresses_internationales !== false, lu: Date.now() };
    }
  } catch { /* on garde la dernière valeur connue */ }
  return interrupteur.valeur;
}

// Garde-fou contre les abus : 90 recherches par minute et par appareil.
const compteurs = new Map();
function tropDeRequetes(event, maintenant = Date.now()) {
  const ip = String(event?.headers?.["x-nf-client-connection-ip"] || event?.headers?.["x-forwarded-for"] || "?").split(",")[0].trim();
  const minute = Math.floor(maintenant / 60_000);
  const cle = `${ip}|${minute}`;
  const n = (compteurs.get(cle) || 0) + 1;
  compteurs.set(cle, n);
  if (compteurs.size > 5000) compteurs.clear();
  return n > 90;
}

export const traiter = async (event) => {
  if (event.httpMethod !== "POST") return json(405, { error: "method_not_allowed" });
  const body = parseBody(event);
  const q = typeof body?.q === "string" ? body.q : "";
  if (q.trim().length < 3 || q.length > 200) return json(200, { items: [] });
  if (tropDeRequetes(event)) return json(429, { error: "too_many_requests", items: [] });
  if (!(await actif())) return json(200, { items: [], disabled: true });
  const r = await chercherAdressesEtrangeres(q);
  return json(r.ok ? 200 : 503, { items: r.items, provider: r.provider });
};

export default withLambda(withCors(traiter));
