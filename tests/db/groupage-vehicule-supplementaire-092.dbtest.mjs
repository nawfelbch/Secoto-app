// Tests d'intégration base de données — migration 092 (2e véhicule sur le même plateau à −25 %).
// Exécution : PGURL=postgres://... node --test tests/db/groupage-vehicule-supplementaire-092.dbtest.mjs
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
const quotePayload = (over = {}) => ({
  mode: "plateau",
  pickup: { label: "1 rue de Test 92260 Fontenay-aux-Roses", city: "Fontenay-aux-Roses", postcode: "92260", lat: 48.79, lng: 2.29 },
  delivery: { label: "1 place Test 69002 Lyon", city: "Lyon", postcode: "69002", lat: 45.76, lng: 4.83 },
  vehicle: { model: "TEST Peugeot 308", class: "voiture", category: "standard", rolling: true, constraints: [] },
  schedule: { pickup_date: inDays(5), slot: "matin", flexibility_days: 0 },
  ...over,
});
async function createQuote(clientId, over = {}, km = 400) {
  const r = await service("select public.secoto_quote_create($1,$2,$3) as q",
    [clientId, JSON.stringify(quotePayload(over)), JSON.stringify({ distance_km: km, duration_min: 240, provider: "test" })]);
  return r[0].q;
}
async function book(clientId, over = {}, km = 400) {
  const q = await createQuote(clientId, over, km);
  return (await as(clientId, "select public.secoto_od_book_quote($1,false,$2) as r", [q.id, randomUUID()]))[0].r.order;
}
const setFlag = (on) => sql("update public.secoto_feature_flags set enabled = $1 where key = 'plateau_paiement_direct'", [on]);
const cardSaved = (paymentId, evt = `evt_${randomUUID()}`) =>
  service("select public.secoto_direct_card_saved($1,$2,'seti_test','pm_test') as r", [paymentId, evt]).then((r) => r[0].r);
const paidOld = (paymentId) => service("select public.secoto_od_apply_payment_event($1,$2,'payment_intent.succeeded','pi_' || $1::uuid::text,0,null,null) as r",
  [paymentId, `evt_${randomUUID()}`]);
const offerFor = async (orderId, partnerId) =>
  (await sql("select id from public.transport_offers where order_id=$1 and partner_id=$2 and status='sent'", [orderId, partnerId]))[0]?.id;
const accept = (partnerId, offerId) =>
  as(partnerId, "select public.secoto_offer_accept($1,$2) as r", [offerId, randomUUID()]).then((r) => r[0].r);
async function makeReady(partnerId, acct) {
  await sql(`update public.accounts set stripe_connect_account_id=$2, stripe_connect_status='active',
             stripe_transfers_enabled=true, stripe_payouts_enabled=true, stripe_card_payments_enabled=true, stripe_payouts_manual=true where id=$1`, [partnerId, acct]);
  await as(partnerId, "select public.secoto_carrier_accept_billing_mandate($1,$2,$3,$4,$5,$6)",
    ["2026-10-08", "TEST Transports SARL", "123 456 789", "1 rue du Test 92000 Nanterre", "franchise", null]);
}
// (circuit direct non utilisé ici)
// Acceptation complète du circuit direct, telle que l'enchaîne le serveur.
async function acceptAndCharge(order, partnerId) {
  const r = await accept(partnerId, await offerFor(order.id, partnerId));
  assert.equal(r.result, "pending_capture", JSON.stringify(r));
  const ctx = (await service("select public.secoto_direct_charge_context($1) as r", [order.id]))[0].r;
  const confirmed = (await service("select public.secoto_od_capture_result($1,true,null) as r", [order.id]))[0].r;
  await sql("update public.payments set provider_intent_id=$2 where id=$1", [order.payment_id, `pi_direct_${order.id}`]);
  return { ctx, confirmed };
}

test.before(async () => {
  await sql(`update public.app_settings set value = value || jsonb_build_object('sous_traitance_totale_since', '2026-09-01T00:00:00Z')
             where key = 'dispatch_policy' and value ->> 'sous_traitance_totale_since' is null`);
  await sql("update public.secoto_feature_flags set enabled = true where key in ('auto_pricing','od_payments','dispatch_notifications')");
  await sql("update public.secoto_feature_flags set enabled = false where key in ('plateau_paiement_direct','bareme_transporteurs')");
  await account("client", "client");
  await account("plateau", "transporter", { type: "vl" });
  await as(ids.plateau, "select public.secoto_update_dispatch_preferences($1)", [JSON.stringify({ available: true, notify_offline: true, zones: [] })]);
});
test.after(async () => { await pool.end(); });

const V = {
  voiture: { model: "TEST Audi Q5", class: "voiture", category: "standard", rolling: true, constraints: [] },
  utilitaire: { model: "TEST Peugeot Expert", class: "utilitaire", category: "standard", rolling: true, constraints: [] },
  moto: { model: "TEST Yamaha MT-07", class: "moto", category: "standard", rolling: true, constraints: [] },
  nonRoulante: { model: "TEST Lexus RX", class: "voiture", category: "standard", rolling: false, constraints: [] },
};
const groupe = (vehicles, km, mode = "plateau") => createQuote(ids.client, { mode, vehicle: vehicles[0], vehicles }, km);

test("092 : Benissa (Expert + Q5, 1463,5 km) = 3146,53 € client, 2707,47 € transporteur", async () => {
  const q = await groupe([V.utilitaire, V.voiture], 1463.5);
  assert.equal(q.status, "priced", JSON.stringify(q));
  assert.equal(q.client_price_cents, 314653);
  assert.equal(q.group_discount_cents, 43905);
  const row = (await sql("select partner_pay_cents, margin_cents, breakdown from public.transport_quotes where id=$1", [q.id]))[0];
  assert.equal(row.partner_pay_cents, 270747);
  assert.equal(row.margin_cents, 314653 - 270747);
  const d = row.breakdown.detail;
  assert.deepEqual(d.map((x) => [x.principal, x.client_cents, x.partner_cents]), [[true, 182938, 160985], [false, 131715, 109762]]);
  // Le client voit chaque véhicule au plein tarif, puis la remise.
  assert.deepEqual(q.lines.map((l) => l.label), ["Véhicule 1 - TEST Peugeot Expert", "Véhicule 2 - TEST Audi Q5", "Remise 2e véhicule sur le même plateau (−25 %)"]);
  assert.equal(q.lines[2].eur, -439.05);
});

test("092 : le véhicule le plus cher est toujours au plein tarif, quel que soit l'ordre", async () => {
  const a = await groupe([V.voiture, V.utilitaire], 1463.5);
  const b = await groupe([V.utilitaire, V.voiture], 1463.5);
  assert.equal(a.client_price_cents, b.client_price_cents);
});

test("092 : chaque véhicule garde au moins 10 % de marge, à toutes les distances", async () => {
  for (const km of [3, 30, 150, 600, 1400]) {
    for (const vs of [[V.voiture, V.voiture], [V.moto, V.moto, V.moto], [V.utilitaire, V.nonRoulante], [V.nonRoulante, V.nonRoulante], [V.moto, V.utilitaire, V.voiture]]) {
      const q = await groupe(vs, km);
      assert.equal(q.status, "priced", `${km} km ${JSON.stringify(q.manual_reason)}`);
      const row = (await sql("select partner_pay_cents, breakdown from public.transport_quotes where id=$1", [q.id]))[0];
      assert.ok(q.client_price_cents > row.partner_pay_cents, "SECOTO gagne toujours");
      for (const x of row.breakdown.detail) {
        assert.ok(x.client_cents - x.partner_cents >= Math.ceil(x.client_cents * 0.1), `${km} km : ${JSON.stringify(x)}`);
        assert.ok(x.partner_cents > 0);
      }
      // Le transporteur gagne plus qu'avec un seul véhicule.
      const seul = await createQuote(ids.client, { vehicle: vs[0] }, km);
      const pSeul = (await sql("select partner_pay_cents from public.transport_quotes where id=$1", [seul.id]))[0].partner_pay_cents;
      assert.ok(row.partner_pay_cents > pSeul);
    }
  }
});

test("092 : le treuil d'un véhicule non roulant reste entier", async () => {
  const q = await groupe([V.nonRoulante, V.nonRoulante], 500);
  assert.equal(q.client_price_cents, 121000); // 680 + (450 + 80)
});

test("092 : convoyage inchangé, aucune remise", async () => {
  const q = await groupe([V.voiture, V.voiture], 400, "convoyage");
  assert.equal(q.client_price_cents, 80000);
  assert.equal(q.group_discount_cents, 0);
});

test("092 : un réglage qui ferait perdre de l'argent est corrigé automatiquement", async () => {
  const p = (await sql("select params from public.pricing_grids where mode='plateau' and status='active'"))[0].params;
  const r = (await sql("select secoto_private.price_group_with_grid('plateau', $1::jsonb, 500, $2::jsonb, 72) as r",
    [JSON.stringify({ ...p, group_extra_client_pct: 60, group_extra_partner_pct: 0 }), JSON.stringify([V.voiture, V.voiture])]))[0].r;
  const extra = r.detail[1];
  assert.equal(extra.partner_cents, 50000);
  assert.ok(extra.client_cents - extra.partner_cents >= Math.ceil(extra.client_cents * 0.1), JSON.stringify(extra));
  const bad = (await sql("select secoto_private.price_group_with_grid('plateau', $1::jsonb, 500, $2::jsonb, 72) as r",
    [JSON.stringify({ ...p, group_extra_client_pct: 100 }), JSON.stringify([V.voiture, V.voiture])]))[0].r;
  assert.equal(bad.manual_reason, "reglage_groupage_invalide");
});

test("092 : commande payée → une mission par véhicule, rémunérations exactes", async () => {
  const q = await groupe([V.voiture, V.utilitaire], 500);
  const order = (await as(ids.client, "select public.secoto_od_book_quote($1,false,$2) as r", [q.id, randomUUID()]))[0].r.order;
  await paidOld(order.payment_id);
  const offre = await offerFor(order.id, ids.plateau);
  assert.ok(offre, "offre envoyée au transporteur plateau");
  const r = await accept(ids.plateau, offre);
  assert.ok(["confirmed", "accepted", "pending_capture"].includes(r.result), JSON.stringify(r));
  const o = (await sql("select client_price_cents, partner_pay_cents from public.transport_orders where id=$1", [order.id]))[0];
  const m = await sql("select groupage_rank, vehicle, manual_carrier_pay::numeric pay, manual_margin::numeric marge from public.missions where groupage_order_id=$1 order by groupage_rank", [order.id]);
  assert.equal(m.length, 2);
  // Missions dans l'ordre saisi : voiture (à −25 % : 450 € / 375 €), puis
  // utilitaire (le plus cher, plein tarif : 625 € / 550 €).
  assert.equal(o.client_price_cents, 107500);
  assert.equal(o.partner_pay_cents, 92500);
  assert.equal(Math.round(m.reduce((s, x) => s + Number(x.pay), 0) * 100), o.partner_pay_cents);
  assert.equal(Math.round(m.reduce((s, x) => s + Number(x.marge), 0) * 100), o.client_price_cents - o.partner_pay_cents);
  assert.deepEqual(m.map((x) => [x.vehicle, Number(x.pay), Number(x.marge)]), [["TEST Audi Q5", 375, 75], ["TEST Peugeot Expert", 550, 75]]);
});
