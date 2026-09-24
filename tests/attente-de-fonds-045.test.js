// Migration 045 — attendre les fonds n'est pas un échec.
// Stripe libère les fonds 3 jours ouvrés après le paiement, alors que SECOTO
// verse le transporteur 48 h après la livraison : sans cette règle, un
// versement légitime finissait « en échec » par simple attente.
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const SQL45 = readFileSync(new URL("../supabase/migrations/202609240045_attente_de_fonds.sql", import.meta.url), "utf8");
const MAINT = readFileSync(new URL("../netlify/functions/od-maintenance.js", import.meta.url), "utf8");
const COPY = readFileSync(new URL("../src/lib/orderCopy.js", import.meta.url), "utf8");

test("une attente de fonds ne consomme pas d'essai", () => {
  assert.match(SQL45, /balance_insufficient\|insufficient \(available \)\?funds/);
  assert.match(SQL45, /attempt_count = greatest\(coalesce\(attempt_count, 1\) - 1, 0\)/);
  assert.match(SQL45, /next_retry_at = now\(\) \+ interval ''6 hours''/);
});

test("au-delà de dix jours, l'administrateur est prévenu", () => {
  assert.match(SQL45, /now\(\) - interval ''10 days''/);
  assert.match(SQL45, /Versement bloque faute de solde/);
  assert.match(SQL45, /status = ''failed''/);
});

test("le correctif refuse de s'appliquer à l'aveugle", () => {
  assert.match(SQL45, /appliquez d''abord la migration 036/);
  assert.match(SQL45, /Point d''insertion introuvable/);
  // Rejouer le script ne double pas la règle.
  assert.match(SQL45, /position\('attente_de_fonds' in v_src\) > 0/);
});

test("le code d'erreur Stripe est transmis à la base", () => {
  assert.match(MAINT, /\[stripeError\?\.code, stripeError\?\.message \|\| "transfer_failed"\]/);
});

test("le client sait quand l'argent revient vraiment sur son compte", () => {
  // Un remboursement part tout de suite, mais c'est la banque qui crédite.
  assert.match(COPY, /votre banque le crédite sous 5 à 10 jours/);
  assert.match(COPY, /le remboursement intégral est lancé sous \$\{NO_PARTNER_REFUND_HOURS\} h/);
});
