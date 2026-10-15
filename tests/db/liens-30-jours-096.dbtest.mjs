// Tests d'intégration base de données — migration 096 (lien valable jusqu'au jour du transport).
// Exécution : PGURL=postgres://... node --test tests/db/liens-30-jours-096.dbtest.mjs
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
import { readFileSync } from "node:fs";
const MIGRATION = readFileSync(new URL("../../supabase/migrations/202610160096_liens_paiement_jusqu_au_transport.sql", import.meta.url), "utf8");
const lien = async (quoteId) => (await as(adminId, "select public.secoto_admin_devis_link_quote($1, 30) as r", [quoteId]))[0].r;
const ouvrir = async (token) => (await as(null, "select public.secoto_devis_link_open($1) as r", [token], "service_role"))[0].r;
const jeton = (url) => new URL(url).searchParams.get("t");
const ligneLien = async (token) => (await sql("select * from public.devis_payment_links where token = $1", [token]))[0];
const devis = async (id) => (await sql("select * from public.transport_quotes where id = $1", [id]))[0];

test.before(async () => {
  await sql("update public.secoto_feature_flags set enabled = true where key in ('auto_pricing','od_payments')");
  adminId = await compte("admin");
  clientId = await compte("client");
});
test.after(async () => { await pool.end(); });

test("096 : nouveau lien valable jusqu'à la prise en charge, pas seulement 24 h", async () => {
  const q = await devisSansCompte();
  const d = await devis(q.id);
  const l = await lien(q.id);
  const fin = new Date(l.expires_at).getTime();
  assert.ok(fin > new Date(d.valid_until).getTime(), "le lien doit survivre au devis");
  assert.equal(fin, new Date(d.pickup_at).getTime());
});

test("096 : lien déjà envoyé et expiré → prolongé, rouvre le parcours au même prix", async () => {
  const q = await devisSansCompte();
  const l = await lien(q.id);
  const t = jeton(l.url);
  // Situation réelle : lien mort après 24 h, devis expiré.
  await sql("update public.devis_payment_links set expires_at = now() - interval '2 hours', created_at = now() - interval '26 hours' where token = $1", [t]);
  await sql("update public.transport_quotes set status = 'expired', valid_until = now() - interval '2 hours' where id = $1", [q.id]);
  assert.equal((await ouvrir(t)).error, "lien_expire");
  await sql(MIGRATION);
  const apres = await ligneLien(t);
  assert.ok(new Date(apres.expires_at) > new Date());
  const r = await ouvrir(t);
  assert.equal(r.error, "compte_requis", JSON.stringify(r));
  assert.equal(r.amount_cents, q.client_price_cents);
  assert.equal((await devis(q.id)).status, "priced");
});

test("096 : jamais pour un lien révoqué, payé, un devis supprimé ou une date passée", async () => {
  const cas = [];
  for (let i = 0; i < 4; i++) {
    const q = await devisSansCompte();
    const l = await lien(q.id);
    const t = jeton(l.url);
    await sql("update public.devis_payment_links set expires_at = now() - interval '1 hour', created_at = now() - interval '26 hours' where token = $1", [t]);
    cas.push({ q, t });
  }
  await sql("update public.devis_payment_links set revoked_at = now() where token = $1", [cas[0].t]);
  await sql("update public.devis_payment_links set paid_at = now() where token = $1", [cas[1].t]);
  await sql("update public.transport_quotes set supprime_le = now(), status = 'cancelled', statut_avant_suppression = 'priced' where id = $1", [cas[2].q.id]);
  await sql("update public.transport_quotes set pickup_at = now() - interval '1 hour' where id = $1", [cas[3].q.id]);
  await sql(MIGRATION);
  for (const c of cas) assert.ok(new Date((await ligneLien(c.t)).expires_at) < new Date(), c.t);
});

test("096 : rejouable, ne raccourcit jamais un lien", async () => {
  const q = await devisSansCompte();
  const l = await lien(q.id);
  const t = jeton(l.url);
  const loin = new Date(Date.now() + 60 * 86400000).toISOString();
  await sql("update public.devis_payment_links set expires_at = $2 where token = $1", [t, loin]);
  await sql(MIGRATION);
  await sql(MIGRATION);
  assert.equal(new Date((await ligneLien(t)).expires_at).toISOString(), loin);
});
