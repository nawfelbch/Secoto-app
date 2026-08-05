import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const sql = readFileSync(
  new URL(
    "../supabase/migrations/202608050007_luxury_routing_enforcement.sql",
    import.meta.url,
  ),
  "utf8",
);

const app = readFileSync(
  new URL("../src/App.jsx", import.meta.url),
  "utf8",
);

test("les notifications de mission utilisent la matrice serveur", () => {
  assert.match(
    sql,
    /notify_verified_transporters[\s\S]*transporter_matches_mission/,
  );
});

test("la visibilité, la candidature et l'attribution utilisent la même règle", () => {
  assert.match(
    sql,
    /secoto_public_missions_v2[\s\S]*transporter_matches_mission/,
  );
  assert.match(
    sql,
    /secoto_apply_to_mission[\s\S]*transporter_matches_mission/,
  );
  assert.match(
    sql,
    /secoto_assign_mission[\s\S]*transporter_matches_mission/,
  );
});

test("tous les parcours de création conservent la catégorie du véhicule", () => {
  for (const name of [
    "secoto_create_public_request",
    "secoto_create_mission",
    "secoto_create_client_mission",
    "secoto_create_transporter_request",
    "secoto_approve_request",
  ]) {
    const start = sql.indexOf(`function public.${name}`);
    assert.notEqual(start, -1, name);
    const body = sql.slice(start, start + 12000);
    assert.match(body, /vehicle_category/, name);
  }
});

test("une demande premium d'inscription reste en attente de SECOTO", () => {
  assert.match(
    sql,
    /case when v_luxury_requested then 'pending' else 'not_requested' end/,
  );
  assert.doesNotMatch(
    sql,
    /case when v_luxury_requested then 'approved'/,
  );
});

test("l'administration et le transporteur disposent des commandes premium", () => {
  assert.match(app, /secoto_admin_review_luxury_capacity/);
  assert.match(app, /secoto_update_my_transport_preferences/);
  assert.match(app, /Valider camion fermé/);
  assert.match(app, /Transport de véhicules de prestige en camion fermé/);
});
test("une suspension premium ne peut pas être levée par le transporteur", () => {
  assert.match(
    sql,
    /luxury_closed_transport_status = 'suspended'\s+then 'suspended'/,
  );
  assert.match(
    app,
    /Seul SECOTO peut réactiver cette capacité\./,
  );
  assert.match(
    app,
    /disabled=\{luxurySuspended\}/,
  );
});

test("un compte non vérifié n'est pas annoncé comme autorisé à consulter les missions", () => {
  assert.doesNotMatch(
    app,
    /vous pouvez consulter les missions, mais pas encore candidater/,
  );
  assert.match(
    app,
    /les missions compatibles seront visibles[\s\S]*après validation/,
  );
});
test("la migration SQL ne contient aucun caractère PowerShell parasite", () => {
  assert.doesNotMatch(sql, /`/);
  assert.match(
    sql,
    /split_part\(coalesce\(new\.email, 'utilisateur'\), '@', 1\)/,
  );
});
test("la suspension administrative prime sur toute préférence transporteur", () => {
  const functionStart = sql.indexOf(
    "function public.secoto_update_my_transport_preferences",
  );
  const functionEnd = sql.indexOf(
    "create or replace function public.secoto_admin_review_luxury_capacity",
    functionStart,
  );
  const body = sql.slice(functionStart, functionEnd);

  const suspendedIndex = body.indexOf(
    "luxury_closed_transport_status = 'suspended'",
  );
  const uncheckedIndex = body.indexOf(
    "when not v_requested then 'not_requested'",
  );

  assert.ok(suspendedIndex >= 0);
  assert.ok(uncheckedIndex >= 0);
  assert.ok(
    suspendedIndex < uncheckedIndex,
    "la suspension doit être évaluée avant une désactivation demandée",
  );
});

test("une nouvelle demande premium efface l'ancien avis administratif", () => {
  assert.match(
    sql,
    /v_next_status in \('not_requested', 'pending'\) then null/,
  );
});

test("les quatre vues missions conservent explicitement leur sécurité", () => {
  const matches = sql.match(
    /with \(security_barrier = true, security_invoker = false\)/g,
  ) || [];
  assert.equal(matches.length, 4);
});

test("les anciens profils transporteur incomplets ne reçoivent aucun plateau", () => {
  assert.match(
    sql,
    /coalesce\(transporter_type::text, ''\) not in \('vl', 'pl'\)/,
  );
});