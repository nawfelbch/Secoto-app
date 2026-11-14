import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { filtrerClients, etiquetteClient, nomClient } from "../src/lib/clientsPros.js";

const lire = (p) => readFileSync(new URL(`../${p}`, import.meta.url), "utf8");

test("147 : fonction admin en lecture seule, réservée à l'administrateur, sans comptes internes ni tests", () => {
  const sql = lire("supabase/migrations/202611140147_admin_clients_pros.sql");
  assert.match(sql, /perform secoto_private\.assert_admin\(\);/);
  assert.match(sql, /a\.client_type = 'pro'/);
  assert.match(sql, /not coalesce\(a\.is_internal, false\)/);
  assert.match(sql, /not coalesce\(o\.is_test, false\)/);
  assert.match(sql, /<> 'transporteur'/);
  assert.doesNotMatch(sql, /\b(update|delete|insert)\s+(into\s+)?public\./i);
});

test("147 : recherche (société, téléphone, SIREN avec espaces) et tris", () => {
  const clients = [
    { id: 1, societe: "Garage du Midi", telephone: "0601020304", siren: "123456789", ca_cents: 100, commandes: 1, inscrit_le: "2026-11-01", derniere_commande_at: "2026-11-10" },
    { id: 2, nom: "Éric Martin", ville: "Lyon", ca_cents: 900, commandes: 3, inscrit_le: "2026-11-05", dernier_devis_at: "2026-11-12" },
  ];
  assert.deepEqual(filtrerClients(clients, "midi").map((c) => c.id), [1]);
  assert.deepEqual(filtrerClients(clients, "123 456").map((c) => c.id), [1]);
  assert.deepEqual(filtrerClients(clients, "eric").map((c) => c.id), [2]);
  assert.deepEqual(filtrerClients(clients, "", "ca").map((c) => c.id), [2, 1]);
  assert.deepEqual(filtrerClients(clients, "", "activite").map((c) => c.id), [2, 1]);
  assert.equal(nomClient(clients[0]), "Garage du Midi");
  assert.equal(etiquetteClient({ commandes: 0, devis: 2 }).texte, "Prospect · devis sans commande");
  assert.equal(etiquetteClient({ commandes: 2, en_cours: 1 }).texte, "Commande en cours");
});

test("147 : onglet « Clients pros » dans l'espace admin", () => {
  const app = lire("src/App.jsx");
  assert.match(app, /\{ key: "clientsPros", label: "Clients pros", icon: "users" \}/);
  assert.match(app, /adminTab === "clientsPros" && \(/);
});
