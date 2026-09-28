// ============================================================================
// SECOTO 066 — annuler une invitation, retirer un chauffeur. Le point le plus
// sensible : un lien d'invitation envoye par erreur doit pouvoir etre coupe,
// et un compte qui appartient a son titulaire ne doit jamais etre supprime.
// ============================================================================
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const SQL = readFileSync(
  new URL("../supabase/migrations/202609280066_retirer_chauffeur_et_annuler_invitation.sql", import.meta.url),
  "utf8",
);
const FONCTION = readFileSync(new URL("../netlify/functions/carrier-employee.js", import.meta.url), "utf8");
const ECRAN = readFileSync(new URL("../src/ondemand/EspaceEntreprise.jsx", import.meta.url), "utf8");

test("une invitation s'annule, et seulement dans sa propre entreprise", () => {
  assert.match(SQL, /create or replace function public\.secoto_carrier_revoke_invitation\(/);
  assert.match(SQL, /and company_id = v_company\s*\n\s*and status = 'pending'/);
  assert.match(SQL, /Une invitation d''une autre entreprise pourrait etre annulee/);
  assert.match(ECRAN, /carrierRevokeInvitation\(i\.id\)/);
  assert.match(ECRAN, /Le lien déjà envoyé cessera de fonctionner/);
});

test("les garde-fous du retrait restent en place", () => {
  assert.match(SQL, /Designez d''abord un autre compte de versement\./);
  assert.match(SQL, /mission\(s\) en cours : reaffectez-les d''abord\./);
  assert.match(SQL, /Les garde-fous du retrait d''un chauffeur ont disparu/);
});

test("un compte deja ouvert par son titulaire n'est jamais supprime", () => {
  // Double verrou : la base ne declare supprimable qu'un compte dont le mot de
  // passe provisoire n'a jamais ete remplace, et le serveur verifie en plus
  // qu'aucune connexion n'a eu lieu.
  assert.match(SQL, /select coalesce\(a\.must_change_password, false\) into v_jamais_active/);
  assert.match(SQL, /'compte_supprimable', coalesce\(v_jamais_active, false\)/);
  assert.match(FONCTION, /if \(!retrait\?\.compte_supprimable\) return json\(200, \{ removed: true, compte_supprime: false \}\);/);
  assert.match(FONCTION, /if \(u\?\.user\?\.last_sign_in_at\) return json\(200, \{ removed: true, compte_supprime: false \}\);/);
});

test("le retrait est confirme, en disant ce qui va se passer", () => {
  assert.match(ECRAN, /Retirer \$\{x\.name\} de \$\{company\.name\} \?/);
  assert.match(ECRAN, /S’il n’a jamais ouvert son compte, celui-ci sera supprimé/);
});

test("le gerant voit que le lien reste valable tant qu'il n'annule pas", () => {
  assert.match(ECRAN, /Invitations en attente\. Tant qu’elles ne sont pas annulées/);
});
