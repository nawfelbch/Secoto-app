// ============================================================================
// SECOTO 063 — une societe de transport doit pouvoir se declarer des son
// inscription, sans attendre d'etre verifiee et sans decouvrir l'ecran apres
// coup. La verification reste exigee la ou elle protege : l'acceptation d'une
// mission.
// ============================================================================
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const SQL = readFileSync(
  new URL("../supabase/migrations/202609280063_creer_entreprise_des_inscription.sql", import.meta.url),
  "utf8",
);
const ECRAN = readFileSync(new URL("../src/ondemand/EspaceEntreprise.jsx", import.meta.url), "utf8");
const APP = readFileSync(new URL("../src/App.jsx", import.meta.url), "utf8");

test("creer une entreprise n'exige plus un compte verifie", () => {
  // On regarde le CORPS de la fonction, pas le fichier : le controle, lui,
  // cite volontairement is_verified_transporter pour refuser son retour.
  const corps = SQL.slice(
    SQL.indexOf("create or replace function public.secoto_carrier_create"),
    SQL.indexOf("revoke all on function public.secoto_carrier_create"),
  );
  assert.doesNotMatch(corps, /is_verified_transporter/);
  assert.match(corps, /a\.role::text in \('transporter', 'admin'\)/);
  assert.match(SQL, /La creation d''entreprise exige encore un compte verifie/);
});

test("mais accepter une mission reste verrouille", () => {
  // Le controle de la migration refuse de passer si ce verrou a saute.
  assert.match(SQL, /Le verrou sur l''acceptation des missions a disparu/);
});

test("l'inscription propose l'entreprise, aux seules entreprises de plateau", () => {
  // Un convoyeur conduit lui-meme le vehicule : il n'a pas d'equipe. Le modele
  // employeur ne vaut que pour le transport sur plateau, VL ou PL.
  assert.match(APP, /J’emploie des chauffeurs/);
  assert.match(APP, /\{\["vl", "pl"\]\.includes\(transporterType\) && \(\s*<label className="preference-card"/);
  assert.match(APP, /memoriserCreationEntreprise\(companyName\);/);
  assert.match(APP, /effectiveRole === "transporter" && emploieDesConvoyeurs\s*\n?\s*&& \["vl", "pl"\]\.includes\(transporterType\)/);
});

test("l'intention survit a l'inscription et ouvre l'ecran", () => {
  // Meme mecanique que l'invitation : ni l'un ni l'autre ne peut se perdre
  // entre la creation du compte et la premiere connexion.
  assert.match(ECRAN, /export function memoriserCreationEntreprise/);
  assert.match(ECRAN, /export function ouvertureEntrepriseDemandee/);
  assert.match(APP, /if \(ouvertureEntrepriseDemandee\(\) && account\?\.role === "transporter"\)/);
});

test("le nom d'entreprise est deja rempli, il ne reste qu'a confirmer", () => {
  assert.match(ECRAN, /if \(attendu\) setNom\(\(n\) => n \|\| attendu\);/);
  assert.match(ECRAN, /c’est la dernière étape/);
  assert.match(ECRAN, /if \(r\) oublierCreation\(\);/);
});
