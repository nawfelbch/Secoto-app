// SECOTO 097 puis 123 — Immatriculation de SECOTO.
// 16/10/2026 (097) : numéro retiré partout, mention « Immatriculation en cours
// de mise à jour ». 30/10/2026 (123) : Kbis de nouveau valide — le SIRET
// 951 857 531 00028 (RCS Nanterre) revient sur tous les supports.
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync, readdirSync, statSync } from "node:fs";
import { join } from "node:path";

const RACINE = new URL("..", import.meta.url).pathname;
const DOSSIERS = ["src", "public", "templates", "netlify", "deliverables/secoto-kit-commercial/sources", "index.html"];
const SUPPORTS = ["templates/devis.html", "templates/facture.html", "templates/bon-de-mission.html",
  "public/cgu.html", "public/politique-confidentialite.html", "public/conditions-transporteur.html",
  "public/verifications.html", "src/LegalNoticesPanel.jsx"];

function fichiers(chemin) {
  const abs = join(RACINE, chemin);
  if (statSync(abs).isFile()) return [chemin];
  return readdirSync(abs).flatMap((n) => fichiers(join(chemin, n)));
}

test("123 : plus aucune mention provisoire sur les supports", () => {
  const texte = /\.(jsx?|mjs|html|css|json|txt|md|svg|toml)$/;
  const trouves = DOSSIERS.flatMap(fichiers).filter((f) => texte.test(f))
    .filter((f) => /[Ii]mmatriculation en cours de mise à jour/.test(readFileSync(join(RACINE, f), "utf8")));
  assert.deepEqual(trouves, []);
});

test("123 : le SIRET et le RCS figurent sur les documents et pages légales", () => {
  for (const f of SUPPORTS) {
    assert.match(readFileSync(join(RACINE, f), "utf8"), /SIRET 951 857 531 00028 · RCS Nanterre/, f);
  }
});

test("123 : base — factures automatiques, maquettes et garde-fou 097 retiré, rien de supprimé", () => {
  const sql = readFileSync(join(RACINE, "supabase/migrations/202610300123_siret_actif.sql"), "utf8");
  assert.match(sql, /od_issue_direct_invoices/);
  assert.match(sql, /SIRET 951 857 531 00028 - RCS Nanterre/);
  assert.match(sql, /values \(p_kind, \/\* 123 \*\/ p_html, now\(\)\)/);
  assert.doesNotMatch(sql, /\bdelete\s+from\b|\bdrop\s|\btruncate\b|alter\s+policy/i);
  const s097 = readFileSync(join(RACINE, "supabase/migrations/202610160097_immatriculation_en_cours.sql"), "utf8");
  assert.match(s097, /sauvegarde_097_doc_templates/);
});
