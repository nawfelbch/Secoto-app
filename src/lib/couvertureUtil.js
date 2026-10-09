// SECOTO 088 — Couverture d'un transporteur : départements et moto (calculs purs).

/** Départements de métropole et de Corse, dans l'ordre (01 … 19, 2A, 2B, 21 … 95). */
export const DEPARTEMENTS = Object.freeze([
  ...Array.from({ length: 19 }, (_, i) => String(i + 1).padStart(2, "0")),
  "2A", "2B",
  ...Array.from({ length: 75 }, (_, i) => String(i + 21)),
]);

export const RACCOURCIS = Object.freeze([
  { key: "idf", label: "Île-de-France", deps: ["75", "77", "78", "91", "92", "93", "94", "95"] },
  { key: "azur", label: "Côte d’Azur", deps: ["06", "83"] },
]);

/** Ajoute ou retire un département ; résultat trié dans l'ordre officiel. */
export function basculer(liste, dep) {
  const set = new Set(liste || []);
  if (set.has(dep)) set.delete(dep); else set.add(dep);
  return DEPARTEMENTS.filter((d) => set.has(d));
}

/** Raccourci : s'il est déjà entièrement coché, on le retire ; sinon on l'ajoute. */
export function appliquerRaccourci(liste, deps) {
  const set = new Set(liste || []);
  const complet = deps.every((d) => set.has(d));
  for (const d of deps) { if (complet) set.delete(d); else set.add(d); }
  return DEPARTEMENTS.filter((d) => set.has(d));
}

export function resumeDepartements(liste) {
  const n = (liste || []).length;
  if (n === 0) return "Aucun département choisi";
  if (n === DEPARTEMENTS.length) return "Toute la France";
  return `${n} département${n > 1 ? "s" : ""} : ${liste.slice(0, 12).join(", ")}${n > 12 ? "…" : ""}`;
}
