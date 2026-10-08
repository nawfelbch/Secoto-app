import { withLambda } from "@netlify/aws-lambda-compat";
// SECOTO — lancement MANUEL de la maintenance, pour l'environnement de TEST.
// ----------------------------------------------------------------------------
// Netlify n'exécute les fonctions planifiées (od-maintenance, chaque minute)
// que sur le déploiement de production. Sur l'aperçu de test, cette porte
// permet de déclencher la même maintenance (virements à l'échéance,
// remboursements, verrous expirés) à la demande.
//
// Fermée par défaut : sans la variable SECOTO_MAINTENANCE_TEST_SECRET (posée
// UNIQUEMENT dans le contexte « Branch deploys »), elle répond 404. Elle refuse
// aussi toute clé Stripe qui n'est pas une clé de test.
import { timingSafeEqual } from "node:crypto";
import Stripe from "stripe";
import { json, serviceClient } from "../lib/secoto-server.js";
import { runMaintenance } from "./od-maintenance.js";

function memeSecret(a, b) {
  const x = Buffer.from(String(a || ""));
  const y = Buffer.from(String(b || ""));
  return x.length === y.length && x.length >= 24 && timingSafeEqual(x, y);
}

const handler = async (event) => {
  const secret = process.env.SECOTO_MAINTENANCE_TEST_SECRET;
  const cle = process.env.STRIPE_SECRET_KEY || "";
  if (!secret || !cle.startsWith("sk_test_")) return json(404, { error: "not_found" });
  if (event.httpMethod !== "POST") return json(405, { error: "method_not_allowed" });
  const fourni = event.headers?.["x-secoto-maintenance"] || event.headers?.["X-Secoto-Maintenance"];
  if (!memeSecret(fourni, secret)) return json(401, { error: "unauthorized" });
  const admin = serviceClient();
  if (!admin) return json(503, { error: "server_not_configured" });
  const report = await runMaintenance({ admin, stripe: new Stripe(cle) });
  return json(report.error ? 500 : 200, report);
};

export default withLambda(handler);
