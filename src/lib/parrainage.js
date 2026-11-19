// SECOTO 154 — Parrainage : lien ?parrain=CODE et petites aides d'affichage.
// Le code reçu par lien est gardé dans le navigateur jusqu'à la connexion,
// puis envoyé une seule fois à la base (qui fait tous les contrôles).
const CLE = "secoto:parrain";

export function normaliserCode(code) {
  return String(code || "").toUpperCase().replace(/[^A-Z0-9-]/g, "").slice(0, 24);
}

export function codeDuLien(search) {
  try {
    const c = normaliserCode(new URLSearchParams(search || "").get("parrain"));
    return c.length >= 4 ? c : "";
  } catch { return ""; }
}

export function memoriserCodeLien(search = typeof window !== "undefined" ? window.location.search : "") {
  const c = codeDuLien(search);
  if (c) { try { localStorage.setItem(CLE, c); } catch { /* stockage indisponible */ } }
  return c;
}

export function codeEnAttente() {
  try { return localStorage.getItem(CLE) || ""; } catch { return ""; }
}

export function oublierCodeEnAttente() {
  try { localStorage.removeItem(CLE); } catch { /* ignore */ }
}

export const STATUT_FILLEUL = {
  en_attente: "En attente de son premier transport",
  valide: "Validé : crédit gagné",
  prime_a_verser: "Validé : prime en cours de versement",
  prime_versee: "Prime versée",
  refuse: "Refusé",
};

export function texteInvitation(moi) {
  if (!moi?.code) return "";
  if (moi.type === "transporteur") {
    return `Rejoins SECOTO, la plateforme de missions de transport de véhicules : inscription gratuite, missions près de chez toi, payées après livraison. Mon code parrain : ${moi.code} — ${moi.lien}`;
  }
  return `Pour transporter un véhicule, j'utilise SECOTO : prix immédiat, transporteurs validés. Avec mon code ${moi.code}, tu as ${moi.filleul_eur} € de remise sur ton premier transport : ${moi.lien}`;
}
