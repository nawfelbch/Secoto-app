// SECOTO 147 — Onglet admin « Clients pros » : recherche, tri, étiquettes
// (logique pure, sans réseau : testable).

export const TRIS = [
  { cle: "activite", libelle: "Activité récente" },
  { cle: "ca", libelle: "Chiffre d’affaires" },
  { cle: "commandes", libelle: "Commandes" },
  { cle: "inscription", libelle: "Inscription" },
];

const norm = (s) => String(s || "").toLowerCase().normalize("NFD").replace(/[̀-ͯ]/g, "");

// Recherche sur société, nom, e-mail, téléphone, ville, SIREN ; puis tri.
export function filtrerClients(clients, recherche = "", tri = "activite") {
  const q = norm(recherche).trim();
  const liste = (clients || []).filter((c) => !q || [c.societe, c.entreprise, c.nom, c.email, c.telephone, c.ville, c.siren]
    .some((v) => norm(v).includes(q) || (v && String(v).replace(/\s/g, "").includes(q.replace(/\s/g, "")))));
  const date = (v) => (v ? new Date(v).getTime() : 0);
  const cle = {
    activite: (c) => date(c.derniere_commande_at || c.dernier_devis_at || c.inscrit_le),
    ca: (c) => Number(c.ca_cents) || 0,
    commandes: (c) => Number(c.commandes) || 0,
    inscription: (c) => date(c.inscrit_le),
  }[tri] || ((c) => date(c.tri));
  return [...liste].sort((a, b) => cle(b) - cle(a));
}

// Étiquette d'un client : actif (au moins une commande) ou prospect.
export function etiquetteClient(c) {
  if ((c.en_cours || 0) > 0) return { texte: "Commande en cours", classe: "is-ok" };
  if ((c.commandes || 0) > 0) return { texte: "Client actif", classe: "is-ok" };
  if ((c.devis || 0) > 0) return { texte: "Prospect · devis sans commande", classe: "is-warn" };
  return { texte: "Inscrit · aucun devis", classe: "" };
}

export function nomClient(c) {
  return c.societe || c.entreprise || c.raison_sociale || c.nom || "Client pro sans nom";
}
