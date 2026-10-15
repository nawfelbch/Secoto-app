// Tests d'intégration base de données — migration 093 (lien de paiement d'un devis sans compte).
// Exécution : PGURL=postgres://... node --test tests/db/lien-devis-sans-compte-093.dbtest.mjs
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
async function devisSansCompte() {
  const r = (await sql("select public.secoto_anon_quote_create($1,$2,$3) as r", [JSON.stringify({
    mode: "plateau",
    pickup: { label: "1 rue Test 04000 Digne-les-Bains", city: "Digne-les-Bains", postcode: "04000", lat: 44.09, lng: 6.23 },
    delivery: { label: "1 rue Test 83190 Ollioules", city: "Ollioules", postcode: "83190", lat: 43.14, lng: 5.85 },
    vehicle: { model: "TEST Clio", class: "voiture", category: "standard", rolling: false, constraints: [] },
    schedule: { pickup_date: inDays(6), slot: "matin", flexibility_days: 0 },
  }), JSON.stringify({ distance_km: 160, duration_min: 150, provider: "test" }), randomUUID().replace(/-/g, "") + randomUUID().replace(/-/g, "")]))[0].r;
  return r.quote;
}
const lien = async (quoteId) => (await as(adminId, "select public.secoto_admin_devis_link_quote($1, 30) as r", [quoteId]))[0].r;
const ouvrir = async (token) => (await as(null, "select public.secoto_devis_link_open($1) as r", [token], "service_role"))[0].r;
const jeton = (url) => new URL(url).searchParams.get("t");

test.before(async () => {
  await sql("update public.secoto_feature_flags set enabled = true where key in ('auto_pricing','od_payments')");
  adminId = await compte("admin");
  clientId = await compte("client");
  autreId = await compte("client");
});
test.after(async () => { await pool.end(); });

test("093 : devis sans compte → « compte requis » avec jeton de reprise, trajet et prix", async () => {
  const q = await devisSansCompte();
  const l = await lien(q.id);
  const r = await ouvrir(jeton(l.url));
  assert.equal(r.error, "compte_requis", JSON.stringify(r));
  assert.match(r.reprendre, /^[0-9a-f]{64}$/);
  assert.equal(r.trajet, "Digne-les-Bains → Ollioules");
  assert.equal(r.amount_cents, q.client_price_cents);
  // Aucune commande créée sans compte.
  assert.equal((await sql("select count(*)::int n from public.transport_orders where quote_id=$1", [q.id]))[0].n, 0);
});

test("093 : compte créé → devis rattaché → le même lien ouvre le paiement", async () => {
  const q = await devisSansCompte();
  const l = await lien(q.id);
  const r = await ouvrir(jeton(l.url));
  const repris = (await as(clientId, "select public.secoto_anon_quote_claim($1) as r", [r.reprendre]))[0].r;
  assert.equal(repris.id, q.id);
  assert.equal(repris.status, "priced");
  const p = await ouvrir(jeton(l.url));
  assert.ok(p.payment_id, JSON.stringify(p));
  assert.equal(p.amount_cents, q.client_price_cents);
  assert.equal(p.account_id, clientId);
  // Un autre client ne peut plus reprendre ce devis.
  await assert.rejects(as(autreId, "select public.secoto_anon_quote_claim($1)", [r.reprendre]), /plus disponible/);
});

test("093 : devis expiré (plus de 48 h) mais lien valable → prix honoré", async () => {
  const q = await devisSansCompte();
  const l = await lien(q.id);
  await sql("update public.transport_quotes set status='expired', valid_until=now() - interval '1 day' where id=$1", [q.id]);
  const r = await ouvrir(jeton(l.url));
  assert.equal(r.error, "compte_requis", JSON.stringify(r));
  // Le devis reste valable jusqu'à l'échéance du lien.
  const row = (await sql(`select q.status, q.valid_until >= l.expires_at as prolonge
                            from public.transport_quotes q join public.devis_payment_links l on l.quote_id = q.id
                           where q.id=$1`, [q.id]))[0];
  assert.deepEqual(row, { status: "priced", prolonge: true });
  const repris = (await as(clientId, "select public.secoto_anon_quote_claim($1) as r", [r.reprendre]))[0].r;
  assert.equal(repris.status, "priced", "le client voit un prix valable, pas « expiré »");
});

test("093 : date de prise en charge passée → message clair, rien n'est créé", async () => {
  const q = await devisSansCompte();
  const l = await lien(q.id);
  await sql("update public.transport_quotes set pickup_at = now() - interval '1 hour' where id=$1", [q.id]);
  const r = await ouvrir(jeton(l.url));
  assert.equal(r.error, "date_depassee");
});

test("093 : devis d'un client déjà inscrit → inchangé, paiement direct", async () => {
  const q = await devisSansCompte();
  await sql("update public.transport_quotes set account_id=$2, anon_token=null where id=$1", [q.id, clientId]);
  const l = await lien(q.id);
  const p = await ouvrir(jeton(l.url));
  assert.ok(p.payment_id, JSON.stringify(p));
});
