// SECOTO 151 — « Transporteurs à appeler » : libellés et lien d'appel (logique pure).
export const STATUTS_APPEL = [
  { cle: "appele", libelle: "Appelé" },
  { cle: "pas_de_reponse", libelle: "Pas de réponse" },
  { cle: "interesse", libelle: "Intéressé" },
  { cle: "refus", libelle: "Refus" },
];
export const CLASSE_STATUT = { interesse: "is-ok", refus: "is-bad", pas_de_reponse: "is-warn", appele: "" };
export const OFFRE_APPEL = { sent: "offre reçue", accepted: "a accepté", expired: "offre expirée", lost: "offre perdue", withdrawn: "offre retirée" };
export const telLien = (tel) => `tel:${String(tel || "").replace(/[^\d+]/g, "")}`;
