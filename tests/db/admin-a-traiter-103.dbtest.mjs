// Migration 103 — compteurs « À traiter » et prix suggéré d'un devis manuel.
// Base JETABLE uniquement. PGURL=postgres://... node --test tests/db/admin-a-traiter-103.dbtest.mjs
import test from "node:test";
import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import pg from "pg";

const pool = new pg.Pool({ connectionString: process.env.PGURL, max: 4 });
async function as(userId, text, params = [], role = "authenticated") {
  const c = await pool.connect();
  try {
    await c.query("begin");
    await c.query("select set_config('request.jwt.claim.sub', $1, true)", [userId || ""]);
    await c.query(`set local role ${role}`);
    const rows = (await c.query(text, params)).rows;
    await c.query("commit");
    return rows;
  } catch (e) { await c.query("rollback").catch(() => {}); throw e; } finally { c.release(); }
}
const sql = (t, p) => pool.query(t, p).then((r) => r.rows);
test.after(() => pool.end());

test("devis sans itinéraire : compté « à chiffrer », prix du barème suggéré pour une distance donnée", async () => {
  await sql("update public.secoto_feature_flags set enabled = true where key = 'auto_pricing'");
  const admin = randomUUID(); const client = randomUUID();
  await sql(`insert into public.accounts(id, role, full_name, email, status, is_verified) values
    ($1,'admin','TEST admin','adm103@test.invalid','active',true), ($2,'client','TEST client','cl103@test.invalid','active',true)`, [admin, client]);
  const payload = {
    mode: "convoyage",
    pickup: { label: "1 rue de Test 78530 Buc", city: "Buc", postcode: "78530", lat: 48.77, lng: 2.12 },
    delivery: { label: "1 rue Test 06800 Cagnes-sur-Mer", city: "Cagnes-sur-Mer", postcode: "06800", lat: 43.67, lng: 7.15 },
    vehicle: { model: "TEST Zoé", class: "voiture", category: "standard", rolling: true, constraints: [] },
    schedule: { pickup_date: new Date(Date.now() + 5 * 86400000).toISOString().slice(0, 10), slot: "matin", flexibility_days: 0 },
  };
  const q = (await as(null, "select public.secoto_quote_create($1,$2,$3) as q", [client, JSON.stringify(payload), null], "service_role"))[0].q;
  assert.equal(q.manual_reason, "itineraire_indisponible");
  const t = (await as(admin, "select public.secoto_admin_a_traiter() as r"))[0].r;
  assert.ok(t.devis_a_chiffrer >= 1);
  const s = (await as(admin, "select public.secoto_admin_quote_suggest($1, 925.5) as r", [q.id]))[0].r;
  assert.ok(s.client_cents > 0 && s.partner_cents > 0 && s.client_cents > s.partner_cents, JSON.stringify(s));
  await assert.rejects(as(client, "select public.secoto_admin_quote_suggest($1, 925.5)", [q.id]));
  await assert.rejects(as(client, "select public.secoto_admin_a_traiter()"));
});
