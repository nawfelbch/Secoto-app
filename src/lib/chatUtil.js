// ============================================================================
// SECOTO 142 — chat client ↔ transporteur : fonctions pures (testables seules).
// ============================================================================

export const CHAT_MAX = 2000;

/** Titre du fil selon qui le lit. */
export function titreChat(role) {
  if (role === "transporteur") return "Discuter avec votre client";
  if (role === "admin") return "Conversation client ↔ transporteur";
  return "Discuter avec votre transporteur";
}

/** Libellé de l'auteur d'un message, vu par le lecteur. */
export function auteurChat(message, roleLecteur) {
  if (message?.moi) return "Vous";
  const r = message?.auteur_role;
  if (r === "admin") return "SECOTO";
  if (r === "transporteur") return roleLecteur === "admin" ? "Transporteur" : "Votre transporteur";
  if (r === "client") return roleLecteur === "admin" ? "Client" : "Votre client";
  return "";
}

/** Texte prêt à envoyer, ou "" s'il est vide. */
export function texteAEnvoyer(brut) {
  return String(brut ?? "").trim().slice(0, CHAT_MAX);
}

/** Heure courte : « 14:05 » aujourd'hui, « mar. 12 nov., 14:05 » sinon. */
export function heureChat(iso, maintenant = new Date()) {
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return "";
  const memeJour = d.toDateString() === maintenant.toDateString();
  return memeJour
    ? d.toLocaleTimeString("fr-FR", { hour: "2-digit", minute: "2-digit" })
    : d.toLocaleString("fr-FR", { weekday: "short", day: "numeric", month: "short", hour: "2-digit", minute: "2-digit" });
}

/** Le chat s'affiche dès qu'un transporteur est attribué (mission non annulée). */
export function chatVisibleMission(mission) {
  return Boolean(mission?.id && mission.assignedTransporterId && !["cancelled", "published"].includes(mission.status));
}

/** Côté client : commande confirmée, en cours ou livrée, avec une mission. */
export function chatVisibleCommande(order) {
  return Boolean(order?.mission_id && ["partner_confirmed", "picked_up", "delivered"].includes(order.status));
}
