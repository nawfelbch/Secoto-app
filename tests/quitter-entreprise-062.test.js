// ============================================================================
// SECOTO 062 — quitter ou dissoudre une entreprise. Une entreprise n'est
// jamais supprimee : elle est archivee, pour que la comptabilite et la
// tracabilite des versements survivent a sa fermeture.
// ============================================================================
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const SQL = readFileSync(
  new URL("../supabase/migrations/202609280062_quitter_ou_dissoudre_entreprise.sql", import.meta.url),
  "utf8",
);
const ECRAN = readFileSync(new URL("../src/ondemand/EspaceEntreprise.jsx", import.meta.url), "utf8");

test("une entreprise fermee est archivee, jamais supprimee", () => {
  assert.match(SQL, /add column if not exists archived_at timestamptz/);
  assert.match(SQL, /set archived_at = now\(\), payout_account_id = null/);
  // La ligne survit : les missions passees gardent leur rattachement.
  assert.doesNotMatch(SQL, /delete from public\.business_accounts/);
});

test("une entreprise archivee n'existe plus pour aucune des quatre fonctions", () => {
  // Sans cela, ses anciens membres resteraient prisonniers, et le declencheur
  // continuerait de rediriger leurs versements vers une societe fermee.
  for (const f of ["carrier_of", "is_carrier_owner", "trg_carrier_payee", "trg_carrier_payee_order"]) {
    assert.match(SQL, new RegExp(`create or replace function secoto_private\\.${f}\\(`));
  }
  const occurrences = (SQL.match(/archived_at is null/g) || []).length;
  assert.ok(occurrences >= 4, `attendu au moins 4 filtres d'archivage, trouve ${occurrences}`);
  assert.match(SQL, /ignore encore l''archivage des entreprises/);
});

test("on ne part pas en laissant des missions en cours", () => {
  assert.match(SQL, /mission\(s\) en cours : terminez-les ou faites-les reaffecter avant de partir/);
  assert.match(SQL, /mission\(s\) en cours : elles doivent etre terminees ou annulees avant la dissolution/);
});

test("une entreprise ne peut pas se retrouver sans gerant ni sans compte de versement", () => {
  assert.match(SQL, /Vous etes le seul gerant : nommez un autre gerant, ou dissolvez l''entreprise\./);
  assert.match(SQL, /Vous recevez les versements de l''entreprise : designez d''abord un autre gerant/);
  // Les versements ne peuvent etre confies qu'a un gerant.
  assert.match(SQL, /Les versements ne peuvent aller qu''a un gerant de l''entreprise\./);
});

test("une invitation emise avant la fermeture devient inutilisable", () => {
  assert.match(SQL, /Cette entreprise n''existe plus\./);
  assert.match(SQL, /update public\.carrier_invitations\s+set status = 'revoked'/);
});

test("l'ecran offre la sortie aux deux roles", () => {
  // Un convoyeur depuis sa propre vue, un gerant depuis la sienne.
  assert.ok((ECRAN.match(/Quitter l’entreprise/g) || []).length >= 2);
  assert.match(ECRAN, /Fermer l’entreprise/);
  assert.match(ECRAN, /Lui confier les versements/);
  // Fermer est irreversible pour l'equipe : on demande confirmation.
  assert.match(ECRAN, /window\.confirm\(/);
});
