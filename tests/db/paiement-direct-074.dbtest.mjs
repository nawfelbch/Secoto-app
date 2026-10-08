// Tests d'intégration base de données — migration 074 (paiement direct plateau).
// Exécution : PGURL=postgres://... node --test tests/db/paiement-direct-074.dbtest.mjs
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
  await sql("update public.secoto_feature_flags set enabled = true where key in ('auto_pricing','od_payments','connect_payouts','direct_accept','dispatch_notifications')");
  await account("client", "client");
  await account("other", "client");
  await account("convoyeur", "transporter", { type: "convoyeur" });
  await account("ready", "transporter", { type: "vl" });
  await account("notReady", "transporter", { type: "vl" });
  for (const k of ["convoyeur", "ready", "notReady"]) {
    await as(ids[k], "select public.secoto_update_dispatch_preferences($1)", [JSON.stringify({ available: true, notify_offline: true, zones: ["92"] })]);
  }
  await makeReady(ids.ready, "acct_test_ready");
});
test.after(async () => { await setFlag(false); await pool.end(); });

test("interrupteur éteint : le plateau reste dans l'ancien circuit, rien ne change", async () => {
  await setFlag(false);
  const order = await book(ids.client);
  assert.equal(order.payment_circuit, null);
  assert.equal(order.payment_strategy, "capture_then_refund");
  const p = (await sql("select payment_circuit, capture_method from public.payments where id=$1", [order.payment_id]))[0];
  assert.equal(p.payment_circuit, null);
  assert.equal(p.capture_method, "automatic");
});

test("interrupteur allumé : le convoyage n'est pas touché", async () => {
  await setFlag(true);
  const order = await book(ids.client, { mode: "convoyage" }, 200);
  assert.equal(order.payment_circuit, null);
  assert.equal(order.payment_strategy, "capture_then_refund");
  assert.equal((await sql("select payment_circuit from public.payments where id=$1", [order.payment_id]))[0].payment_circuit, null);
});

let direct;
test("plateau direct : carte validée sans débit, puis diffusion", async () => {
  await setFlag(true);
  direct = await book(ids.client);
  assert.equal(direct.payment_circuit, "direct");
  assert.equal(direct.payment_strategy, "authorize_then_capture");
  assert.equal((await sql("select count(*)::int n from public.transport_offers where order_id=$1", [direct.id]))[0].n, 0,
    "aucune diffusion avant la validation de la carte");

  const saved = await cardSaved(direct.payment_id, "evt_seti_1");
  assert.equal(saved.status, "requires_capture");
  assert.equal(saved.effect, "dispatch_opened");
  const replay = await cardSaved(direct.payment_id, "evt_seti_1");
  assert.equal(replay.reason, "event_already_processed");
  const pay = (await sql("select status, saved_payment_method_id, provider_intent_id from public.payments where id=$1", [direct.payment_id]))[0];
  assert.equal(pay.status, "requires_capture");
  assert.equal(pay.saved_payment_method_id, "pm_test");
  assert.equal(pay.provider_intent_id, null, "aucun paiement créé chez SECOTO");
  const notif = await sql("select title from public.notifications where account_id=$1 and title='Carte validée'", [ids.client]);
  assert.equal(notif.length, 1);
  assert.ok(await offerFor(direct.id, ids.ready), "le transporteur prêt reçoit la proposition");
  assert.ok(await offerFor(direct.id, ids.notReady), "le transporteur sans compte de paiement VOIT aussi la proposition");
});

test("transporteur sans compte de paiement : il voit, mais ne peut pas accepter", async () => {
  const r = await accept(ids.notReady, await offerFor(direct.id, ids.notReady));
  assert.equal(r.result, "payment_account_required");
  const o = (await sql("select status, lock_partner_id from public.transport_orders where id=$1", [direct.id]))[0];
  assert.equal(o.status, "searching_partner", "la commande reste disponible pour les autres");
  assert.equal(o.lock_partner_id, null);
  const status = (await as(ids.notReady, "select public.secoto_carrier_direct_status() as r"))[0].r;
  assert.equal(status.ready, false);
  assert.equal(status.card_payments, false);
});

test("acceptation : débit chez le transporteur, commission = prix client - paie transporteur", async () => {
  const { ctx, confirmed } = await acceptAndCharge(direct, ids.ready);
  const o = (await sql("select client_price_cents, partner_pay_cents from public.transport_orders where id=$1", [direct.id]))[0];
  assert.equal(ctx.connected_account_id, "acct_test_ready");
  assert.equal(ctx.amount_cents, o.client_price_cents);
  assert.equal(ctx.application_fee_cents, o.client_price_cents - o.partner_pay_cents);
  assert.equal(ctx.payment_method_id, "pm_test");
  assert.equal(ctx.partner_ready, true);
  assert.equal(confirmed.result, "confirmed");
  const pay = (await sql("select status, connected_account_id, application_fee_cents from public.payments where id=$1", [direct.payment_id]))[0];
  assert.equal(pay.status, "paid");
  assert.equal(pay.connected_account_id, "acct_test_ready");
  direct.mission_id = confirmed.mission_id;
});

test("webhook du compte transporteur : facture au nom du transporteur + facture de commission, sans doublon", async () => {
  const ev = (id) => service("select public.secoto_od_apply_payment_event($1,$2,'payment_intent.succeeded',$3,0,null,null) as r",
    [direct.payment_id, id, `pi_direct_${direct.id}`]);
  await ev("evt_conn_succ_1");
  await ev("evt_conn_succ_2");
  const inv = await sql("select kind, number, amount_cents, body from public.partner_invoices where order_id=$1 order by kind", [direct.id]);
  assert.equal(inv.length, 2, JSON.stringify(inv));
  const client = inv.find((i) => i.kind === "client_on_behalf");
  const fee = inv.find((i) => i.kind === "commission");
  assert.match(client.number, /^TR\d{4}-0001$/);
  assert.match(client.body, /au nom et pour le compte de TEST Transports SARL/);
  assert.match(client.body, /SIREN 123456789/);
  assert.match(client.body, /TVA non applicable/);
  const o = (await sql("select client_price_cents, partner_pay_cents, invoice_number from public.transport_orders where id=$1", [direct.id]))[0];
  assert.equal(o.invoice_number, client.number);
  assert.equal(fee.amount_cents, o.client_price_cents - o.partner_pay_cents);
  assert.match(fee.body, /prelev/);
  // Cloisonnement : le client voit sa facture, pas la facture de commission.
  const seenByClient = await as(ids.client, "select kind from public.partner_invoices where order_id=$1", [direct.id]);
  assert.deepEqual(seenByClient.map((r) => r.kind), ["client_on_behalf"]);
  const seenByOther = await as(ids.other, "select kind from public.partner_invoices where order_id=$1", [direct.id]);
  assert.equal(seenByOther.length, 0);
  const seenByPartner = await as(ids.ready, "select kind from public.partner_invoices where order_id=$1 order by kind", [direct.id]);
  assert.equal(seenByPartner.length, 2);
});

test("livraison : argent retenu chez le transporteur, viré vers SA banque 4 h après, JAMAIS de Transfer", async () => {
  await sql("update public.missions set progress_status='delivery_completed', status='completed' where id=$1", [direct.mission_id]);
  const pp = (await sql("select *, due_at > now() + interval '3 hours' as plus_tard from public.partner_payouts where mission_id=$1", [direct.mission_id]))[0];
  assert.equal(pp.payment_circuit, "direct");
  assert.equal(pp.connected_account_id, "acct_test_ready");
  assert.equal(pp.status, "to_pay", "076 : virement bancaire à déclencher par SECOTO");
  assert.equal(pp.paid_via, null);
  assert.equal(pp.plus_tard, true, "échéance = livraison + 4 h");
  const avant = (await service("select public.secoto_direct_payouts_claim_due(50) as r"))[0].r;
  assert.ok(!avant.some((x) => x.payout_id === pp.id), "rien avant l'échéance");
  await sql("update public.partner_payouts set due_at = now() - interval '1 minute' where id=$1", [pp.id]);
  const du = (await service("select public.secoto_direct_payouts_claim_due(50) as r"))[0].r.find((x) => x.payout_id === pp.id);
  assert.ok(du, "virement réclamé à l'échéance");
  assert.equal(du.connected_account_id, "acct_test_ready");
  assert.equal(du.amount_cents, pp.amount_cents);
  // Fonds pas encore disponibles chez Stripe : nouvel essai, rien de perdu.
  const attente = (await service("select public.secoto_payout_transfer_result($1,false,null,null,'balance_insufficient') as r", [pp.id]))[0].r;
  assert.equal(attente.result, "attente_de_fonds");
  await sql("update public.partner_payouts set next_retry_at = now() - interval '1 minute' where id=$1", [pp.id]);
  assert.ok((await service("select public.secoto_direct_payouts_claim_due(50) as r"))[0].r.some((x) => x.payout_id === pp.id));
  const ok = (await service("select public.secoto_payout_transfer_result($1,true,'po_test',null,null) as r", [pp.id]))[0].r;
  assert.equal(ok.result, "paid");
  assert.equal((await sql("select count(*)::int n from public.connect_bank_payouts where source_payout_id=$1", [pp.id]))[0].n, 0,
    "un virement direct ne crée pas de second virement");
  const transfers = (await service("select public.secoto_payouts_claim_due(50) as r"))[0].r;
  assert.ok(!transfers.some((x) => x.payout_id === pp.id), "aucun Transfer pour une course encaissée en direct");
  const tick = (await service("select public.secoto_od_maintenance_tick() as r"))[0].r;
  assert.ok(tick, "aucun rappel « versement à effectuer » pour une course payée en direct");
  const n = await sql("select title, body from public.notifications where account_id=$1 and title='Mission livrée' order by created_at desc limit 1", [ids.ready]);
  assert.match(n[0].body, /compte bancaire sous 4 h/);
});

test("ancien circuit (courses déjà payées) : versement par Transfer inchangé, ignoré par le circuit direct", async () => {
  await setFlag(false);
  const old = await book(ids.client);
  await paidOld(old.payment_id);
  await setFlag(true); // interrupteur rallumé : la commande ancienne ne change pas de circuit
  const r = await accept(ids.notReady, await offerFor(old.id, ids.notReady));
  assert.equal(r.result, "confirmed", "ancien circuit : pas d'exigence de compte de paiement");
  await sql("update public.missions set progress_status='delivery_completed', status='completed' where id=$1", [r.mission_id]);
  const pp = (await sql("select * from public.partner_payouts where mission_id=$1", [r.mission_id]))[0];
  assert.equal(pp.payment_circuit, null);
  await sql("update public.accounts set stripe_connect_account_id='acct_test_old', stripe_transfers_enabled=true where id=$1", [ids.notReady]);
  await sql("update public.partner_payouts set due_at = now() - interval '1 minute' where id=$1", [pp.id]);
  const transfers = (await service("select public.secoto_payouts_claim_due(50) as r"))[0].r;
  assert.ok(transfers.some((x) => x.payout_id === pp.id), "le Transfer historique part toujours");
  await sql("update public.accounts set stripe_connect_account_id=null, stripe_transfers_enabled=false where id=$1", [ids.notReady]);
});

async function chargedOrder(pickupInHours) {
  await setFlag(true);
  const o = await book(ids.client);
  await cardSaved(o.payment_id);
  const { confirmed } = await acceptAndCharge(o, ids.ready);
  await sql("update public.transport_orders set pickup_at = now() + make_interval(hours => $2) where id=$1", [o.id, pickupInHours]);
  return { ...o, mission_id: confirmed.mission_id };
}
const cancel = (orderId) => as(ids.client, "select public.secoto_od_cancel_order($1,$2) as r", [orderId, randomUUID()]).then((r) => r[0].r);

test("annulation plus de 24 h avant : remboursement intégral, rien de retenu", async () => {
  const o = await chargedOrder(72);
  await cancel(o.id);
  const p = (await sql("select status, refund_requested_cents, amount_cents from public.payments where id=$1", [o.payment_id]))[0];
  assert.equal(p.status, "refund_pending");
  assert.equal(p.refund_requested_cents, p.amount_cents);
  assert.equal((await sql("select count(*)::int n from public.partner_payouts where mission_id=$1 and status='to_pay'", [o.mission_id]))[0].n, 0);
  const action = (await service("select public.secoto_od_maintenance_tick() as r"))[0].r.payment_actions.find((a) => a.payment_id === o.payment_id);
  assert.equal(action.action, "refund");
  assert.equal(action.circuit, "direct", "le serveur rembourse sur le compte du transporteur");
  assert.equal(action.connected_account_id, "acct_test_ready");
});

test("annulation entre 24 h et 2 h : 50 % remboursés, part du transporteur au prorata", async () => {
  const o = await chargedOrder(12);
  const preview = (await as(ids.client, "select public.secoto_od_cancel_quote_preview($1) as r", [o.id]))[0].r;
  assert.equal(preview.retained_pct, 50);
  assert.equal(preview.charged, true);
  assert.equal(preview.last_minute, false);
  await cancel(o.id);
  const ord = (await sql("select client_price_cents, partner_pay_cents from public.transport_orders where id=$1", [o.id]))[0];
  const p = (await sql("select status, refund_requested_cents from public.payments where id=$1", [o.payment_id]))[0];
  assert.equal(p.status, "refund_pending");
  assert.equal(p.refund_requested_cents, ord.client_price_cents - Math.round(ord.client_price_cents * 0.5));
  const pp = (await sql("select kind, amount_cents, payment_circuit, status from public.partner_payouts where mission_id=$1", [o.mission_id]))[0];
  assert.equal(pp.kind, "late_cancel");
  assert.equal(pp.payment_circuit, "direct");
  assert.equal(pp.status, "to_pay", "part retenue virée vers la banque du transporteur");
  assert.equal(pp.amount_cents, Math.round(ord.partner_pay_cents * 0.5));
});

test("annulation à moins de 2 h : aucun remboursement, part du transporteur intégralement versée", async () => {
  const o = await chargedOrder(1);
  const preview = (await as(ids.client, "select public.secoto_od_cancel_quote_preview($1) as r", [o.id]))[0].r;
  assert.equal(preview.retained_pct, 100);
  assert.equal(preview.last_minute, true);
  assert.equal(preview.refund_cents, 0);
  await cancel(o.id);
  const ord = (await sql("select status, partner_pay_cents from public.transport_orders where id=$1", [o.id]))[0];
  assert.equal(ord.status, "cancelled");
  const p = (await sql("select status, refund_requested_cents from public.payments where id=$1", [o.payment_id]))[0];
  assert.equal(p.status, "paid", "rien à rembourser");
  assert.equal(p.refund_requested_cents, null);
  const pp = (await sql("select amount_cents, payment_circuit, status from public.partner_payouts where mission_id=$1", [o.mission_id]))[0];
  assert.equal(pp.amount_cents, ord.partner_pay_cents);
  assert.equal(pp.status, "to_pay", "la part du transporteur est virée vers sa banque");
  assert.ok((await service("select public.secoto_direct_payouts_claim_due(50) as r"))[0].r.some((x) => x.kind === "late_cancel"),
    "annulation tardive : virement immédiat, sans attendre une livraison");
  const n = await sql("select body from public.notifications where account_id=$1 and title='Commande annulée' order by created_at desc limit 1", [ids.client]);
  assert.match(n[0].body, /dernière minute/);
});

test("annulation sans transporteur : la carte n'a jamais été débitée", async () => {
  await setFlag(true);
  const o = await book(ids.client);
  await cardSaved(o.payment_id);
  await sql("update public.transport_orders set pickup_at = now() + interval '1 hour' where id=$1", [o.id]);
  const preview = (await as(ids.client, "select public.secoto_od_cancel_quote_preview($1) as r", [o.id]))[0].r;
  assert.equal(preview.charged, false);
  assert.equal(preview.retained_pct, 0, "jamais débité : rien n'est retenu, même à la dernière minute");
  await cancel(o.id);
  const p = (await sql("select status, release_requested_at from public.payments where id=$1", [o.payment_id]))[0];
  assert.equal(p.status, "requires_capture");
  assert.ok(p.release_requested_at);
  const action = (await service("select public.secoto_od_maintenance_tick() as r"))[0].r.payment_actions.find((a) => a.payment_id === o.payment_id);
  assert.equal(action.action, "cancel");
  assert.equal(action.intent_id, null, "rien à annuler chez Stripe");
  await service("select public.secoto_od_payment_action_result($1,'cancel',true,null)", [o.payment_id]);
  assert.equal((await sql("select status from public.payments where id=$1", [o.payment_id]))[0].status, "cancelled");
  const n = await sql("select body from public.notifications where account_id=$1 and title='Commande annulée' order by created_at desc limit 1", [ids.client]);
  assert.match(n[0].body, /pas été débitée/);
});

test("validation bancaire demandée : mission réservée, puis confirmée par le webhook", async () => {
  await setFlag(true);
  const o = await book(ids.client);
  await cardSaved(o.payment_id);
  const r = await accept(ids.ready, await offerFor(o.id, ids.ready));
  assert.equal(r.result, "pending_capture");
  const na = (await service("select public.secoto_direct_charge_needs_action($1,'pi_action') as r", [o.id]))[0].r;
  assert.equal(na.result, "needs_action");
  const ord = (await sql("select status, lock_expires_at > now() + interval '100 minutes' as long from public.transport_orders where id=$1", [o.id]))[0];
  assert.equal(ord.status, "partner_locked");
  assert.equal(ord.long, true, "le transporteur garde la mission le temps de la validation");
  const n = await sql("select title from public.notifications where account_id=$1 and title='Validez votre paiement'", [ids.client]);
  assert.ok(n.length >= 1);
  const ev = (await service("select public.secoto_od_apply_payment_event($1,'evt_action_ok','payment_intent.succeeded','pi_action',0,null,null) as r", [o.payment_id]))[0].r;
  assert.equal(ev.effect, "confirmed");
  assert.equal((await sql("select status from public.transport_orders where id=$1", [o.id]))[0].status, "partner_confirmed");
});

test("sécurité : fonctions serveur interdites à l'application, mandat contrôlé", async () => {
  await assert.rejects(as(ids.client, "select public.secoto_direct_card_saved($1,'x','y','z')", [randomUUID()]), /permission denied/);
  await assert.rejects(as(ids.ready, "select public.secoto_direct_charge_context($1)", [randomUUID()]), /permission denied/);
  await assert.rejects(as(ids.client, "select public.secoto_carrier_accept_billing_mandate('v','A','123456789','adr','franchise',null)"), /transporteurs/);
  await assert.rejects(as(ids.notReady, "select public.secoto_carrier_accept_billing_mandate('v','A','1234','adr','franchise',null)"), /9 chiffres/);
  await assert.rejects(as(ids.notReady, "select public.secoto_carrier_accept_billing_mandate('v','A','123456789','adr','assujetti','XX')"), /TVA/);
  await assert.rejects(as(ids.client, "select * from public.partner_invoice_counters"), /permission denied/);
});

// ---------------------------------------------------------------------------
// 076 — argent retenu jusqu'à la livraison
// ---------------------------------------------------------------------------
test("076 : sans virement manuel chez Stripe, le transporteur n'est pas prêt", async () => {
  await sql("update public.accounts set stripe_payouts_manual=false where id=$1", [ids.ready]);
  try {
    const st = (await as(ids.ready, "select public.secoto_carrier_direct_status() as r"))[0].r;
    assert.equal(st.ready, false);
    assert.equal(st.payouts_manual, false);
    await assert.rejects(as(ids.ready, "update public.accounts set stripe_payouts_manual=true where id=$1", [ids.ready]), /ne se modifient que depuis SECOTO|permission denied/);
  } finally {
    await sql("update public.accounts set stripe_payouts_manual=true where id=$1", [ids.ready]);
  }
  assert.equal((await as(ids.ready, "select public.secoto_carrier_direct_status() as r"))[0].r.ready, true);
});

test("076 : pas de virement tant que la course n'est pas livrée, ni pendant un litige", async () => {
  const o = await chargedOrder(48);
  await sql(`insert into public.partner_payouts(mission_id, order_id, partner_id, amount_cents, due_at, mode, kind)
             values ($1,$2,$3,1000, now() - interval '1 minute','plateau','mission')`, [o.mission_id, o.id, ids.ready]);
  const pp = (await sql("select id, status from public.partner_payouts where mission_id=$1", [o.mission_id]))[0];
  assert.equal(pp.status, "to_pay");
  let due = (await service("select public.secoto_direct_payouts_claim_due(50) as r"))[0].r;
  assert.ok(!due.some((x) => x.payout_id === pp.id), "course non livrée : l'argent reste retenu");
  await sql("update public.transport_orders set status='delivered' where id=$1", [o.id]);
  await sql("update public.payments set dispute_status='open' where id=$1", [o.payment_id]);
  due = (await service("select public.secoto_direct_payouts_claim_due(50) as r"))[0].r;
  assert.ok(!due.some((x) => x.payout_id === pp.id), "litige ouvert : rien ne part");
  await sql("update public.payments set dispute_status='closed' where id=$1", [o.payment_id]);
  due = (await service("select public.secoto_direct_payouts_claim_due(50) as r"))[0].r;
  assert.ok(due.some((x) => x.payout_id === pp.id), "livrée et sans litige : virement");
});

test("076 : un Transfer de l'ancien circuit reçu par un compte en virement manuel part vers sa banque", async () => {
  await setFlag(false);
  const old = await book(ids.client);
  await paidOld(old.payment_id);
  await setFlag(true);
  const r = await accept(ids.ready, await offerFor(old.id, ids.ready));
  assert.equal(r.result, "confirmed");
  await sql("update public.missions set progress_status='delivery_completed', status='completed' where id=$1", [r.mission_id]);
  const pp = (await sql("select id, payment_circuit, status from public.partner_payouts where mission_id=$1", [r.mission_id]))[0];
  assert.equal(pp.payment_circuit, null, "ancien circuit inchangé");
  assert.equal(pp.status, "to_pay");
  await sql("update public.partner_payouts set status='processing', processing_at=now() where id=$1", [pp.id]);
  const res = (await service("select public.secoto_payout_transfer_result($1,true,'tr_test',null,null) as r", [pp.id]))[0].r;
  assert.equal(res.result, "paid");
  const due = (await service("select public.secoto_bank_payouts_claim_due(50) as r"))[0].r;
  const b = due.find((x) => x.connected_account_id === "acct_test_ready");
  assert.ok(b, "virement bancaire du Transfer reçu");
  const fin = (await service("select public.secoto_bank_payout_result($1,true,'po_bank',null) as r", [b.bank_payout_id]))[0].r;
  assert.equal(fin.result, "paid");
  await assert.rejects(as(ids.ready, "select * from public.connect_bank_payouts"), /permission denied/);
});
