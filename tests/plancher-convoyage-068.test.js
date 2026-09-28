// ============================================================================
// SECOTO 068 — premier prix du convoyage a 60 EUR.
//
// Le test le plus important porte sur le piege rencontre en production : le nom
// « partner_minimum_eur » existe deja dans la branche historique de
// price_with_grid, si bien qu'un garde naif conclut que la fonction est deja
// patchee et la saute en silence — le prix client baisse, la remuneration non.
// ============================================================================
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const SQL = readFileSync(
  new URL("../supabase/migrations/202609280068_plancher_convoyage_60.sql", import.meta.url),
  "utf8",
);
const BAREME = readFileSync(
  new URL("../supabase/migrations/202609180034_bareme_secoto_2026.sql", import.meta.url),
  "utf8",
);

test("le nom du parametre existe deja ailleurs : le garde ne peut pas s'y fier", () => {
  // C'est la cause reelle de l'echec en production, on la documente par un test.
  assert.match(BAREME, /coalesce\(\(p ->> 'partner_minimum_eur'\)::numeric, 0\)/);
  // Le garde de la migration porte donc sur l'expression complete.
  assert.match(SQL, /if position\(v_patch in v_src\) = 0 then/);
  assert.doesNotMatch(SQL, /if position\('partner_minimum_eur' in v_src\) > 0 then/);
});

test("le patch est verifie en appelant reellement la fonction", () => {
  // Une grille d'essai, un appel, un montant attendu : un patch saute ne peut
  // plus passer inapercu.
  assert.match(SQL, /v_essai := secoto_private\.price_with_grid\(/);
  assert.match(SQL, /if \(v_essai ->> 'partner_cents'\)::int <> 1200 then/);
  assert.match(SQL, /price_with_grid ignore le plancher de remuneration/);
});

test("le plancher client passe a 60 EUR et le convoyeur a 12 EUR", () => {
  assert.match(SQL, /jsonb_build_object\('minimum_eur', 60, 'partner_minimum_eur', 12\)/);
});

test("les montants attendus sont controles a l'application", () => {
  for (const [montant, cas] of [
    ["6000", "client au plancher"],
    ["1200", "convoyeur au plancher, 10 km"],
    ["2200", "convoyeur a 40 km"],
    ["3300", "convoyeur a 60 km, fin du forfait"],
    ["4400", "convoyeur a 80 km"],
    ["1300", "utilitaire au plancher"],
  ]) {
    assert.ok(SQL.includes(montant), `le controle doit verifier ${cas} : ${montant}`);
  }
});

test("le plateau est explicitement protege", () => {
  assert.match(SQL, /Le plancher plateau a ete modifie alors qu''il ne devait pas l''etre/);
  assert.match(SQL, /Un plancher de remuneration a ete pose sur le plateau par erreur/);
  assert.match(SQL, /Plateau voiture 500 km/);
});
