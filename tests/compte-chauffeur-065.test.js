// ============================================================================
// SECOTO 065 — un gerant fait creer le compte d'un chauffeur, avec un mot de
// passe provisoire. Ce que ces tests protegent : un mot de passe connu d'un
// tiers ne doit jamais rester actif, ni donner acces a quoi que ce soit.
// ============================================================================
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const SQL = readFileSync(
  new URL("../supabase/migrations/202609280065_compte_chauffeur_cree_par_le_gerant.sql", import.meta.url),
  "utf8",
);
const FONCTION = readFileSync(new URL("../netlify/functions/carrier-employee.js", import.meta.url), "utf8");
const APP = readFileSync(new URL("../src/App.jsx", import.meta.url), "utf8");
const GARDE = readFileSync(new URL("../src/MotDePasseProvisoire.jsx", import.meta.url), "utf8");
const ECRAN = readFileSync(new URL("../src/ondemand/EspaceEntreprise.jsx", import.meta.url), "utf8");

const { motDePasseProvisoire } = await import("../netlify/functions/carrier-employee.js");

test("le mot de passe provisoire donne acces a RIEN d'autre", () => {
  // Le garde est pose avant tout le reste de l'application, pas dans un onglet.
  assert.match(APP, /if \(account\.mustChangePassword\) \{\s*\n\s*return \(\s*\n\s*<MotDePasseProvisoire/);
  const avant = APP.indexOf("if (account.mustChangePassword)");
  const apres = APP.indexOf('const isAdmin = account.role === "admin";');
  assert.ok(avant > 0 && avant < apres, "le garde doit preceder le rendu de l'application");
});

test("seul le chauffeur peut lever le drapeau, sur son propre compte", () => {
  assert.match(SQL, /update public\.accounts\s*\n\s*set must_change_password = false\s*\n\s*where id = v_user;/);
  assert.match(SQL, /pourrait lever le drapeau d''un autre compte/);
});

test("le rattachement reste hors de portee de l'application", () => {
  // Sinon n'importe quel compte authentifie pourrait s'attribuer un chauffeur.
  assert.match(SQL, /revoke all on function public\.secoto_carrier_attach_employee\(uuid, uuid\)\s*\n\s*from public, anon, authenticated;/);
  assert.match(SQL, /est appelable depuis l''application/);
});

test("le serveur verifie le droit en base, pas dans son code", () => {
  assert.match(FONCTION, /rpc\("secoto_carrier_overview"/);
  assert.match(FONCTION, /vue\?\.company\?\.role !== "owner"/);
  assert.match(FONCTION, /reserve_aux_gerants/);
});

test("un compte existant n'est jamais touche", () => {
  assert.match(FONCTION, /\.from\("accounts"\)\.select\("id"\)\.eq\("email", email\)/);
  assert.match(FONCTION, /return json\(200, \{ existe: true, email \}\);/);
  assert.match(ECRAN, /if \(r\.existe\) \{/);
  assert.match(ECRAN, /déjà un compte SECOTO/);
});

test("un rattachement rate ne laisse pas de compte orphelin", () => {
  assert.match(FONCTION, /admin\.auth\.admin\.deleteUser\(cree\.user\.id\)/);
});

test("le mot de passe provisoire est lisible au telephone et sans ambiguite", () => {
  const mdp = motDePasseProvisoire();
  assert.match(mdp, /^[A-Z2-9]{4}-[A-Z2-9]{4}-[A-Z2-9]{4}$/);
  // Ni O/0 ni I/l/1 : ces caracteres se confondent a l'oral comme a l'ecrit.
  assert.doesNotMatch(mdp, /[OI01L]/);
  const tire = new Set(Array.from({ length: 200 }, () => motDePasseProvisoire()));
  assert.ok(tire.size > 190, "les mots de passe doivent etre imprevisibles");
});

test("l'ecran de changement n'offre qu'une seule action", () => {
  assert.match(GARDE, /supabase\.auth\.updateUser\(\{ password: motDePasse \}\)/);
  assert.match(GARDE, /await passwordChanged\(\);/);
  assert.match(GARDE, /disabled=\{busy \|\| motDePasse\.length < 8\}/);
});
