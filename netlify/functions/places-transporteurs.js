import { withLambda } from "@netlify/aws-lambda-compat";
// SECOTO 151 — transporteurs hors SECOTO autour du départ (Google Places).
// Réservé aux administrateurs. Sans clé GOOGLE_PLACES_API_KEY : réponse 503
// claire, l'écran l'indique. Les numéros déjà inscrits chez SECOTO sont retirés.
import { authenticatedUserId, bearer, json, parseBody, serviceClient, withCors } from "../lib/secoto-server.js";

export const PLACES_URL = "https://places.googleapis.com/v1/places:searchText";
const RECHERCHES = {
  plateau: ["dépannage remorquage plateau", "transport de véhicules porte-voitures"],
  convoyage: ["convoyage de véhicules"],
};

export const chiffres = (tel) => String(tel || "").replace(/\D/g, "").replace(/^33/, "0");

export function placesVersTransporteurs(places = [], dejaConnus = new Set()) {
  const vus = new Set();
  return places
    .map((p) => ({
      cle: `google:${p.id}`,
      nom: p.displayName?.text || "",
      telephone: p.nationalPhoneNumber || p.internationalPhoneNumber || "",
      adresse: p.formattedAddress || "",
      site: p.websiteUri || "",
      note: p.rating ?? null,
      avis: p.userRatingCount ?? null,
    }))
    .filter((t) => t.telephone && !dejaConnus.has(chiffres(t.telephone)) && !vus.has(t.cle) && vus.add(t.cle));
}

const handler = async (event) => {
  if (event.httpMethod !== "POST") return json(405, { error: "method_not_allowed" });
  const admin = serviceClient();
  if (!admin) return json(503, { error: "server_not_configured" });
  const userId = await authenticatedUserId(bearer(event));
  if (!userId) return json(401, { error: "unauthorized" });
  const { data: compte } = await admin.from("accounts").select("role").eq("id", userId).maybeSingle();
  if (compte?.role !== "admin") return json(403, { error: "forbidden" });
  const cle = process.env.GOOGLE_PLACES_API_KEY;
  if (!cle) return json(503, { error: "sans_cle", message: "Recherche Google non configurée : ajoutez la clé GOOGLE_PLACES_API_KEY dans Netlify." });
  const body = parseBody(event) || {};
  const lat = Number(body.lat), lng = Number(body.lng);
  if (!Number.isFinite(lat) || !Number.isFinite(lng)) return json(400, { error: "position_manquante" });
  const rayon = Math.min(Math.max(Number(body.rayon_m) || 40000, 5000), 50000);

  const { data: connus } = await admin.from("accounts").select("phone").eq("role", "transporter").not("phone", "is", null);
  const dejaConnus = new Set((connus || []).map((c) => chiffres(c.phone)).filter(Boolean));

  const places = [];
  for (const q of RECHERCHES[body.mode === "convoyage" ? "convoyage" : "plateau"]) {
    const r = await fetch(PLACES_URL, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "X-Goog-Api-Key": cle,
        "X-Goog-FieldMask": "places.id,places.displayName,places.nationalPhoneNumber,places.internationalPhoneNumber,places.formattedAddress,places.websiteUri,places.rating,places.userRatingCount",
      },
      body: JSON.stringify({ textQuery: q, languageCode: "fr", regionCode: "FR", maxResultCount: 20,
        locationBias: { circle: { center: { latitude: lat, longitude: lng }, radius: rayon } } }),
    });
    if (!r.ok) return json(502, { error: "google", message: `Google Places : ${r.status}` });
    places.push(...(((await r.json()) || {}).places || []));
  }
  return json(200, { transporteurs: placesVersTransporteurs(places, dejaConnus) });
};

export default withLambda(withCors(handler));
