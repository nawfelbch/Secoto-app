// SECOTO 087 — Espace dirigeant : calculs purs (périodes, montants).
// Aucune dépendance au client Supabase : testable tel quel.

export const MOIS = Object.freeze([
  "janvier", "février", "mars", "avril", "mai", "juin",
  "juillet", "août", "septembre", "octobre", "novembre", "décembre",
]);

const pad = (n) => String(n).padStart(2, "0");
const iso = (annee, mois) => `${annee}-${pad(mois)}-01`; // mois de 1 à 12

/** Période d'un mois (début inclus, fin exclue). */
export function periodeMois(annee, mois) {
  const finAnnee = mois === 12 ? annee + 1 : annee;
  const finMois = mois === 12 ? 1 : mois + 1;
  return {
    rythme: "mois", annee, index: mois,
    debut: iso(annee, mois), fin: iso(finAnnee, finMois),
    label: `${MOIS[mois - 1].charAt(0).toUpperCase()}${MOIS[mois - 1].slice(1)} ${annee}`,
  };
}

/** Période d'un trimestre (1 à 4). */
export function periodeTrimestre(annee, t) {
  const premier = (t - 1) * 3 + 1;
  const fin = t === 4 ? iso(annee + 1, 1) : iso(annee, premier + 3);
  return {
    rythme: "trimestre", annee, index: t,
    debut: iso(annee, premier), fin,
    label: `${t === 1 ? "1er" : `${t}e`} trimestre ${annee}`,
    detail: `${MOIS[premier - 1]} à ${MOIS[premier + 1]}`,
  };
}

/**
 * La période à déclarer maintenant : la dernière période terminée
 * (le mois dernier, ou le trimestre dernier).
 */
export function periodeADeclarer(rythme, date = new Date()) {
  const annee = date.getFullYear();
  const mois = date.getMonth() + 1;
  if (rythme === "trimestre") {
    const t = Math.floor((mois - 1) / 3) + 1;
    return t === 1 ? periodeTrimestre(annee - 1, 4) : periodeTrimestre(annee, t - 1);
  }
  return mois === 1 ? periodeMois(annee - 1, 12) : periodeMois(annee, mois - 1);
}

/** Période précédente (-1) ou suivante (+1). */
export function decaler(periode, sens) {
  if (periode.rythme === "trimestre") {
    let { annee, index } = periode;
    index += sens;
    if (index < 1) { index = 4; annee -= 1; }
    if (index > 4) { index = 1; annee += 1; }
    return periodeTrimestre(annee, index);
  }
  let { annee, index } = periode;
  index += sens;
  if (index < 1) { index = 12; annee -= 1; }
  if (index > 12) { index = 1; annee += 1; }
  return periodeMois(annee, index);
}

/** La période n'est pas encore terminée : le montant peut encore bouger. */
export function periodeEnCours(periode, date = new Date()) {
  const aujourdHui = `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())}`;
  return aujourdHui < periode.fin;
}

/** Montant comptable : toujours deux décimales, espace des milliers. */
export function euros(cents) {
  const n = Number(cents);
  if (!Number.isFinite(n)) return "—";
  return (n / 100).toLocaleString("fr-FR", { style: "currency", currency: "EUR", minimumFractionDigits: 2, maximumFractionDigits: 2 });
}

/** Montant arrondi à l'euro, comme le demande l'URSSAF. */
export function eurosEntiers(valeur) {
  const n = Number(valeur);
  if (!Number.isFinite(n)) return "—";
  return n.toLocaleString("fr-FR", { style: "currency", currency: "EUR", minimumFractionDigits: 0, maximumFractionDigits: 0 });
}

export function dateCourte(value) {
  if (!value) return "—";
  const d = new Date(value);
  if (Number.isNaN(d.getTime())) return "—";
  return d.toLocaleDateString("fr-FR", { day: "2-digit", month: "2-digit", year: "numeric" });
}

/** Totaux de l'année à partir des 12 mois renvoyés par la base. */
export function totauxAnnee(mois = []) {
  return mois.reduce((t, m) => ({
    encaisse: t.encaisse + Number(m.encaisse_cents || 0),
    reverse: t.reverse + Number(m.reverse_cents || 0),
    rembourse: t.rembourse + Number(m.rembourse_cents || 0),
    commission: t.commission + Number(m.commission_cents || 0),
    operations: t.operations + Number(m.operations || 0),
  }), { encaisse: 0, reverse: 0, rembourse: 0, commission: 0, operations: 0 });
}

/** Période des N derniers jours, aujourd'hui inclus (fin exclue = demain). */
export function derniersJours(n, maintenant = new Date()) {
  const iso = (d) => `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;
  const fin = new Date(maintenant.getFullYear(), maintenant.getMonth(), maintenant.getDate() + 1);
  const debut = new Date(fin.getFullYear(), fin.getMonth(), fin.getDate() - n);
  return { debut: iso(debut), fin: iso(fin) };
}
