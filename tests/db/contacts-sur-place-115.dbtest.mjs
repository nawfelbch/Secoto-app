// Tests d'intégration base de données — migration 115 (contacts sur place).
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


async function commandeEnRecherche(client) {
  const q = await quote(client);
  const o = await book(client, q.id);
  await cardSaved(o.payment_id);
  return o;
}
const contacts = (client, orderId, enl, liv) =>
  as(client, "select public.secoto_od_contacts_sur_place($1,$2,$3) as r", [orderId, JSON.stringify(enl), JSON.stringify(liv)]).then((r) => r[0].r);

test.before(async () => {
  await sql("update public.secoto_feature_flags set enabled = true where key in ('auto_pricing','od_payments','direct_accept','dispatch_notifications','reglement_arrivee')");
  await sql("update public.secoto_feature_flags set enabled = false where key in ('plateau_paiement_direct','trois_offres','bareme_transporteurs')");
  await account("part", "client", { clientType: "particulier" });
  await account("pro", "client", { clientType: "pro" });
  await account("autre", "client", { clientType: "particulier" });
  await account("vl1", "transporter", { type: "vl" });
});
test.after(async () => { await pool.end(); });

test("particulier : téléphone obligatoire ; contacts reportés sur la mission du transporteur, jamais sur la vitrine", async () => {
  const o = await commandeEnRecherche(ids.part);
  await assert.rejects(contacts(ids.part, o.id, { nom: "Moi" }, { telephone: "0612345678" }), /téléphone du contact à l'enlèvement/);
  await assert.rejects(contacts(ids.part, o.id, { telephone: "12" }, { telephone: "0612345678" }), /invalide/);
  await assert.rejects(contacts(ids.autre, o.id, { telephone: "0611111111" }, { telephone: "0622222222" }), /introuvable/);
  const j = await contacts(ids.part, o.id, { nom: "Paul", telephone: "06 11 11 11 11" }, { telephone: "0622222222" });
  assert.equal(j.contact_enlevement.telephone, "+33611111111");
  assert.equal(j.client_pro, false);
  const vit = (await sql("select notes, client_phone from public.missions where od_order_id=$1", [o.id]))[0];
  assert.ok(vit && !String(vit.notes).includes("06 11"), "la vitrine publique ne reçoit pas les contacts");
  assert.equal((await sql("select phone from public.accounts where id=$1", [ids.part]))[0].phone, "+33611111111", "téléphone du compte complété");
  // Le transporteur accepte : la mission attribuée porte les contacts.
  const v = (await sql("select id from public.missions where od_order_id=$1", [o.id]))[0];
  await as(ids.vl1, "select public.secoto_mission_accept($1,$2)", [v.id, randomUUID()]);
  const ord = await row("transport_orders", o.id);
  const m = await row("missions", ord.mission_id);
  assert.match(m.notes, /\[Contacts sur place\] Enlèvement : Paul · 06 11 11 11 11 \| Livraison : 06 22 22 22 22/);
  assert.equal(m.client_phone, "+33611111111");
  // Correction après attribution : bloc remplacé, transporteur prévenu.
  await contacts(ids.part, o.id, { nom: "Paul", telephone: "0633333333" }, { telephone: "0622222222" });
  const m2 = await row("missions", ord.mission_id);
  assert.equal((m2.notes.match(/\[Contacts sur place\]/g) || []).length, 1);
  assert.match(m2.notes, /06 33 33 33 33/);
  assert.ok((await sql("select count(*)::int n from public.notifications where account_id=$1 and title='Contacts sur place mis à jour'", [ids.vl1]))[0].n >= 1);
});

test("professionnel : un nom de garage suffit", async () => {
  const o = await commandeEnRecherche(ids.pro);
  await assert.rejects(contacts(ids.pro, o.id, {}, { nom: "Garage B" }), /nom/);
  const j = await contacts(ids.pro, o.id, { nom: "Garage A" }, { nom: "Concession B" });
  assert.equal(j.contact_enlevement.nom, "Garage A");
  assert.equal(j.contact_enlevement.telephone, null);
  assert.equal(j.client_pro, true);
});
