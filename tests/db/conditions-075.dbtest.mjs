// Tests d'intégration base de données — migration 075 (acceptation des conditions).
// Exécution : PGURL=postgres://... node --test tests/db/conditions-075.dbtest.mjs
// Base JETABLE uniquement (données fictives « TEST »). Jamais sur la production.
import test from "node:test";
import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import pg from "pg";

const PGURL = process.env.PGURL;
if (!PGURL) throw new Error("PGURL requis (base de test jetable).");
const pool = new pg.Pool({ connectionString: PGURL, max: 5 });

async function sql(text, params = []) {
  const c = await pool.connect();
  try { return (await c.query(text, params)).rows; } finally { c.release(); }
}
async function as(userId, text, params = [], role = "authenticated") {
  const c = await pool.connect();
  try {
    await c.query("begin");
    await c.query("select set_config('request.jwt.claim.sub', $1, true)", [userId || ""]);
    await c.query(`set local role ${role}`);
    const rows = (await c.query(text, params)).rows;
    await c.query("commit");
    return rows;
  } catch (error) {
    await c.query("rollback").catch(() => {});
    throw error;
  } finally { c.release(); }
}
const flag = (on) => sql("update public.secoto_feature_flags set enabled = $1 where key = 'conditions_v2'", [on]);
const version = async () => (await sql("select value ->> 'version' as v from public.app_settings where key = 'terms_current'"))[0].v;
const status = async (id) => (await as(id, "select public.secoto_terms_status() as s"))[0].s;

async function account(role, meta = null, extra = {}) {
  const id = randomUUID();
  if (meta) {
    // Inscription réelle : le déclencheur d'inscription crée le compte.
    await sql("insert into auth.users(id, email, raw_user_meta_data) values ($1,$2,$3)",
      [id, `${id}@test.invalid`, JSON.stringify({ role, client_type: "pro", full_name: "TEST", ...meta })]);
    return id;
  }
  await sql(`insert into public.accounts(id, role, full_name, email, status, transporter_type, client_type)
             values ($1,$2,'TEST',$3,'active',$4,$5)`, [id, role, `${id}@test.invalid`, extra.type ?? null, role === "client" ? "pro" : null]);
  return id;
}

test.after(async () => { await flag(false); await pool.end(); });

test("interrupteur éteint : personne n'est bloqué, rien n'est enregistré", async () => {
  await flag(false);
  const c = await account("client");
  const s = await status(c);
  assert.equal(s.required, false);
  const r = (await as(c, "select public.secoto_accept_terms($1) as r", [await version()]))[0].r;
  assert.equal(r.ok, false);
  assert.equal((await sql("select count(*)::int as n from public.terms_acceptances where account_id=$1", [c]))[0].n, 0);
  const pub = (await as(null, "select public.secoto_terms_public() as p", [], "anon"))[0].p;
  assert.equal(pub.active, false);
});

test("allumé : client et transporteur doivent accepter, l'administrateur jamais", async () => {
  await flag(true);
  const c = await account("client");
  const t = await account("transporter", null, { type: "vl" });
  const a = await account("admin");
  const sc = await status(c);
  assert.equal(sc.required, true);
  assert.deepEqual(sc.documents, ["cgu", "confidentialite"]);
  const st = await status(t);
  assert.equal(st.required, true);
  assert.deepEqual(st.documents, ["cgu", "confidentialite", "conditions_transporteur"]);
  assert.equal((await status(a)).required, false);
  const ra = (await as(a, "select public.secoto_accept_terms($1) as r", [await version()]))[0].r;
  assert.equal(ra.reason, "non_concerne");
});

test("un clic enregistre la preuve : compte, version, date, heure, origine", async () => {
  await flag(true);
  const t = await account("transporter", null, { type: "pl" });
  const v = await version();
  const s = (await as(t, "select public.secoto_accept_terms($1,'ios','TestAgent') as r", [v]))[0].r;
  assert.equal(s.required, false);
  const rows = await sql("select * from public.terms_acceptances where account_id=$1", [t]);
  assert.equal(rows.length, 1);
  assert.equal(rows[0].terms_version, v);
  assert.equal(rows[0].source, "reconnexion");
  assert.equal(rows[0].platform, "ios");
  assert.deepEqual(rows[0].documents, ["cgu", "confidentialite", "conditions_transporteur"]);
  assert.ok(rows[0].accepted_at instanceof Date);
  // Double clic : une seule ligne.
  await as(t, "select public.secoto_accept_terms($1) as r", [v]);
  assert.equal((await sql("select count(*)::int as n from public.terms_acceptances where account_id=$1", [t]))[0].n, 1);
});

test("une version périmée est refusée", async () => {
  await flag(true);
  const c = await account("client");
  await assert.rejects(as(c, "select public.secoto_accept_terms('ancienne-version') as r"), /mises à jour/);
});

test("nouvelle version : tout le monde réaccepte une fois", async () => {
  await flag(true);
  const c = await account("client");
  const v1 = await version();
  await as(c, "select public.secoto_accept_terms($1)", [v1]);
  assert.equal((await status(c)).required, false);
  await sql("update public.app_settings set value = jsonb_set(value, '{version}', '\"v-test-2\"') where key='terms_current'");
  try {
    assert.equal((await status(c)).required, true);
    await as(c, "select public.secoto_accept_terms('v-test-2')");
    assert.equal((await status(c)).required, false);
  } finally {
    await sql("update public.app_settings set value = jsonb_set(value, '{version}', to_jsonb($1::text)) where key='terms_current'", [v1]);
  }
});

test("inscription : la case cochée est enregistrée à la création du compte", async () => {
  await flag(true);
  const v = await version();
  const ok = await account("client", { terms_version: v, terms_platform: "web" });
  const r = await sql("select source, platform from public.terms_acceptances where account_id=$1", [ok]);
  assert.deepEqual(r, [{ source: "inscription", platform: "web" }]);
  assert.equal((await status(ok)).required, false);
  // Version absente ou périmée : rien n'est enregistré, la fenêtre prendra le relais.
  const ko = await account("client", { terms_version: "ancienne" });
  assert.equal((await sql("select count(*)::int as n from public.terms_acceptances where account_id=$1", [ko]))[0].n, 0);
  assert.equal((await status(ko)).required, true);
});

test("cloisonnement : chacun ne lit que sa preuve, personne n'écrit directement", async () => {
  await flag(true);
  const v = await version();
  const a = await account("client");
  const b = await account("client");
  await as(a, "select public.secoto_accept_terms($1)", [v]);
  await as(b, "select public.secoto_accept_terms($1)", [v]);
  const vues = await as(a, "select account_id from public.terms_acceptances");
  assert.deepEqual(vues.map((r) => r.account_id), [a]);
  await assert.rejects(as(a, "insert into public.terms_acceptances(account_id, terms_version, documents, source) values ($1,'x','{cgu}','reconnexion')", [a]), /permission denied/);
  await assert.rejects(as(a, "delete from public.terms_acceptances"), /permission denied/);
  await assert.rejects(as(null, "select public.secoto_terms_status()", [], "anon"), /permission denied/);
  await assert.rejects(as(a, "select public.secoto_devis_link_accept_terms('x','y')"), /permission denied/);
});

test("lien de paiement : version vérifiée, preuve posée sur le paiement", async () => {
  await flag(true);
  const r = (await as(null, "select public.secoto_devis_link_accept_terms('inconnu', $1) as r", [await version()], "service_role"))[0].r;
  assert.equal(r.error, "lien_inconnu");
  const p = (await as(null, "select public.secoto_devis_link_accept_terms('inconnu', 'ancienne') as r", [], "service_role"))[0].r;
  assert.equal(p.error, "version_perimee");
  const e = (await as(null, "select public.secoto_devis_link_terms('inconnu') as r", [], "service_role"))[0].r;
  assert.equal(e.active, true);
  assert.equal(e.accepted, false);
});
