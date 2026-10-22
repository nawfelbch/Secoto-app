// SECOTO 095 — Supprimer un devis (sans rien effacer) et le restaurer.
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const ECRAN = readFileSync(new URL("../src/ondemand/AdminOnDemand.jsx", import.meta.url), "utf8");
const OD = readFileSync(new URL("../src/lib/onDemand.js", import.meta.url), "utf8");
const SQL = readFileSync(new URL("../supabase/migrations/202610150095_suppression_devis.sql", import.meta.url), "utf8");

test("migration additive : aucune suppression, aucune policy touchée", () => {
  assert.doesNotMatch(SQL, /\bdelete\s+from\b|\bdrop\s|\btruncate\b|alter\s+policy|disable\s+row\s+level/i);
  assert.match(SQL, /add column if not exists supprime_le timestamptz;/);
  assert.match(SQL, /set revoked_at = now\(\)/);
  assert.match(SQL, /déjà une commande/);
  assert.match(SQL, /revoke all on function public\.secoto_admin_quote_supprimer\(uuid, text\) from public, anon;/);
});

test("API admin : supprimer, restaurer, corbeille", () => {
  assert.match(OD, /deleteQuote: \(id, motif = null\) => rpc\("secoto_admin_quote_supprimer", \{ p_quote: id, p_motif: motif \}\)/);
  assert.match(OD, /restoreQuote: \(id\) => rpc\("secoto_admin_quote_restaurer", \{ p_quote: id \}\)/);
  assert.match(OD, /deletedQuotes: \(\) => rpc\("secoto_admin_quotes_supprimes", \{\}\)/);
});

test("écran : bouton sur chaque carte, confirmation dans la carte (pas de fenêtre système), corbeille", () => {
  assert.equal((ECRAN.match(/<SupprimerDevis q=\{q\} busy=\{busy\} run=\{run\} \/>/g) || []).length, 4); // 116 : + « à prévenir » et « date passée »
  assert.match(ECRAN, /Confirmer la suppression/);
  assert.match(ECRAN, /<DevisSupprimes busy=\{busy\} run=\{run\} \/>/);
  const bloc = ECRAN.slice(ECRAN.indexOf("function SupprimerDevis"), ECRAN.indexOf("function AdminQuotes"));
  assert.doesNotMatch(bloc, /window\.(confirm|prompt|alert)/);
});
