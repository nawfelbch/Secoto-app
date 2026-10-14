// Tests d'intégration base de données — migration 090 (contact avant le prix).
// Exécution : PGURL=postgres://... node --test tests/db/contact-avant-prix-090.dbtest.mjs
// Base JETABLE uniquement (données fictives « TEST »). Jamais sur la production.
import test from "node:test";
import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import pg from "pg";

const PGURL = process.env.PGURL;
if (!PGURL) throw new Error("PGURL requis (base de test jetable).");
const pool = new pg.Pool({ connectionString: PGURL, max: 5 });
const sql = async (t, p = []) => { const c = await pool.connect(); try { return (await c.query(t, p)).rows; } finally { c.release(); } };
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
const payload = {
  mode: "plateau",
  pickup: { label: "1 rue de Test 92260 Fontenay-aux-Roses", city: "Fontenay-aux-Roses", postcode: "92260", lat: 48.79, lng: 2.29 },
  delivery: { label: "1 place Test 69002 Lyon", city: "Lyon", postcode: "69002", lat: 45.76, lng: 4.83 },
  vehicle: { model: "TEST Clio", class: "voiture", category: "standard", rolling: true, constraints: [] },
  schedule: { pickup_date: inDays(6), slot: "matin", flexibility_days: 0 },
};
let adminId;
const devisAnonyme = async () => (await sql("select public.secoto_anon_quote_create($1,$2,$3) as r",
  [JSON.stringify(payload), JSON.stringify({ distance_km: 465, duration_min: 280, provider: "test" }), `ip-${randomUUID()}`]))[0].r.quote;
const contact = (id, tel, mail) => as(null, "select public.secoto_devis_contact($1,$2,$3) as r", [id, tel, mail], "service_role").then((r) => r[0].r);

test.before(async () => {
  await sql("update public.secoto_feature_flags set enabled = true where key = 'auto_pricing'");
  adminId = randomUUID();
  await sql(`insert into public.accounts(id, role, full_name, email, status, is_verified) values ($1,'admin','TEST admin 090',$2,'active',true)`,
    [adminId, `a090-${adminId.slice(0, 6)}@test.invalid`]);
});
test.after(async () => { await pool.end(); });

test("090 : téléphone du visiteur gardé au format international, admin prévenu", async () => {
  const q = await devisAnonyme();
  const r = await contact(q.id, "06 12 34 56 78", null);
  assert.deepEqual(r, { ok: true, telephone: true, email: false });
  const row = (await sql("select contact_phone, contact_email, contact_at from public.transport_quotes where id=$1", [q.id]))[0];
  assert.equal(row.contact_phone, "+33612345678");
  assert.equal(row.contact_email, null);
  assert.ok(row.contact_at);
  const n = (await sql("select count(*)::int n from public.notifications where event_key like $1", [`%quote-contact:${q.id}%`]))[0].n;
  assert.ok(n > 0, "notification « Nouveau contact devis »");
});

test("090 : e-mail seul accepté ; rien de valide = refus", async () => {
  const q = await devisAnonyme();
  await contact(q.id, "abc", "Client@Exemple.FR");
  assert.equal((await sql("select contact_email from public.transport_quotes where id=$1", [q.id]))[0].contact_email, "client@exemple.fr");
  await assert.rejects(contact(q.id, "06", "pas-un-mail"), /téléphone ou votre e-mail/);
});

test("090 : visible de l'admin seulement ; personne d'autre ne peut l'écrire", async () => {
  const q = await devisAnonyme();
  await contact(q.id, "+49 151 2345678", null);
  const liste = (await as(adminId, "select public.secoto_admin_quotes(null) as r"))[0].r;
  const ligne = liste.find((x) => x.id === q.id);
  assert.equal(ligne.client_phone, "+491512345678");
  assert.equal(ligne.client_anonyme, true);
  await assert.rejects(as(null, "select public.secoto_devis_contact($1,'0612345678',null)", [q.id], "anon"), /permission denied/);
  await assert.rejects(as(adminId, "select public.secoto_devis_contact($1,'0612345678',null)", [q.id]), /permission denied/);
});

test("090 : effacé après douze mois sans commande", async () => {
  const q = await devisAnonyme();
  await contact(q.id, "0612345678", "a@b.fr");
  await sql("update public.transport_quotes set contact_at = now() - interval '13 months' where id=$1", [q.id]);
  const r = (await as(null, "select public.secoto_purge_contacts_devis() as r", [], "service_role"))[0].r;
  assert.ok(r.effaces >= 1);
  const row = (await sql("select contact_phone, contact_email from public.transport_quotes where id=$1", [q.id]))[0];
  assert.deepEqual(row, { contact_phone: null, contact_email: null });
});
