import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const sql = readFileSync(new URL("../supabase/migrations/202610310126_relances_transporteurs_automatiques.sql", import.meta.url), "utf8");
const maintenance = readFileSync(new URL("../netlify/functions/od-maintenance.js", import.meta.url), "utf8");

test("126 : missions publiées sans transporteur, 48 h puis 24 h avant le départ", () => {
  assert.match(sql, /m\.status::text = 'published'/);
  assert.match(sql, /m\.assigned_transporter_id is null/);
  assert.match(sql, /interval '48 hours'/);
  assert.match(sql, /then 'j1' else 'j2'/);
});

test("126 : une seule relance par palier, jamais à moins de 12 h, jamais la nuit", () => {
  assert.match(sql, /'relance-auto:' \|\| r\.mission_id::text \|\| ':' \|\| r\.palier \|\| ':' \|\| r\.transporteur_id::text/);
  assert.match(sql, /on conflict \(event_key\) do nothing/);
  assert.match(sql, /interval '12 hours'/);
  assert.match(sql, /v_heure < 7 or v_heure >= 21/);
});

test("126 : seulement les transporteurs compatibles qui n'ont ni proposé ni refusé", () => {
  assert.match(sql, /transporter_matches_mission\(a\.id, m\.id\)/);
  assert.match(sql, /mission_applications ap where ap\.mission_id = m\.id and ap\.transporter_id = a\.id/);
  assert.match(sql, /mission_declines d where d\.mission_id = m\.id and d\.partner_id = a\.id/);
  assert.match(sql, /'L''Équipe SECOTO'/);
});

test("126 : réservée au serveur et appelée par la maintenance", () => {
  assert.match(sql, /revoke all on function public\.secoto_relances_transporteurs\(integer\) from public, anon, authenticated/);
  assert.match(sql, /grant execute on function public\.secoto_relances_transporteurs\(integer\) to service_role/);
  assert.match(maintenance, /admin\.rpc\("secoto_relances_transporteurs", \{ p_limit: 200 \}\)/);
});
