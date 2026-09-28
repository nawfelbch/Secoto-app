// ============================================================================
// SECOTO — ecran de l'espace entreprise. On verrouille ici les proprietes
// anti-friction : jamais proposer une action que la base refusera, jamais
// montrer un montant a un convoyeur salarie, jamais perdre une invitation.
// ============================================================================
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const ECRAN = readFileSync(new URL("../src/ondemand/EspaceEntreprise.jsx", import.meta.url), "utf8");
const APP = readFileSync(new URL("../src/App.jsx", import.meta.url), "utf8");

// Le rendu destine au convoyeur salarie, isole du reste du fichier.
const vueEmploye = ECRAN.slice(
  ECRAN.indexOf("  // Employé : ses missions, aucun montant."),
  ECRAN.indexOf("  // Gérant : décisions d'abord"),
);

test("un convoyeur salarie ne voit aucun montant sur cet ecran", () => {
  assert.ok(vueEmploye.length > 200, "la vue employe doit etre isolee correctement");
  for (const interdit of ["euros(", "carrier_pay", "client_price", "comptabilite", "verse_total"]) {
    assert.ok(!vueEmploye.includes(interdit), `la vue employe ne doit pas contenir ${interdit}`);
  }
});

test("on ne propose jamais a un salarie une action que la base refusera", () => {
  // La base refuse qu'un employe soit attribue a une mission. L'ecran ne lui
  // montre donc ni « Accepter » ni « Candidater », mais une suggestion.
  assert.match(APP, /const estConvoyeurSalarie = entreprise\?\.company\?\.role === "member";/);
  assert.match(APP, /\{!isAdmin && estConvoyeurSalarie && \(/);
  assert.match(APP, /Proposer à mon employeur/);
  // Les deux chemins d'acceptation sont explicitement fermes au salarie.
  assert.match(APP, /\{!isAdmin && !estConvoyeurSalarie && flags\?\.direct_accept && \(/);
  assert.match(APP, /\{!isAdmin && !estConvoyeurSalarie && !flags\?\.direct_accept && \(/);
});

test("une invitation survit a l'inscription et ouvre le bon ecran", () => {
  // Meme lecon que le devis client perdu apres creation de compte : le jeton
  // ne peut pas vivre uniquement dans l'URL.
  assert.match(ECRAN, /localStorage\.setItem\(CLE_INVITATION, t\)/);
  assert.match(ECRAN, /localStorage\.getItem\(CLE_INVITATION\)/);
  assert.match(ECRAN, /function oublierInvitation/);
  assert.match(APP, /if \(memoriserInvitation\(\) && account\?\.role === "transporter"\) \{\s*setTransporterTab\("entreprise"\);/);
});

test("le gerant sait qu'on l'attend sans ouvrir l'ecran", () => {
  assert.match(APP, /const decisionsEntreprise = estGerant/);
  assert.match(APP, /count: decisionsEntreprise \|\| undefined/);
});

test("une decision se prend en un seul clic", () => {
  // Retenir une suggestion designe directement le convoyeur : pas d'ecran
  // intermediaire, pas de confirmation.
  assert.match(ECRAN, /Confier à \{s\.employee_name\}/);
  assert.match(ECRAN, /carrierAssignEmployee\(s\.mission_id, s\.employee_id\)/);
  // Designer depuis une mission sans convoyeur : un seul choix dans une liste.
  assert.match(ECRAN, /Désigner un convoyeur…/);
});

test("l'invitation part sans que le convoyeur ait rien a recopier", () => {
  assert.match(ECRAN, /navigator\.clipboard\.writeText\(lienInvitation\(i\.token\)\)/);
  assert.match(ECRAN, /href=\{`sms:\?&body=/);
});

test("la regle des versements est dite au gerant, en clair", () => {
  assert.match(ECRAN, /aucun paiement ne peut lui être versé/i);
  assert.match(ECRAN, /SECOTO ne verse qu’à/);
});
