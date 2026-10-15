// Tests d'intégration base de données — migration 094 (écran admin : devis utiles seulement).
// Exécution : PGURL=postgres://... node --test tests/db/admin-devis-actifs-094.dbtest.mjs
// Base JETABLE uniquement (données fictives « TEST »). Jamais sur la production.
import test from "node:test";
import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import pg from "pg";

const PGURL = process.env.PGURL;
if (!PGURL) throw new Error("PGURL requis (base de test jetable).");
const pool = new pg.Pool({ connectionString: PGURL, max: 5 });
const sql = async (t, p = []) => (await pool.query(t, p)).rows;
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
const inDays = (d) => new Date(Date.now() + d * 86400000).toISOString().slice(0, 10);
let adminId, clientId, autreId;
async function compte(role) {
  const id = randomUUID();
  await sql(`insert into public.accounts(id, role, full_name, email, status, is_verified, client_type) values ($1,$2,$3,$4,'active',true,'particulier')`,
    [id, role, `TEST ${role}`, `${role}-${id.slice(0, 6)}@test.invalid`]);
  return id;
}
async function devisSansCompte(constraints = []) {
  const r = (await sql("select public.secoto_anon_quote_create($1,$2,$3) as r", [JSON.stringify({
    mode: "plateau",
    pickup: { label: "1 rue Test 04000 Digne-les-Bains", city: "Digne-les-Bains", postcode: "04000", lat: 44.09, lng: 6.23 },
    delivery: { label: "1 rue Test 83190 Ollioules", city: "Ollioules", postcode: "83190", lat: 43.14, lng: 5.85 },
    vehicle: { model: "TEST Clio", class: "voiture", category: "standard", rolling: false, constraints },
    schedule: { pickup_date: inDays(6), slot: "matin", flexibility_days: 0 },
  }), JSON.stringify({ distance_km: 160, duration_min: 150, provider: "test" }), randomUUID().replace(/-/g, "") + randomUUID().replace(/-/g, "")]))[0].r;
  return r.quote;
}
const actifs = async (uid) => (await as(uid, "select public.secoto_admin_quotes_actifs() as r"))[0].r;
const tous = async (uid) => (await as(uid, "select public.secoto_admin_quotes(null) as r"))[0].r;

test.before(async () => {
  await sql("update public.secoto_feature_flags set enabled = true where key in ('auto_pricing','od_payments')");
  adminId = await compte("admin");
  clientId = await compte("client");
});
test.after(async () => { await pool.end(); });

test("094 : devis à établir + tarifés valides, rien d'autre, même format que la liste complète", async () => {
  const valide = await devisSansCompte();
  const expire = await devisSansCompte();
  await sql("update public.transport_quotes set valid_until = now() - interval '1 hour' where id = $1", [expire.id]);
  const manuel = await devisSansCompte(["gabarit_hors_norme"]);
  assert.equal(valide.status, "priced");
  assert.equal(manuel.status, "manual_review", JSON.stringify(manuel));

  const a = await actifs(adminId);
  const ids = a.map((q) => q.id);
  assert.ok(ids.includes(valide.id));
  assert.ok(ids.includes(manuel.id));
  assert.ok(!ids.includes(expire.id));
  for (const q of a) {
    assert.ok(["manual_review", "manual_priced"].includes(q.status) || (q.status === "priced" && (!q.valid_until || new Date(q.valid_until) > new Date())), q.status);
  }
  // Mêmes objets (nom, téléphone…) et même ordre que secoto_admin_quotes.
  const complet = (await tous(adminId)).filter((q) => ids.includes(q.id));
  assert.deepEqual(a, complet);
});

test("094 : réservé à l'admin, fermé aux anonymes", async () => {
  await assert.rejects(actifs(clientId));
  await assert.rejects(as(null, "select public.secoto_admin_quotes_actifs()", [], "anon"), /permission denied/);
});

test("094 : la liste complète d'origine est inchangée", async () => {
  const t = await tous(adminId);
  assert.ok(t.length >= (await actifs(adminId)).length);
});
