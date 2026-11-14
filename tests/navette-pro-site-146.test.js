import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const lire = (p) => readFileSync(new URL(`../${p}`, import.meta.url), "utf8");
const sql = lire("supabase/migrations/202611140146_navette_pro_site.sql");

test("146 : le site reçoit les prix client Navette Pro, jamais la rémunération transporteur", () => {
  assert.match(sql, /'navette_pro', \(select jsonb_build_object\(/);
  for (const k of ["'voiture_1'", "'voiture_par_vehicule_2_plus'", "'grand_1'", "'grand_par_vehicule_2_plus'"]) assert.ok(sql.includes(k), k);
  assert.doesNotMatch(sql, /'transporteur_eur', \(a/);
  assert.match(sql, /array\['bareme_v3', 'trois_offres', 'navette_pro'\]/);
  assert.match(sql, /bareme_v3_public_rafraichir\(\)/);
});

test("146 : lien « Créer mon compte pro » du site — inscription, profil Professionnel déjà choisi", () => {
  const app = lire("src/App.jsx");
  assert.match(app, /get\("compte"\) === "pro"/);
  assert.match(app, /useState\(\(\) => \(lienComptePro\(\) \? "pro" : "particulier"\)\)/);
  assert.match(app, /lienComptePro\(\) \? \{ mode: "signup" \} : null/);
});
