// Tests d'intégration base de données — migration 095 (supprimer / restaurer un devis).
// Exécution : PGURL=postgres://... node --test tests/db/suppression-devis-095.dbtest.mjs
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
const actifs = async () => (await as(adminId, "select public.secoto_admin_quotes_actifs() as r"))[0].r;
const supprimer = async (id, motif = null, uid = adminId) => (await as(uid, "select public.secoto_admin_quote_supprimer($1, $2) as r", [id, motif]))[0].r;
const restaurer = async (id) => (await as(adminId, "select public.secoto_admin_quote_restaurer($1) as r", [id]))[0].r;
const corbeille = async () => (await as(adminId, "select public.secoto_admin_quotes_supprimes() as r"))[0].r;
const lien = async (quoteId) => (await as(adminId, "select public.secoto_admin_devis_link_quote($1, 30) as r", [quoteId]))[0].r;
const ouvrir = async (token) => (await as(null, "select public.secoto_devis_link_open($1) as r", [token], "service_role"))[0].r;
const jeton = (url) => new URL(url).searchParams.get("t");
const ligne = async (id) => (await sql("select * from public.transport_quotes where id = $1", [id]))[0];

test.before(async () => {
  await sql("update public.secoto_feature_flags set enabled = true where key in ('auto_pricing','od_payments')");
  adminId = await compte("admin");
  clientId = await compte("client");
});
test.after(async () => { await pool.end(); });

// 105 : plus aucun devis manuel n'est créé ; un devis « à établir » d'avant 105
// est reconstitué tel qu'il existe encore en base.
async function devisManuelHistorique() {
  const q = await devisSansCompte();
  await sql("update public.transport_quotes set status='manual_review', manual_reason='contraintes_particulieres', client_price_cents=null, partner_pay_cents=null where id=$1", [q.id]);
  return { ...q, status: "manual_review", manual_reason: "contraintes_particulieres" };
}

test("095 : supprimer = sort des listes, lien révoqué, rien d'effacé", async () => {
  const q = await devisSansCompte();
  const l = await lien(q.id);
  const avant = await sql("select count(*)::int n from public.transport_quotes");
  const r = await supprimer(q.id, "test");
  assert.equal(r.supprime, true);
  assert.equal(r.liens_revoques, 1);
  const apres = await ligne(q.id);
  assert.equal(apres.status, "cancelled");
  assert.equal(apres.statut_avant_suppression, "priced");
  assert.equal(apres.motif_suppression, "test");
  assert.equal(apres.supprime_par, adminId);
  assert.equal((await sql("select count(*)::int n from public.transport_quotes"))[0].n, avant[0].n);
  assert.ok(!(await actifs()).some((x) => x.id === q.id));
  assert.equal((await ouvrir(jeton(l.url))).error, "lien_revoque");
  assert.ok((await corbeille()).some((x) => x.id === q.id && x.motif_suppression === "test"));
  // Idempotent.
  assert.equal((await supprimer(q.id)).deja, true);
  // Journal d'audit.
  assert.equal((await sql("select count(*)::int n from public.secoto_audit_log where action = 'quote_deleted' and entity_id = $1", [q.id]))[0].n, 1);
});

test("095 : restaurer remet le devis, un nouveau lien fonctionne", async () => {
  const q = await devisSansCompte();
  await supprimer(q.id);
  const r = await restaurer(q.id);
  assert.equal(r.status, "priced");
  const l2 = await ligne(q.id);
  assert.equal(l2.supprime_le, null);
  assert.ok((await actifs()).some((x) => x.id === q.id));
  const l = await lien(q.id);
  assert.equal((await ouvrir(jeton(l.url))).error, "compte_requis");
  await assert.rejects(restaurer(q.id), /pas dans les devis supprimés/);
});

test("095 : restauré après expiration → « expiré », jamais un prix périmé", async () => {
  const q = await devisSansCompte();
  await supprimer(q.id);
  await sql("update public.transport_quotes set valid_until = now() - interval '1 hour' where id = $1", [q.id]);
  assert.equal((await restaurer(q.id)).status, "expired");
});

test("095 : devis à établir supprimable ; devis avec commande refusé", async () => {
  const m = await devisManuelHistorique();
  assert.equal(m.status, "manual_review");
  await supprimer(m.id);
  assert.equal((await ligne(m.id)).status, "cancelled");
  assert.equal((await restaurer(m.id)).status, "manual_review");

  const q = await devisSansCompte();
  await sql("update public.transport_quotes set status = 'accepted' where id = $1", [q.id]);
  await assert.rejects(supprimer(q.id), /déjà une commande/);
  assert.equal((await ligne(q.id)).status, "accepted");
});

test("095 : réservé à l'admin", async () => {
  const q = await devisSansCompte();
  await assert.rejects(supprimer(q.id, null, clientId));
  await assert.rejects(as(null, "select public.secoto_admin_quote_supprimer($1)", [q.id], "anon"), /permission denied/);
  await assert.rejects(as(null, "select public.secoto_admin_quotes_supprimes()", [], "anon"), /permission denied/);
  assert.equal((await ligne(q.id)).status, "priced");
});
