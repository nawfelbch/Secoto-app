// ============================================================================
// SECOTO 064 — deux frictions relevees en conditions reelles : un lien
// d'invitation inutilisable depuis l'app iOS, et un numero d'entreprise refuse
// sans explication.
// ============================================================================
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const ECRAN = readFileSync(new URL("../src/ondemand/EspaceEntreprise.jsx", import.meta.url), "utf8");
const SQL = readFileSync(
  new URL("../supabase/migrations/202609280064_siren_message_clair.sql", import.meta.url),
  "utf8",
);

test("le lien d'invitation ne depend jamais de l'origine courante", () => {
  // Dans l'app iOS l'origine vaut capacitor://localhost : un SMS parti de la
  // n'est cliquable par personne.
  assert.match(ECRAN, /const WEB_APP_URL = "https:\/\/app\.secoto-transport\.fr";/);
  assert.match(ECRAN, /const lienInvitation = \(token\) =>\s*\n?\s*`\$\{WEB_APP_URL\}\/\?invitation=/);
  const fabrique = ECRAN.slice(ECRAN.indexOf("const lienInvitation"), ECRAN.indexOf("const CLE_INVITATION"));
  assert.doesNotMatch(fabrique, /window\.location\.origin/);
});

test("un numero d'entreprise invalide dit ce qui ne va pas", () => {
  assert.match(SQL, /Le SIREN comporte 9 chiffres, le SIRET 14\. Vous en avez saisi %/);
  assert.match(SQL, /Le numero d''entreprise est encore refuse sans explication/);
});

test("le SIRET est accepte, puisque c'est le numero qu'on a sous la main", () => {
  assert.match(SQL, /elsif length\(v_chiffres\) = 14 then\s*\n\s*v_siren := left\(v_chiffres, 9\);/);
  assert.match(SQL, /Le SIRET n''est pas accepte/);
});

test("le champ empeche la saisie invalide avant meme l'envoi", () => {
  assert.match(ECRAN, /maxLength=\{14\}/);
  assert.match(ECRAN, /replace\(\/\\D\/g, ""\)\.slice\(0, 14\)/);
  assert.match(ECRAN, /il en faut 9 \(SIREN\) ou 14 \(SIRET\)/);
});
