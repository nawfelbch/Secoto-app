// SECOTO — Liste admin des devis déjà tarifés.
// ----------------------------------------------------------------------------
// Tous les devis tarifés encore valides restent accessibles (avant : 12 au
// plus, les plus anciens disparaissaient de l'écran alors que leur lien de
// paiement marchait toujours). Une recherche retrouve un devis par ville,
// nom, téléphone ou e-mail.

export const DEVIS_AFFICHES = 12;

export function devisTarifesValides(quotes, maintenant = new Date()) {
  return (quotes || []).filter(
    (q) => q.status === "priced" && (!q.valid_until || new Date(q.valid_until) > maintenant),
  );
}

const texte = (v) =>
  String(v || "")
    .normalize("NFD")
    .replace(/[̀-ͯ]/g, "")
    .toLowerCase();

// 06 86 66 52 86, +33 6 86 66 52 86 et 0686665286 doivent se retrouver.
export function chiffresTelephone(v) {
  const d = String(v || "").replace(/\D/g, "");
  if (d.startsWith("0033")) return `0${d.slice(4)}`;
  if (d.startsWith("33") && d.length === 11) return `0${d.slice(2)}`;
  return d;
}

export function filtrerDevis(liste, recherche) {
  const r = texte(recherche).trim();
  if (!r) return liste || [];
  const mots = r.split(/\s+/);
  const chiffres = chiffresTelephone(recherche);
  return (liste || []).filter((q) => {
    const tel = chiffresTelephone(q.client_phone);
    if (chiffres.length >= 4 && /^[\d\s+.()-]+$/.test(recherche.trim()) && tel.includes(chiffres)) return true;
    const botte = texte([q.pickup?.city, q.delivery?.city, q.client_name, q.client_email, tel].join(" "));
    return mots.every((m) => botte.includes(m));
  });
}
