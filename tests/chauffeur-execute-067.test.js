// ============================================================================
// SECOTO 067 — le chauffeur execute, l'entreprise encaisse.
//
// La 060 faisait du gerant le titulaire de la mission : le chauffeur n'existait
// pour aucune des regles de terrain. Ces tests verrouillent la correction et
// s'assurent qu'elle n'a pas ouvert la porte des versements.
// ============================================================================
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const SQL = readFileSync(
  new URL("../supabase/migrations/202609280067_le_chauffeur_execute_l_entreprise_encaisse.sql", import.meta.url),
  "utf8",
);
const APP = readFileSync(new URL("../src/App.jsx", import.meta.url), "utf8");
const MAPPERS = readFileSync(new URL("../src/lib/mappers.js", import.meta.url), "utf8");

test("le titulaire de la mission redevient celui qui la fait", () => {
  // Sans cela, rien du terrain ne reconnait le chauffeur : ni les vues, ni la
  // RLS, ni l'etat des lieux, ni les photos, ni le suivi.
  assert.match(SQL, /assigned_transporter_id = v_cible/);
  assert.match(SQL, /L''affectation redirige encore le titulaire de la mission/);
});

test("mais le versement, lui, vise l'entreprise", () => {
  assert.match(SQL, /create or replace function secoto_private\.beneficiaire_mission\(/);
  assert.match(SQL, /coalesce\(secoto_private\.beneficiaire_mission\(new\.id\), new\.assigned_transporter_id\)/);
  assert.match(SQL, /Le versement d''une mission d''entreprise ne vise pas l''entreprise/);
});

test("un chauffeur ne peut toujours pas prendre une mission de lui-meme", () => {
  // La regle n'est pas supprimee, elle est deplacee : seul un gerant pose le
  // drapeau de designation, le temps d'une transaction.
  assert.match(SQL, /if v_role <> 'owner' and not secoto_private\.designation_en_cours\(\) then/);
  assert.match(SQL, /Seul un gerant peut accepter une mission pour son entreprise\./);
  assert.match(SQL, /perform set_config\('secoto\.designation', 'on', true\);/);
  assert.match(SQL, /Un chauffeur pourrait accepter une mission de lui-meme/);
});

test("le chauffeur salarie ne voit toujours aucun montant", () => {
  // Il est desormais titulaire : la vue ne peut plus se fier a ce seul critere.
  assert.match(SQL, /and secoto_private\.carrier_of\(auth\.uid\(\)\) is null\)\s*\n\s*then m\.carrier_cost end/);
  assert.match(SQL, /and secoto_private\.carrier_of\(auth\.uid\(\)\) is null\)\s*\n\s*then m\.carrier_pay end/);
});

test("le gerant suit les missions de son equipe sans avoir a les executer", () => {
  assert.match(APP, /const missionsSuiviesEntreprise = useMemo\(/);
  assert.match(APP, /m\.carrierCompanyId\s*\n\s*&& m\.assignedTransporterId !== account\?\.id/);
  assert.match(APP, /Confiées à mon équipe/);
});

test("la direction voit a quelle entreprise un transporteur est rattache", () => {
  assert.match(SQL, /create or replace function public\.secoto_admin_carrier_members\(/);
  assert.match(APP, /rattachements\[transporter\.id\]\.role === "owner" \? "Gérant de " : "Chauffeur chez "/);
  assert.match(APP, /reçoit les versements/);
});

test("les missions portent leur entreprise et leur executant cote client", () => {
  assert.match(APP, /"carrier_company_id", "carrier_employee_id",/);
  assert.match(MAPPERS, /carrierCompanyId: row\.carrier_company_id \|\| null,/);
  assert.match(MAPPERS, /carrierEmployeeId: row\.carrier_employee_id \|\| null,/);
});
