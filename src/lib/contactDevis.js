// SECOTO 090 — Contact demandé juste avant le prix (visiteur sans compte).
// Règles pures, testables sans navigateur, identiques à la base
// (secoto_private.tel_propre) : un numéro valide ici l'est aussi là-bas.

const CLE = "secoto:contact-devis";

/** Numéro normalisé au format international (+33…), ou null s'il est invalide. */
export function telephonePropre(valeur) {
  const v = String(valeur || "").replace(/[\s.\-()/]/g, "");
  if (/^0[1-9]\d{8}$/.test(v)) return `+33${v.slice(1)}`;
  if (/^0033[1-9]\d{8}$/.test(v)) return `+${v.slice(2)}`;
  if (/^\+33[1-9]\d{8}$/.test(v)) return v;
  if (/^\+[1-9]\d{7,14}$/.test(v)) return v;
  return null;
}

export function emailPropre(valeur) {
  const v = String(valeur || "").trim().toLowerCase();
  return v.length <= 254 && /^[^\s@<>]+@[^\s@<>]+\.[^\s@<>]{2,}$/.test(v) ? v : null;
}

/** Au moins un des deux, valide. Renvoie { phone, email } ou null. */
export function contactValide({ phone = "", email = "" } = {}) {
  const tel = telephonePropre(phone);
  const mail = emailPropre(email);
  if (!tel && !mail) return null;
  return { phone: tel, email: mail };
}

/** Message d'aide, ou "" si le contact est bon. Jamais d'erreur avant la saisie. */
export function aideContact({ phone = "", email = "" } = {}, mode = "telephone") {
  if (mode === "telephone") {
    if (!String(phone).trim()) return "";
    return telephonePropre(phone) ? "" : "Vérifiez le numéro (exemple : 06 12 34 56 78).";
  }
  if (!String(email).trim()) return "";
  return emailPropre(email) ? "" : "Vérifiez l’adresse e-mail.";
}

// Gardé sur l'appareil pour ne pas le redemander au prochain devis, et pour
// pré-remplir la création de compte. Jamais bloquant si le stockage manque.
export function contactMemorise() {
  try {
    const v = JSON.parse(window.localStorage.getItem(CLE) || "null");
    return v && typeof v === "object" ? { phone: String(v.phone || ""), email: String(v.email || "") } : null;
  } catch {
    return null;
  }
}
export function memoriserContact(contact) {
  try { window.localStorage.setItem(CLE, JSON.stringify({ phone: contact?.phone || "", email: contact?.email || "" })); } catch { /* indisponible */ }
}

/** Affichage lisible d'un numéro français : +33612345678 → 06 12 34 56 78. */
export function telephoneLisible(tel) {
  const v = String(tel || "");
  if (/^\+33[1-9]\d{8}$/.test(v)) return `0${v.slice(3)}`.replace(/(\d{2})(?=\d)/g, "$1 ").trim();
  return v;
}
