// SECOTO 097 — Aucun numéro SIREN / SIRET de SECOTO sur un support client
// tant que la nouvelle immatriculation n'est pas active.
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync, readdirSync, statSync } from "node:fs";
import { join } from "node:path";

const RACINE = new URL("..", import.meta.url).pathname;
const NUMERO = /951[\s. -]?857[\s. -]?531|95185753100028/;
// Tout ce qui part chez le client, le transporteur ou le prospect.
const DOSSIERS = ["src", "public", "templates", "netlify", "deliverables/secoto-kit-commercial/sources", "index.html"];

function fichiers(chemin) {
  const abs = join(RACINE, chemin);
  if (statSync(abs).isFile()) return [chemin];
  return readdirSync(abs).flatMap((n) => fichiers(join(chemin, n)));
}

test("aucun support ne contient l'ancien numéro", () => {
  const texte = /\.(jsx?|mjs|html|css|json|txt|md|svg|toml)$/;
  const trouves = DOSSIERS.flatMap(fichiers).filter((f) => texte.test(f))
    .filter((f) => NUMERO.test(readFileSync(join(RACINE, f), "utf8")));
  assert.deepEqual(trouves, []);
});

test("la mention remplace le numéro sur les documents et pages légales", () => {
  for (const f of ["templates/devis.html", "templates/facture.html", "templates/bon-de-mission.html",
    "public/cgu.html", "public/politique-confidentialite.html", "public/conditions-transporteur.html", "src/LegalNoticesPanel.jsx"]) {
    assert.match(readFileSync(join(RACINE, f), "utf8"), /[Ii]mmatriculation en cours de mise à jour/, f);
  }
});

test("migration 097 : factures automatiques et maquettes en base, rien de supprimé", () => {
  const sql = readFileSync(join(RACINE, "supabase/migrations/202610160097_immatriculation_en_cours.sql"), "utf8");
  assert.match(sql, /od_issue_direct_invoices/);
  assert.match(sql, /sauvegarde_097_doc_templates/);
  assert.doesNotMatch(sql, /\bdelete\s+from\b|\bdrop\s|\btruncate\b|alter\s+policy/i);
});
