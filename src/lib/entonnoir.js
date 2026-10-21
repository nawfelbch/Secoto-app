// SECOTO 110 — Comptage anonyme des étapes du formulaire de devis.
// ----------------------------------------------------------------------------
// But : savoir où les visiteurs abandonnent. Un identifiant de visite tiré au
// hasard vit dans l'onglet (sessionStorage, effacé à sa fermeture) ; il n'est
// relié à rien d'autre. Aucun contenu du formulaire n'est envoyé : le nom de
// l'étape, la provenance et le type d'écran. Chaque étape ne compte qu'une
// fois par visite. Un envoi raté est ignoré : le formulaire n'attend jamais.
import { supabase } from "../supabaseClient";
import { lireAttribution } from "./attribution";

const CLE_VISITE = "secoto:visite-entonnoir";
export const ETAPES = Object.freeze(["arrivee", "trajet", "vehicule", "mode", "dates", "contact", "prix", "erreur_prix", "reserver"]);
const envoyees = new Set();

/** Provenance réduite à 4 valeurs : ads, naturel, direct, autre. */
export function sourceVisite(attr) {
  if (!attr || typeof attr !== "object") return "direct";
  if (attr.gclid || attr.utm_medium === "cpc") return "ads";
  if (attr.utm_source === "google-naturel") return "naturel";
  return Object.keys(attr).some((k) => k.startsWith("utm_") || k === "fbclid") ? "autre" : "direct";
}

function idVisite() {
  try {
    let id = sessionStorage.getItem(CLE_VISITE);
    if (!id) {
      id = globalThis.crypto?.randomUUID?.();
      if (!id) return null;
      sessionStorage.setItem(CLE_VISITE, id);
    }
    return id;
  } catch {
    return null;
  }
}

export function etapeFormulaire(etape, { connecte = false } = {}) {
  if (!ETAPES.includes(etape) || envoyees.has(etape)) return;
  const visite = idVisite();
  if (!visite) return;
  envoyees.add(etape);
  let source = "direct";
  try { source = sourceVisite(lireAttribution()); } catch { /* stockage indisponible */ }
  const mobile = typeof window !== "undefined" && window.matchMedia?.("(max-width: 720px)")?.matches === true;
  Promise.resolve()
    .then(() => supabase.rpc("secoto_etape_formulaire", { p_visite: visite, p_etape: etape, p_source: source, p_mobile: mobile, p_connecte: Boolean(connecte) }))
    .catch(() => { /* jamais bloquant */ });
}
