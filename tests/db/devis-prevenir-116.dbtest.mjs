// Migration 116 — le client est prévenu quand un devis est chiffré. Base JETABLE uniquement.
// Exécution : PGURL=postgres://... node --test tests/db/devis-prevenir-116.dbtest.mjs
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
let adminId, clientId;
async function compte(role) {
  const id = randomUUID();
  await sql(`insert into public.accounts(id, role, full_name, email, status, is_verified, client_type) values ($1,$2,$3,$4,'active',true,'particulier')`,
    [id, role, `TEST ${role}`, `${role}-${id.slice(0, 6)}@test.invalid`]);
  return id;
}
async function devisManuel({ email = null, phone = null } = {}) {
  const r = (await sql("select public.secoto_anon_quote_create($1,$2,$3) as r", [JSON.stringify({
    mode: "plateau",
    pickup: { label: "1 rue Test 78530 Buc", city: "Buc", postcode: "78530", lat: 48.77, lng: 2.12 },
    delivery: { label: "1 rue Test 06800 Cagnes-sur-Mer", city: "Cagnes-sur-Mer", postcode: "06800", lat: 43.66, lng: 7.15 },
    vehicle: { model: "TEST Golf 7", class: "voiture", category: "standard", rolling: true, constraints: [] },
    schedule: { pickup_date: inDays(6), slot: "matin", flexibility_days: 0 },
  }), JSON.stringify({ distance_km: 900, duration_min: 540, provider: "test" }), randomUUID().replace(/-/g, "") + randomUUID().replace(/-/g, "")]))[0].r;
  const id = r.quote.id;
  await sql(`update public.transport_quotes set status='manual_review', manual_reason='itineraire_indisponible',
             client_price_cents=null, partner_pay_cents=null, contact_email=$2, contact_phone=$3 where id=$1`, [id, email, phone]);
  return id;
}
const chiffrer = async (id, cents = 105428) =>
  (await as(adminId, "select public.secoto_admin_price_quote($1, $2, $3, 48, 'test', false) as r", [id, cents, Math.round(cents * 0.7)]))[0].r;
const aTraiter = async () => (await as(adminId, "select public.secoto_admin_a_traiter() as r"))[0].r;
const actifs = async () => (await as(adminId, "select public.secoto_admin_quotes_actifs() as r"))[0].r;
const mails = (id) => sql("select to_email, subject, body_text from public.email_outbox where event_key like $1", [`devis-chiffre:${id}:%`]);

test.before(async () => {
  await sql("update public.secoto_feature_flags set enabled = true where key in ('auto_pricing','od_payments')");
  adminId = await compte("admin");
  clientId = await compte("client");
});
test.after(async () => { await pool.end(); });

test("116 : chiffrer envoie l'e-mail au client (e-mail laissé ou compte), montant lisible, pas de relance en double", async () => {
  const id = await devisManuel({ email: "client116@test.invalid" });
  const r = await chiffrer(id);
  assert.equal(r.email_envoye, true);
  assert.equal(r.telephone_seul, false);
  const m = await mails(id);
  assert.equal(m.length, 1);
  assert.equal(m[0].to_email, "client116@test.invalid");
  assert.match(m[0].subject, /Votre devis SECOTO est prêt : 1 054,28 € pour Buc → Cagnes-sur-Mer/);
  assert.match(m[0].body_text, /https:\/\/app\.secoto-transport\.fr\/\?reprendre=[0-9a-f]{64}/);
  assert.match(m[0].body_text, /L'équipe SECOTO/);
  // La relance automatique (étape déjà atteinte) ne double pas l'e-mail du chiffrage.
  await sql("update public.transport_quotes set created_at = now() - interval '3 hours' where id=$1", [id]);
  await as(null, "select public.secoto_devis_relances(50)", [], "service_role");
  assert.equal((await sql("select count(*)::int n from public.email_outbox where event_key like $1", [`relance-devis:${id}:%`]))[0].n, 0);

  // Client avec compte : l'e-mail part à l'adresse du compte.
  const id2 = await devisManuel();
  await sql("update public.transport_quotes set account_id=$2, anon_token=null where id=$1", [id2, clientId]);
  assert.equal((await chiffrer(id2, 12000)).email_envoye, true);
  const m2 = await mails(id2);
  assert.equal(m2.length, 1);
  assert.match(m2[0].to_email, /^client-/);
  assert.match(m2[0].subject, /120 € pour/);
});

test("116 : téléphone seul → à prévenir, message préparé (devis expiré réactivé), trace, sort du compteur", async () => {
  const id = await devisManuel({ phone: "+33637554175" });
  const avant = await aTraiter();
  const r = await chiffrer(id);
  assert.equal(r.email_envoye, false);
  assert.equal(r.telephone_seul, true);
  assert.equal((await aTraiter()).devis_a_rappeler, avant.devis_a_rappeler + 1);
  // Expiré sans que le client le sache : il reste dans la liste admin.
  await sql("update public.transport_quotes set status='expired', valid_until=now()-interval '1 hour' where id=$1", [id]);
  const ligne = (await actifs()).find((q) => q.id === id);
  assert.ok(ligne, "visible malgré l'expiration");
  assert.equal(ligne.telephone_seul, true);
  assert.equal(ligne.dernier_message, null);
  // Préparer : devis réactivé et lien de paiement.
  const p = (await as(adminId, "select public.secoto_admin_devis_message_preparer($1) as r", [id]))[0].r;
  assert.match(p.url, /devis-pay\?t=/);
  assert.equal(p.amount_cents, 105428);
  const [q] = await sql("select status, valid_until > now() valide from public.transport_quotes where id=$1", [id]);
  assert.equal(q.status, "manual_priced");
  assert.equal(q.valide, true);
  // Envoi tracé : sort du compteur « à prévenir », trace visible.
  await as(adminId, "select public.secoto_admin_devis_message_envoye($1, 'sms')", [id]);
  assert.equal((await aTraiter()).devis_a_rappeler, avant.devis_a_rappeler);
  const apres = (await actifs()).find((x) => x.id === id);
  assert.equal(apres.dernier_message.canal, "sms");
  assert.equal(apres.nb_messages, 1);
  // Réservé à l'admin.
  await assert.rejects(as(clientId, "select public.secoto_admin_devis_message_envoye($1, 'sms')", [id]));
  await assert.rejects(as(adminId, "select public.secoto_admin_devis_message_envoye($1, 'pigeon')", [id]), /Canal inconnu/);
});

test("116 : « à chiffrer » ignore les devis dont l'enlèvement est passé", async () => {
  const avant = (await aTraiter()).devis_a_chiffrer;
  const id = await devisManuel({ phone: "+33641894641" });
  assert.equal((await aTraiter()).devis_a_chiffrer, avant + 1);
  await sql("update public.transport_quotes set pickup_at = now() - interval '2 days' where id=$1", [id]);
  assert.equal((await aTraiter()).devis_a_chiffrer, avant);
  await assert.rejects(as(adminId, "select public.secoto_admin_devis_message_preparer($1)", [id]), /enlèvement est passée/);
});
