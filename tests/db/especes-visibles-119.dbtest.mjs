// Migration 119 — le transporteur voit le total à encaisser d'une course en espèces. Base JETABLE uniquement.
// Exécution : PGURL=postgres://... node --test tests/db/especes-visibles-119.dbtest.mjs
import test from "node:test";
import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import pg from "pg";

const PGURL = process.env.PGURL;
if (!PGURL) throw new Error("PGURL requis (base de test jetable).");
const pool = new pg.Pool({ connectionString: PGURL, max: 3 });
const sql = async (t, p = []) => (await pool.query(t, p)).rows;
async function as(userId, text, params = []) {
  const c = await pool.connect();
  try {
    await c.query("begin");
    await c.query("select set_config('request.jwt.claim.sub', $1, true)", [userId]);
    await c.query("set local role authenticated");
    const rows = (await c.query(text, params)).rows;
    await c.query("commit");
    return rows;
  } catch (e) { await c.query("rollback").catch(() => {}); throw e; } finally { c.release(); }
}
test.after(async () => { await pool.end(); });

async function compte(role) {
  const id = randomUUID();
  await sql(`insert into public.accounts(id, role, full_name, email, status, is_verified, transporter_type, client_type)
             values ($1, $2, $3, $4, 'active', true, $5, $6)`,
    [id, role, `TEST ${role}`, `${role}-${id.slice(0, 6)}@test.invalid`, role === "transporter" ? "vl" : null, role === "client" ? "particulier" : null]);
  return id;
}
async function mission(client, transporteur, reglement) {
  return (await sql(`insert into public.missions(public_ref, type, status, from_city, to_city, manual_pricing,
                       manual_carrier_pay, manual_margin, client_account_id, assigned_transporter_id, payment_method)
                     values ('MIS-TEST-' || substr(md5(random()::text),1,6), 'plateau', 'assigned', 'Lux', 'Ambérieu-en-Bugey', true,
                       125.70, 25.14, $1, $2, $3) returning id`, [client, transporteur, reglement]))[0].id;
}

test("119 : espèces → total à encaisser visible ; carte → rien ; autre transporteur → rien", async () => {
  const client = await compte("client");
  const grenier = await compte("transporter");
  const autre = await compte("transporter");
  const especes = await mission(client, grenier, "especes");
  const carte = await mission(client, grenier, "carte");

  const vues = await as(grenier, "select id, carrier_pay, especes_a_encaisser from public.secoto_missions_transporter_v2 where id = any($1)", [[especes, carte]]);
  const e = vues.find((v) => v.id === especes);
  const c = vues.find((v) => v.id === carte);
  assert.equal(Number(e.carrier_pay), 125.7);
  assert.equal(Number(e.especes_a_encaisser), 150.84);
  assert.equal(c.especes_a_encaisser, null, "le prix client reste invisible hors espèces");

  // Un autre transporteur ne voit pas la mission du tout.
  assert.equal((await as(autre, "select 1 from public.secoto_missions_transporter_v2 where id = $1", [especes])).length, 0);
});
