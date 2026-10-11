// SECOTO 089 — règles pures de la recherche d'adresse (testables sans navigateur).

// En dessous de ce score, la Base Adresse Nationale « devine » : l'adresse
// tapée est probablement à l'étranger.
export const SCORE_FRANCE_SUR = 0.6;

export function doitChercherEtranger(q, itemsFrance, horsFrance) {
  if (horsFrance) return true;
  if (String(q || "").trim().length < 5) return false;
  return !(itemsFrance || []).some((i) => Number(i.score) >= SCORE_FRANCE_SUR);
}

const NOMS_PAYS = (() => {
  try { return new Intl.DisplayNames(["fr"], { type: "region" }); } catch { return null; }
})();
export function nomPays(code) {
  if (!code || code === "FR") return "";
  try { return NOMS_PAYS?.of(code) || code; } catch { return code; }
}
