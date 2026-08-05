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