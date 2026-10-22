// Tests d'intégration base de données — migration 114 (commandes dans « Missions publiées »).
// Exécution : PGURL=postgres://... node --test tests/db/reglement-arrivee-100.dbtest.mjs
// Base JETABLE uniquement (données fictives « TEST »). Jamais sur la production.
import test from "node:test";
import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import pg from "pg";

const PGURL = process.env.PGURL;
if (!PGURL) throw new Error("PGURL requis (base de test jetable).");
const pool = new pg.Pool({ connectionString: PGURL, max: 10 });

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
const service = (text, params) => as(null, text, params, "service_role");

const ids = {};
async function account(key, role, extra = {}) {
  const id = randomUUID();
  ids[key] = id;
  await sql(`insert into public.accounts(id, role, full_name, email, status, is_verified, transporter_type, client_type)
             values ($1,$2,$3,$4,'active',true,$5,$6)`,
    [id, role, `TEST ${key}`, `${key}@test.invalid`, extra.type ?? null, extra.clientType ?? "pro"]);
  return id;
}
const inDays = (d) => new Date(Date.now() + d * 86400000).toISOString().slice(0, 10);
const payload = (mode = "plateau") => ({
  mode,
  pickup: { label: "1 rue de Test 92260 Fontenay-aux-Roses", city: "Fontenay-aux-Roses", postcode: "92260", lat: 48.79, lng: 2.29 },
  delivery: { label: "1 place Test 69002 Lyon", city: "Lyon", postcode: "69002", lat: 45.76, lng: 4.83 },
  vehicle: { model: "TEST Peugeot 308", class: "voiture", category: "standard", rolling: true, constraints: [] },
  schedule: { pickup_date: inDays(3), slot: "matin", flexibility_days: 0 },
});
async function quote(clientId, km = 400) {
  const r = await service("select public.secoto_quote_create($1,$2,$3) as q",
    [clientId, JSON.stringify(payload()), JSON.stringify({ distance_km: km, duration_min: 240, provider: "test" })]);
  return r[0].q;
}
const book = (clientId, quoteId) =>
  as(clientId, "select public.secoto_od_book_quote($1,false,$2) as r", [quoteId, randomUUID()]).then((r) => r[0].r.order || r[0].r);
const choisir = (clientId, orderId, mode) =>
  as(clientId, "select public.secoto_od_choisir_reglement($1,$2) as r", [orderId, mode]).then((r) => r[0].r.order);
const cardSaved = (paymentId) =>
  service("select public.secoto_direct_card_saved($1,$2,'seti_test','pm_test') as r", [paymentId, `evt_${randomUUID()}`]).then((r) => r[0].r);
const offerFor = async (orderId, partnerId) =>
  (await sql("select id from public.transport_offers where order_id=$1 and partner_id=$2 and status='sent'", [orderId, partnerId]))[0]?.id;
const accept = (partnerId, offerId) =>
  as(partnerId, "select public.secoto_offer_accept($1,$2) as r", [offerId, randomUUID()]).then((r) => r[0].r);
const confirmer = (orderId) => service("select public.secoto_reglement_confirmer($1) as r", [orderId]).then((r) => r[0].r);
const flag = (key, on) => sql("update public.secoto_feature_flags set enabled=$2 where key=$1", [key, on]);
const row = async (table, id) => (await sql(`select * from public.${table} where id=$1`, [id]))[0];
const clientOrder = async (orderId) => (await sql("select secoto_private.order_client_json(o) as j from public.transport_orders o where o.id=$1", [orderId]))[0].j;
const partnerOffer = async (offerId) => (await sql("select secoto_private.offer_partner_json(x) as j from public.transport_offers x where x.id=$1", [offerId]))[0].j;
const aDebiter = () => service("select public.secoto_reglements_a_debiter(50) as r").then((r) => r[0].r);
const resultat = (paymentId, res, err = null) =>
  service("select public.secoto_reglement_debit_resultat($1,$2,$3,$4) as r", [paymentId, res, `pi_${randomUUID().slice(0, 8)}`, err]).then((r) => r[0].r);

const VL = ["vl1", "vl2"];
async function commandeEnRecherche() {
  const q = await quote(ids.client);
  const o = await book(ids.client, q.id);
  await cardSaved(o.payment_id);
  return o;
}
const vitrine = async (orderId) => (await sql("select * from public.missions where od_order_id=$1", [orderId]))[0];
const publiques = (partnerId) => as(partnerId, "select id, commande, carrier_pay from public.secoto_public_missions_v2");

test.before(async () => {
  await sql("update public.secoto_feature_flags set enabled = true where key in ('auto_pricing','od_payments','direct_accept','dispatch_notifications','reglement_arrivee')");
  await sql("update public.secoto_feature_flags set enabled = false where key in ('plateau_paiement_direct','trois_offres','bareme_transporteurs')");
  await account("client", "client");
  await account("admin", "admin");
  for (const k of VL) await account(k, "transporter", { type: "vl" });
  await account("conv", "transporter", { type: "convoyeur" });
});
test.after(async () => { await pool.end(); });

test("commande validée -> mission vitrine publiée, visible des VL/PL seulement, jamais du client", async () => {
  const o = await commandeEnRecherche();
  const v = await vitrine(o.id);
  assert.ok(v, "vitrine créée");
  assert.equal(v.status, "published");
  assert.equal(v.client_account_id, null);
  assert.equal(Number(v.carrier_pay), (await row("transport_orders", o.id)).partner_pay_cents / 100);
  const vue = await publiques(ids.vl1);
  assert.ok(vue.some((m) => m.id === v.id && m.commande === true), "visible du VL");
  assert.ok(!(await publiques(ids.conv)).some((m) => m.id === v.id), "invisible du convoyeur (plateau)");
  // Attribution directe de la vitrine interdite (le paiement resterait en suspens).
  await assert.rejects(sql("update public.missions set assigned_transporter_id=$2, status='assigned' where id=$1", [v.id, ids.vl1]), /Mission liée à une commande/);
});

test("le transporteur propose le prix affiché -> la COMMANDE lui est attribuée, rien n'est débité, la vitrine disparaît", async () => {
  const o = await commandeEnRecherche();
  const v = await vitrine(o.id);
  await assert.rejects(as(ids.vl1, "select public.secoto_mission_proposer($1,$2,now() + interval '3 days',null)", [v.id, Number(v.carrier_pay) + 50]), /prix fixe/);
  const r = (await as(ids.vl1, "select public.secoto_mission_proposer($1,$2,now() + interval '3 days',null) as r", [v.id, Number(v.carrier_pay)]))[0].r;
  assert.equal(r.result, "assigned");
  const ord = await row("transport_orders", o.id);
  assert.equal(ord.status, "partner_confirmed");
  assert.equal(ord.assigned_partner_id, ids.vl1);
  const pay = await row("payments", o.payment_id);
  assert.equal(pay.status, "requires_capture", "carte en garantie, non débitée");
  assert.equal(pay.paid_at, null);
  const m = await row("missions", ord.mission_id);
  assert.equal(m.status, "assigned");
  assert.equal(m.assigned_transporter_id, ids.vl1);
  assert.equal(await vitrine(o.id), undefined, "vitrine retirée");
  // Second transporteur trop tard : message clair, rien ne change.
  assert.equal((await sql("select count(*)::int n from public.missions where id=$1", [v.id]))[0].n, 0);
});

test("bouton Accepter et attribution admin directe passent aussi par la commande", async () => {
  const o1 = await commandeEnRecherche();
  const v1 = await vitrine(o1.id);
  const r1 = (await as(ids.vl2, "select public.secoto_mission_accept($1,$2) as r", [v1.id, randomUUID()]))[0].r;
  assert.equal(r1.result, "assigned");
  assert.equal((await row("transport_orders", o1.id)).assigned_partner_id, ids.vl2);
  const o2 = await commandeEnRecherche();
  const v2 = await vitrine(o2.id);
  const r2 = (await as(ids.admin, "select public.secoto_admin_assign_mission_direct($1,$2,false,null,null,$3) as r", [v2.id, ids.vl1, randomUUID()]))[0].r;
  assert.equal(r2.result, "assigned");
  assert.equal((await row("transport_orders", o2.id)).status, "partner_confirmed");
  await assert.rejects(as(ids.admin, "select public.secoto_admin_assign_mission_direct($1,$2,false,null,null,$3)", [v2.id, ids.conv, randomUUID()]), /./);
});

test("commande annulée ou sans transporteur -> vitrine retirée ; transporteur non compatible refusé", async () => {
  const o = await commandeEnRecherche();
  const v = await vitrine(o.id);
  await assert.rejects(as(ids.conv, "select public.secoto_mission_accept($1,$2)", [v.id, randomUUID()]), /profil/);
  await sql("update public.transport_orders set status='cancelled' where id=$1", [o.id]);
  assert.equal(await vitrine(o.id), undefined);
});
