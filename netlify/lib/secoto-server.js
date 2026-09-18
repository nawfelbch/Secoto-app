// SECOTO — utilitaires serveur partagés par les fonctions Netlify (030-032).
// Aucun secret n'est codé ici : tout vient des variables d'environnement.
import { createClient } from "@supabase/supabase-js";

export const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

export function json(statusCode, body) {
  return {
    statusCode,
    headers: { "Cache-Control": "no-store", "Content-Type": "application/json; charset=utf-8" },
    body: JSON.stringify(body),
  };
}

export function bearer(event) {
  const raw = event.headers?.authorization || event.headers?.Authorization || "";
  return raw.startsWith("Bearer ") ? raw.slice(7) : "";
}

export function parseBody(event) {
  try {
    return JSON.parse(event.body || "{}");
  } catch {
    return null;
  }
}

export function serviceClient(env = process.env) {
  if (!env.SUPABASE_URL || !env.SUPABASE_SERVICE_ROLE_KEY) return null;
  return createClient(env.SUPABASE_URL, env.SUPABASE_SERVICE_ROLE_KEY, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
}

// Client qui agit AVEC L'IDENTITÉ de l'utilisateur : auth.uid() et les
// contrôles SQL s'appliquent exactement comme depuis l'application.
export function userClient(accessToken, env = process.env) {
  if (!env.SUPABASE_URL || !env.SUPABASE_ANON_KEY || !accessToken) return null;
  return createClient(env.SUPABASE_URL, env.SUPABASE_ANON_KEY, {
    auth: { persistSession: false, autoRefreshToken: false },
    global: { headers: { Authorization: `Bearer ${accessToken}` } },
  });
}

export async function authenticatedUserId(accessToken, env = process.env) {
  if (!accessToken || !env.SUPABASE_URL || !env.SUPABASE_ANON_KEY) return null;
  const anon = createClient(env.SUPABASE_URL, env.SUPABASE_ANON_KEY, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const { data, error } = await anon.auth.getUser(accessToken);
  return error ? null : data?.user?.id || null;
}

// ----------------------------------------------------------------------------
// Itinéraire routier. Fournisseurs pris en charge :
//   ROUTING_PROVIDER=ors   + ORS_API_KEY        (openrouteservice, HeiGIT)
//   ROUTING_PROVIDER=osrm  + OSRM_URL           (instance OSRM auto-hébergée)
// L'ancienne adresse api.openrouteservice.org a été coupée le 24 août 2026 :
// la base par défaut est api.heigit.org/openrouteservice, surchargeable par
// ORS_BASE_URL si HeiGIT la fait encore évoluer. La clé API est inchangée.
// Sans fournisseur configuré : null → devis manuel. Jamais de distance
// « à vol d'oiseau » présentée comme une distance routière.
// ----------------------------------------------------------------------------
export function validCoordinate(point) {
  const lat = Number(point?.lat);
  const lng = Number(point?.lng);
  return Number.isFinite(lat) && Number.isFinite(lng) && Math.abs(lat) <= 90 && Math.abs(lng) <= 180;
}

export async function computeRoute(from, to, { env = process.env, fetchImpl = fetch, profile = "car" } = {}) {
  if (!validCoordinate(from) || !validCoordinate(to)) return null;
  const provider = String(env.ROUTING_PROVIDER || "").toLowerCase();
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), 8000);
  try {
    if (provider === "ors" && env.ORS_API_KEY) {
      const orsProfile = profile === "hgv" ? "driving-hgv" : "driving-car";
      const base = String(env.ORS_BASE_URL || "https://api.heigit.org/openrouteservice").replace(/\/+$/, "");
      const url = `${base}/v2/directions/${orsProfile}?start=${Number(from.lng)},${Number(from.lat)}&end=${Number(to.lng)},${Number(to.lat)}`;
      const res = await fetchImpl(url, { headers: { Authorization: env.ORS_API_KEY, Accept: "application/geo+json" }, signal: controller.signal });
      if (!res.ok) return null;
      const body = await res.json();
      const summary = body?.features?.[0]?.properties?.summary;
      if (!summary || !(summary.distance > 0)) return null;
      return { distance_km: Math.round(summary.distance / 100) / 10, duration_min: Math.round(summary.duration / 60), provider: `ors-${orsProfile}` };
    }
    if (provider === "osrm" && env.OSRM_URL) {
      const base = String(env.OSRM_URL).replace(/\/+$/, "");
      const url = `${base}/route/v1/driving/${Number(from.lng)},${Number(from.lat)};${Number(to.lng)},${Number(to.lat)}?overview=false`;
      const res = await fetchImpl(url, { signal: controller.signal });
      if (!res.ok) return null;
      const body = await res.json();
      const route = body?.routes?.[0];
      if (body?.code !== "Ok" || !(route?.distance > 0)) return null;
      return { distance_km: Math.round(route.distance / 100) / 10, duration_min: Math.round(route.duration / 60), provider: "osrm" };
    }
    return null;
  } catch {
    return null;
  } finally {
    clearTimeout(timer);
  }
}

// Géocodage d'une adresse française (Base Adresse Nationale, sans clé).
export async function geocodeFrenchAddress(label, { fetchImpl = fetch } = {}) {
  const q = String(label || "").trim();
  if (q.length < 5) return null;
  try {
    const res = await fetchImpl(`https://api-adresse.data.gouv.fr/search/?q=${encodeURIComponent(q)}&limit=1`);
    if (!res.ok) return null;
    const body = await res.json();
    const feature = body?.features?.[0];
    if (!feature || Number(feature.properties?.score) < 0.5) return null;
    const [lng, lat] = feature.geometry.coordinates;
    return { lat, lng };
  } catch {
    return null;
  }
}

// ----------------------------------------------------------------------------
// Notification de mission pour un partenaire.
//   masked   : aucune donnée de mission sur l'écran verrouillé.
//   detailed : départ, arrivée (commune + CP), modèle, rémunération.
// Jamais de nom, téléphone ou adresse exacte du client.
// ----------------------------------------------------------------------------
export function formatEuros(cents) {
  const value = Number(cents || 0) / 100;
  return `${value.toLocaleString("fr-FR", { minimumFractionDigits: value % 1 ? 2 : 0, maximumFractionDigits: 2 })} €`;
}

export function offerPushCopy(offer, privacy = "masked") {
  if (!offer || privacy !== "detailed") {
    return { title: "SECOTO — mission disponible", body: "Une mission correspond à vos préférences. Ouvrez SECOTO pour la consulter." };
  }
  const place = (p) => [p?.city, p?.postcode ? `(${p.postcode})` : ""].filter(Boolean).join(" ");
  return {
    title: `Mission · ${formatEuros(offer.partner_pay_cents)} pour vous`,
    body: `${place(offer.pickup)} → ${place(offer.delivery)} · ${String(offer.vehicle_model || "Véhicule").slice(0, 60)}`,
  };
}

// ----------------------------------------------------------------------------
// Événements Stripe des nouveaux parcours.
// ----------------------------------------------------------------------------
export const OD_PAYMENT_EVENTS = new Set([
  "payment_intent.amount_capturable_updated",
  "payment_intent.succeeded",
  "payment_intent.payment_failed",
  "payment_intent.canceled",
  "charge.refunded",
  "charge.dispute.created",
  "charge.dispute.closed",
]);
export const SUBSCRIPTION_EVENTS = new Set([
  "checkout.session.completed",
  "invoice.paid",
  "invoice.payment_failed",
  "customer.subscription.deleted",
]);
export const OD_PURPOSES = new Set(["od_convoyage", "od_plateau", "od_plateau_commission", "subscription_extension"]);

export function intentIdFromObject(type, object = {}) {
  if (type.startsWith("payment_intent.")) return object.id || null;
  if (type.startsWith("charge.dispute.")) return object.payment_intent || null;
  if (type.startsWith("charge.")) return object.payment_intent || null;
  return null;
}

export function subscriptionEventData(type, object = {}) {
  if (type === "checkout.session.completed") {
    if (object.mode !== "subscription") return null;
    return { subscriptionId: object.metadata?.secoto_subscription_id || null, stripeSubscriptionId: object.subscription || null };
  }
  if (type === "invoice.paid" || type === "invoice.payment_failed") {
    const line = object.lines?.data?.[0];
    const meta = object.subscription_details?.metadata || object.parent?.subscription_details?.metadata || line?.metadata || {};
    const stripeSubscriptionId = object.subscription || object.parent?.subscription_details?.subscription || null;
    return {
      subscriptionId: meta.secoto_subscription_id || null,
      stripeSubscriptionId,
      periodStart: line?.period?.start ? new Date(line.period.start * 1000).toISOString() : null,
      periodEnd: line?.period?.end ? new Date(line.period.end * 1000).toISOString() : null,
    };
  }
  if (type === "customer.subscription.deleted") {
    return { subscriptionId: object.metadata?.secoto_subscription_id || null, stripeSubscriptionId: object.id || null };
  }
  return null;
}

// ---------------------------------------------------------------------------
// CORS. L'application native est servie depuis capacitor://localhost : chaque
// appel a une fonction Netlify est donc une requete d'origine differente. Sans
// reponse au preflight OPTIONS ni en-tetes d'autorisation, WebKit abandonne la
// requete et l'ecran affiche « Load failed », sans plus d'explication. Le site
// web, lui, fonctionne : meme origine, aucun preflight. D'ou un defaut visible
// sur iPhone seulement.
// ---------------------------------------------------------------------------
export const ALLOWED_ORIGINS = new Set([
  "https://app.secoto-transport.fr",
  "https://www.app.secoto-transport.fr",
  "capacitor://localhost",
  "ionic://localhost",
  "http://localhost",
  "https://localhost",
]);

export function corsHeaders(origin = "") {
  const valide = ALLOWED_ORIGINS.has(origin) ? origin : "https://app.secoto-transport.fr";
  return {
    "Access-Control-Allow-Headers": "Authorization, Content-Type",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Access-Control-Allow-Origin": valide,
    "Access-Control-Max-Age": "86400",
    Vary: "Origin",
  };
}

// Repond au preflight et ajoute les en-tetes a toutes les reponses, sans
// toucher a la logique de la fonction enveloppee.
export function withCors(handler) {
  return async (event, context) => {
    const origine = event?.headers?.origin || event?.headers?.Origin || "";
    const entetes = corsHeaders(origine);
    if (event?.httpMethod === "OPTIONS") {
      return { statusCode: 204, headers: { ...entetes, "Cache-Control": "no-store" }, body: "" };
    }
    const reponse = await handler(event, context);
    return { ...reponse, headers: { ...(reponse?.headers || {}), ...entetes } };
  };
}
