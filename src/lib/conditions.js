// SECOTO 075 — Acceptation des conditions (CGU, confidentialité, conditions
// transporteur). La base décide seule qui doit accepter et quelle version :
// l'application ne fait qu'afficher l'écran et transmettre le clic.
import { supabase } from "../supabaseClient";
import { getPlatform, isNativePlatform } from "../platform/runtime";

export const DOCUMENT_LABELS = Object.freeze({
  cgu: "les conditions générales",
  confidentialite: "la politique de confidentialité",
  conditions_transporteur: "les conditions transporteur",
});

/** Titres complets, pour les boutons « Lire ». */
export const DOCUMENT_TITLES = Object.freeze({
  cgu: "Conditions générales d’utilisation",
  confidentialite: "Politique de confidentialité",
  conditions_transporteur: "Conditions transporteur",
});

export const PRIVACY_PATH = "/politique-confidentialite.html";

const PROD_ORIGIN = "https://app.secoto-transport.fr";

/** Adresse complète d'une page de conditions (chemin relatif en base). */
export function conditionsUrl(path, version) {
  const clean = String(path || "").trim();
  if (!clean) return "";
  const origin = isNativePlatform() || typeof window === "undefined" ? PROD_ORIGIN : window.location.origin;
  const url = new URL(clean, origin);
  if (version) url.searchParams.set("v", version);
  return url.toString();
}

/**
 * Liens à afficher à côté de la case, dans l'ordre de la phrase :
 * « J'accepte les conditions générales, la politique de confidentialité et
 * les conditions transporteur ».
 */
export function conditionsLinks(documents, urls, version) {
  return (documents || [])
    .filter((key) => DOCUMENT_LABELS[key] && urls?.[key])
    .map((key) => ({ key, label: DOCUMENT_LABELS[key], title: DOCUMENT_TITLES[key], url: conditionsUrl(urls[key], version) }));
}

// En cas d'erreur (fonction absente, réseau), on ne bloque personne : la
// fenêtre réapparaîtra au prochain chargement. Ne jamais enfermer un
// utilisateur hors de l'application à cause d'un incident technique.
export async function termsPublic() {
  const { data, error } = await supabase.rpc("secoto_terms_public");
  if (error || !data) return { active: false };
  return data;
}

export async function termsStatus() {
  const { data, error } = await supabase.rpc("secoto_terms_status");
  if (error || !data) return { required: false };
  return data;
}

export async function acceptTerms(version) {
  const { data, error } = await supabase.rpc("secoto_accept_terms", {
    p_version: version,
    p_platform: getPlatform(),
    p_user_agent: typeof navigator === "undefined" ? null : String(navigator.userAgent || "").slice(0, 300),
  });
  if (error) throw error;
  return data;
}
