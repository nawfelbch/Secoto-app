// SECOTO — Mesure de conversion côté navigateur (088).
//
// Un seul point d'entrée pour toute l'application : l'événement ne part qu'une
// fois par paiement, seulement avec l'accord du visiteur (voir consentement.js),
// et un échec de mesure ne doit jamais casser l'écran qui le porte.
// L'ancien pixel OpenAI est retiré (décision de Nawfal du 09/10/2026).
import { evenement } from "./consentement";

const CLE = "secoto:conversions-mesurees";

function dejaMesure(reference) {
  try {
    const vues = JSON.parse(window.localStorage.getItem(CLE) || "[]");
    if (vues.includes(reference)) return true;
    window.localStorage.setItem(CLE, JSON.stringify([...vues, reference].slice(-50)));
    return false;
  } catch {
    // Navigation privée, stockage bloqué : on mesure, quitte à compter deux fois.
    return false;
  }
}

/** event_id commun navigateur / serveur : « cmd-<identifiant du paiement> ». */
export const eventIdCommande = (paymentId) => `cmd-${paymentId}`;

export function conversionCommande(paymentId) {
  try {
    if (!paymentId || typeof window === "undefined") return;
    if (dejaMesure(String(paymentId))) return;
    evenement("commande_payee", { currency: "EUR" }, { eventId: eventIdCommande(paymentId) });
  } catch {
    // Jamais d'erreur remontée au client pour une question de mesure.
  }
}
