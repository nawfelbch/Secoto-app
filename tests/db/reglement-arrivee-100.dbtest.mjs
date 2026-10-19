// Tests d'intégration base de données — migration 100 (règlement à l'arrivée).
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
const VL = ["vl1", "vl2", "vl3"];

// Réservation complète jusqu'à la livraison, avec le mode choisi.
async function commandeLivree(mode = "carte", partner = "vl1", km = 400) {
  const q = await quote(ids.client, km);
  const o = await book(ids.client, q.id);
  if (mode !== "carte") await choisir(ids.client, o.id, mode);
  await cardSaved(o.payment_id);
  assert.equal((await accept(ids[partner], await offerFor(o.id, ids[partner]))).result, "pending_capture");
  assert.equal((await confirmer(o.id)).result, "confirmed");
  const ord = await row("transport_orders", o.id);
  await sql("update public.missions set progress_status='delivery_completed', status='completed' where id=$1", [ord.mission_id]);
  return { order: await row("transport_orders", o.id), paymentId: o.payment_id };
}

test.before(async () => {
  await sql(`update public.app_settings set value = value || jsonb_build_object('sous_traitance_totale_since', '2026-09-01T00:00:00Z')
             where key = 'dispatch_policy' and value ->> 'sous_traitance_totale_since' is null`);
  await sql("update public.secoto_feature_flags set enabled = true where key in ('auto_pricing','od_payments','connect_payouts','direct_accept','dispatch_notifications')");
  await sql("update public.secoto_feature_flags set enabled = false where key in ('plateau_paiement_direct','trois_offres','bareme_transporteurs')");
  await sql(`insert into public.app_settings(key, value) values ('bank_details', '{"titulaire":"SECOTO TEST","iban":"FR76 TEST 0000 0000 0000 0000 000","bic":"TESTFRPP"}')
             on conflict (key) do update set value = excluded.value`);
  await account("client", "client");
  await account("autre", "client");
  await account("admin", "admin");
  for (const k of VL) await account(k, "transporter", { type: "vl" });
  for (const k of VL) {
    await as(ids[k], "select public.secoto_update_dispatch_preferences($1)", [JSON.stringify({ available: true, notify_offline: true, zones: ["92"] })]);
  }
});
test.after(async () => { await flag("reglement_arrivee", false); await pool.end(); });

test("interrupteur éteint : paiement immédiat inchangé, choix du mode refusé", async () => {
  await flag("reglement_arrivee", false);
  const q = await quote(ids.client);
  const o = await book(ids.client, q.id);
  const pay = await row("payments", o.payment_id);
  assert.equal(pay.debit_a_livraison, false);
  assert.equal(pay.debit_a_confirmation, false);
  assert.equal(pay.capture_method, "automatic");
  assert.equal((await row("transport_orders", o.id)).mode_reglement, null);
  await assert.rejects(choisir(ids.client, o.id, "carte"), /pas encore ouvert/);
});

test("réservation : carte enregistrée, 0 € prélevé ; confirmation du transporteur sans aucun débit", async () => {
  await flag("reglement_arrivee", true);
  const q = await quote(ids.client);
  const o = await book(ids.client, q.id);
  let pay = await row("payments", o.payment_id);
  assert.equal(pay.debit_a_livraison, true);
  assert.equal(pay.debit_a_confirmation, true);
  assert.equal(pay.capture_method, "manual");
  const ord = await row("transport_orders", o.id);
  assert.equal(ord.mode_reglement, "carte");
  assert.equal(ord.payment_strategy, "authorize_then_capture");
  const vue = await clientOrder(o.id);
  assert.equal(vue.debit_a_livraison, true);
  assert.equal(vue.mode_reglement, "carte");
  assert.equal(vue.virement_possible, true);

  await cardSaved(o.payment_id);
  const n = await sql("select body from public.notifications where account_id=$1 and title='Carte validée' order by created_at desc limit 1", [ids.client]);
  assert.match(n[0].body, /0 € prélevé/);
  assert.equal((await accept(ids.vl1, await offerFor(o.id, ids.vl1))).result, "pending_capture");
  const ctx = (await service("select public.secoto_differe_charge_context($1) as r", [o.id]))[0].r;
  assert.equal(ctx.debit_a_livraison, true);
  assert.equal(ctx.mode_reglement, "carte");
  await assert.rejects(as(ids.client, "select public.secoto_reglement_confirmer($1)", [o.id]), /permission denied/);
  const c = await confirmer(o.id);
  assert.equal(c.result, "confirmed");
  pay = await row("payments", o.payment_id);
  assert.equal(pay.status, "requires_capture", "toujours rien de prélevé");
  assert.equal(pay.paid_at, null);
  assert.equal((await row("transport_orders", o.id)).status, "partner_confirmed");
  // Après confirmation, le mode ne change plus.
  await assert.rejects(choisir(ids.client, o.id, "virement"), /ne peut plus être changé/);
  await assert.rejects(choisir(ids.autre, o.id, "carte"), /introuvable/);
});

test("carte : prélèvement automatique à la livraison, puis versement au transporteur", async () => {
  await flag("reglement_arrivee", true);
  const { order, paymentId } = await commandeLivree("carte");
  assert.equal(order.status, "delivered");
  let pay = await row("payments", paymentId);
  assert.ok(Date.parse(pay.reglement_echeance) <= Date.now() + 1000);
  const payout = (await sql("select * from public.partner_payouts where order_id=$1", [order.id]))[0];
  assert.equal(payout.status, "to_pay");
  const lot = await aDebiter();
  const ligne = lot.find((x) => x.payment_id === paymentId);
  assert.ok(ligne, JSON.stringify(lot));
  assert.equal(ligne.amount_cents, order.client_price_cents);
  assert.equal(ligne.payment_method_id, "pm_test");
  assert.equal((await aDebiter()).some((x) => x.payment_id === paymentId), false, "pas repris avant 15 minutes");
  const r = await resultat(paymentId, "reussi");
  assert.equal(r.result, "paid");
  pay = await row("payments", paymentId);
  assert.equal(pay.status, "paid");
  assert.ok((await row("transport_orders", order.id)).invoice_number, "facture émise");
  const n = await sql("select title from public.notifications where event_key=$1", [`od-reglement-paye:${order.id}`]);
  assert.equal(n[0].title, "Paiement effectué");
  assert.equal((await resultat(paymentId, "reussi")).result, "paid", "rejoué : sans effet");
});

test("carte refusée : client invité à payer, nouvel essai 24 h plus tard, 3 essais au plus", async () => {
  await flag("reglement_arrivee", true);
  const { order, paymentId } = await commandeLivree("carte");
  assert.ok((await aDebiter()).some((x) => x.payment_id === paymentId));
  const r = await resultat(paymentId, "refuse", "card_declined");
  assert.equal(r.result, "capture_failed");
  const pay = await row("payments", paymentId);
  assert.equal(pay.status, "capture_failed");
  assert.equal(pay.reglement_tentatives, 1);
  assert.ok(Date.parse(pay.reglement_echeance) > Date.now() + 23 * 3600e3);
  const vue = await clientOrder(order.id);
  assert.equal(vue.reglement_a_payer, true);
  assert.equal(vue.payment_status, "capture_failed");
  assert.equal((await aDebiter()).some((x) => x.payment_id === paymentId), false);
  await sql("update public.payments set reglement_tentatives = 3, reglement_echeance = now() - interval '1 minute', reglement_debit_tente_at = null where id=$1", [paymentId]);
  assert.equal((await aDebiter()).some((x) => x.payment_id === paymentId), false, "plus d'essai automatique après 3");
  // Le client paie lui-même (webhook Stripe) : la commande est réglée.
  await service("select public.secoto_od_apply_payment_event($1,$2,'payment_intent.succeeded','pi_client',0,null,null)", [paymentId, `evt_${randomUUID()}`]);
  assert.equal((await row("payments", paymentId)).status, "paid");
});

test("virement : IBAN et référence envoyés à la livraison, carte prélevée après 48 h sans virement", async () => {
  await flag("reglement_arrivee", true);
  const { order, paymentId } = await commandeLivree("virement");
  const pay = await row("payments", paymentId);
  assert.ok(Math.abs(Date.parse(pay.reglement_echeance) - (Date.now() + 48 * 3600e3)) < 120e3);
  const mail = (await sql("select * from public.email_outbox where event_key=$1", [`od-reglement-virement:${order.id}`]))[0];
  assert.ok(mail, "e-mail avec l'IBAN");
  assert.match(mail.body_text, /FR76 TEST/);
  assert.match(mail.body_text, new RegExp(order.public_ref));
  const vue = await clientOrder(order.id);
  assert.equal(vue.virement.iban, "FR76 TEST 0000 0000 0000 0000 000");
  assert.equal(vue.virement.reference, order.public_ref);
  assert.equal(vue.reglement_a_payer, true);
  assert.equal((await aDebiter()).some((x) => x.payment_id === paymentId), false, "pas avant 48 h");
  await assert.rejects(as(ids.client, "select public.secoto_admin_virement_recu($1)", [order.id]), /administrateur/);
  const ok = (await as(ids.admin, "select public.secoto_admin_virement_recu($1) as r", [order.id]))[0].r;
  assert.equal(ok.result, "paid");
  assert.equal((await row("payments", paymentId)).status, "paid");
  assert.equal((await clientOrder(order.id)).virement, null);

  // Virement jamais reçu : la carte est prélevée à l'échéance.
  const b = await commandeLivree("virement", "vl2");
  await sql("update public.payments set reglement_echeance = now() - interval '1 minute' where id=$1", [b.paymentId]);
  assert.ok((await aDebiter()).some((x) => x.payment_id === b.paymentId));
});

test("Klarna : le client paie lui-même à la livraison, carte prélevée après 24 h", async () => {
  await flag("reglement_arrivee", true);
  const { order, paymentId } = await commandeLivree("klarna");
  const pay = await row("payments", paymentId);
  assert.ok(Math.abs(Date.parse(pay.reglement_echeance) - (Date.now() + 24 * 3600e3)) < 120e3);
  const n = await sql("select title from public.notifications where account_id=$1 and event_key=$2", [ids.client, `od-reglement-livraison:${order.id}`]);
  assert.match(n[0].title, /plusieurs fois/);
  assert.equal((await clientOrder(order.id)).reglement_a_payer, true);
});

test("espèces : plafond légal, transporteur prévenu avant d'accepter, déclaration, marge due", async () => {
  await flag("reglement_arrivee", true);
  // Plafond : 1 € pour l'essai -> refus.
  await sql("update public.app_settings set value = value || '{\"plafond_especes_eur\": 1}' where key='reglement_arrivee'");
  const q0 = await quote(ids.client);
  const o0 = await book(ids.client, q0.id);
  assert.equal((await clientOrder(o0.id)).especes_possible, false);
  await assert.rejects(choisir(ids.client, o0.id, "especes"), /limité à 1 €/);
  await sql("update public.app_settings set value = value || '{\"plafond_especes_eur\": 1000}' where key='reglement_arrivee'");

  const q = await quote(ids.client);
  const o = await book(ids.client, q.id);
  await choisir(ids.client, o.id, "especes");
  await cardSaved(o.payment_id);
  const offre = await partnerOffer(await offerFor(o.id, ids.vl3));
  assert.equal(offre.mode_reglement, "especes");
  const ord0 = await row("transport_orders", o.id);
  assert.equal(offre.especes_a_encaisser_cents, ord0.client_price_cents);
  assert.equal(offre.commission_a_reverser_cents, ord0.client_price_cents - ord0.partner_pay_cents);
  assert.equal((await accept(ids.vl3, await offerFor(o.id, ids.vl3))).result, "pending_capture");
  await confirmer(o.id);
  await sql("update public.missions set progress_status='delivery_completed', status='completed' where id=$1", [ord0.mission_id ?? (await row("transport_orders", o.id)).mission_id]);
  const ord = await row("transport_orders", o.id);
  assert.equal(ord.status, "delivered");
  assert.equal((await aDebiter()).some((x) => x.payment_id === o.payment_id), false, "jamais de prélèvement sans déclaration");
  const avis = await sql("select body from public.notifications where account_id=$1 and event_key=$2", [ids.vl3, `od-reglement-especes:${o.id}`]);
  assert.match(avis[0].body, /Marge SECOTO à reverser/);

  const mes = (await as(ids.vl3, "select public.secoto_mes_reglements() as r"))[0].r;
  assert.ok(mes.especes_a_declarer.some((x) => x.order_id === o.id));
  assert.equal((await as(ids.vl1, "select public.secoto_mes_reglements() as r"))[0].r.especes_a_declarer.some((x) => x.order_id === o.id), false);
  await assert.rejects(as(ids.client, "select public.secoto_reglement_especes($1,true)", [o.id]), /introuvable/);
  await assert.rejects(as(ids.vl1, "select public.secoto_reglement_especes($1,true)", [o.id]), /introuvable/);

  const r = (await as(ids.vl3, "select public.secoto_reglement_especes($1,true) as r", [o.id]))[0].r;
  assert.equal(r.result, "recu");
  const marge = ord.client_price_cents - ord.partner_pay_cents;
  assert.equal(r.commission_cents, marge);
  const pay = await row("payments", o.payment_id);
  assert.equal(pay.especes_statut, "recu");
  assert.equal(pay.status, "cancelled", "rien n'est prélevé sur la carte");
  const payout = (await sql("select status from public.partner_payouts where order_id=$1", [o.id]))[0];
  assert.equal(payout.status, "cancelled", "le transporteur a déjà tout encaissé");
  const due = (await sql("select * from public.commissions_dues where order_id=$1", [o.id]))[0];
  assert.equal(due.amount_cents, marge);
  assert.equal(due.statut, "due");
  assert.equal(due.partner_id, ids.vl3);
  const mes2 = (await as(ids.vl3, "select public.secoto_mes_reglements() as r"))[0].r;
  assert.equal(mes2.commissions[0].reste_cents, marge);
  assert.equal(mes2.bloque, false);
  assert.equal(mes2.virement.iban, "FR76 TEST 0000 0000 0000 0000 000");
  assert.equal((await as(ids.vl3, "select public.secoto_reglement_especes($1,false) as r", [o.id]))[0].r.result, "deja_declare");
  ids.dueVl3 = due.id;
});

test("marge en retard : missions suspendues, retenue sur le prochain versement, puis rétablies", async () => {
  await flag("reglement_arrivee", true);
  await sql("update public.commissions_dues set due_at = now() - interval '1 minute' where id=$1", [ids.dueVl3]);
  assert.equal((await as(ids.vl3, "select public.secoto_mes_reglements() as r"))[0].r.bloque, true);
  const q = await quote(ids.client);
  const o = await book(ids.client, q.id);
  await cardSaved(o.payment_id);
  assert.equal(await offerFor(o.id, ids.vl3), undefined, "plus de nouvelles missions");
  assert.ok(await offerFor(o.id, ids.vl1));

  // Versement à venir pour vl3 (mission livrée et payée par carte, ancienne attribution).
  const due = await row("commissions_dues", ids.dueVl3);
  const ord = (await sql("select o.* from public.transport_orders o where o.status='delivered' and o.mode_reglement='carte' limit 1"))[0];
  const pp = (await sql(`insert into public.partner_payouts(mission_id, order_id, partner_id, amount_cents, due_at, mode)
      select m.id, null, $1, $2, now() + interval '4 hours', 'plateau' from public.missions m
       where not exists (select 1 from public.partner_payouts x where x.mission_id = m.id) limit 1 returning *`,
    [ids.vl3, due.amount_cents + 5000]))[0];
  assert.ok(pp && ord);
  const ret = (await service("select public.secoto_commissions_retenir() as r"))[0].r;
  assert.ok(ret.retenues >= 1);
  assert.equal((await row("partner_payouts", pp.id)).amount_cents, 5000, "marge retenue");
  const apres = await row("commissions_dues", ids.dueVl3);
  assert.equal(apres.statut, "retenue");
  assert.equal(apres.retenue_cents, due.amount_cents);
  assert.equal((await as(ids.vl3, "select public.secoto_mes_reglements() as r"))[0].r.bloque, false);
});

test("espèces non reçues : carte du client prélevée 24 h après", async () => {
  await flag("reglement_arrivee", true);
  const q = await quote(ids.client);
  const o = await book(ids.client, q.id);
  await choisir(ids.client, o.id, "especes");
  await cardSaved(o.payment_id);
  await accept(ids.vl2, await offerFor(o.id, ids.vl2));
  await confirmer(o.id);
  await sql("update public.missions set progress_status='delivery_completed', status='completed' where id=$1", [(await row("transport_orders", o.id)).mission_id]);
  const r = (await as(ids.vl2, "select public.secoto_reglement_especes($1,false) as r", [o.id]))[0].r;
  assert.equal(r.result, "non_recu");
  const pay = await row("payments", o.payment_id);
  assert.equal(pay.especes_statut, "non_recu");
  assert.ok(Date.parse(pay.reglement_echeance) > Date.now() + 23 * 3600e3);
  assert.equal((await clientOrder(o.id)).reglement_a_payer, true);
  assert.equal((await aDebiter()).some((x) => x.payment_id === o.payment_id), false);
  await sql("update public.payments set reglement_echeance = now() - interval '1 minute' where id=$1", [o.payment_id]);
  assert.ok((await aDebiter()).some((x) => x.payment_id === o.payment_id));
  assert.equal((await sql("select count(*)::int n from public.commissions_dues where order_id=$1", [o.id]))[0].n, 0);
});

test("marge payée par carte (webhook) ; admin : liste et règlement par virement", async () => {
  await flag("reglement_arrivee", true);
  const { order } = await commandeLivree("especes", "vl1");
  await as(ids.vl1, "select public.secoto_reglement_especes($1,true)", [order.id]);
  const due = (await sql("select * from public.commissions_dues where order_id=$1", [order.id]))[0];
  const ctx = (await service("select public.secoto_commission_contexte($1,$2) as r", [due.id, ids.vl1]))[0].r;
  assert.equal(ctx.reste_cents, due.amount_cents);
  assert.equal(ctx.reference, `COM-${order.public_ref}`);
  assert.equal((await service("select public.secoto_commission_contexte($1,$2) as r", [due.id, ids.vl2]))[0].r.error, "introuvable");
  assert.equal((await service("select public.secoto_commission_payee($1,'pi_c',1) as r", [due.id]))[0].r.result, "montant_insuffisant");
  assert.equal((await service("select public.secoto_commission_payee($1,'pi_c',$2) as r", [due.id, due.amount_cents]))[0].r.result, "payee");
  assert.equal((await row("commissions_dues", due.id)).paid_via, "carte");

  const b = await commandeLivree("especes", "vl2");
  await as(ids.vl2, "select public.secoto_reglement_especes($1,true)", [b.order.id]);
  const adm = (await as(ids.admin, "select public.secoto_admin_reglements() as r"))[0].r;
  assert.equal(adm.actif, true);
  const c = adm.commissions.find((x) => x.public_ref === b.order.public_ref);
  assert.ok(c);
  await assert.rejects(as(ids.client, "select public.secoto_admin_reglements()"), /administrateur/);
  assert.equal((await as(ids.admin, "select public.secoto_admin_commission_reglee($1) as r", [c.id]))[0].r.result, "payee");
  await assert.rejects(as(ids.vl2, "select * from public.commissions_dues"), /permission denied/);
});

test("paiement direct au transporteur : circuit 074 inchangé", async () => {
  await flag("reglement_arrivee", true);
  await flag("plateau_paiement_direct", true);
  try {
    const q = await quote(ids.client);
    const o = await book(ids.client, q.id);
    const pay = await row("payments", o.payment_id);
    assert.equal(pay.payment_circuit, "direct");
    assert.equal(pay.debit_a_livraison, false);
    await assert.rejects(choisir(ids.client, o.id, "carte"), /se règle déjà autrement/);
  } finally {
    await flag("plateau_paiement_direct", false);
  }
});

test("relance : espèces non confirmées 48 h après la livraison", async () => {
  await flag("reglement_arrivee", true);
  const { order } = await commandeLivree("especes", "vl1");
  await sql("update public.transport_orders set updated_at = now() - interval '49 hours' where id=$1", [order.id]);
  const r = (await service("select public.secoto_reglement_relances() as r"))[0].r;
  assert.ok(r.relances >= 1);
  const n = await sql("select 1 from public.notifications where event_key=$1", [`od-especes-relance:${order.id}`]);
  assert.equal(n.length, 1);
  assert.equal((await service("select public.secoto_reglement_relances() as r"))[0].r.relances, 0, "une seule relance");
});

test("104 : annulation tardive d'un règlement à la livraison — ni « retenue » ni « remboursement » annoncés, rien n'est prélevé", async () => {
  await flag("reglement_arrivee", true);
  const q = await quote(ids.client);
  const o = await book(ids.client, q.id);
  await cardSaved(o.payment_id);
  assert.equal((await accept(ids.vl2, await offerFor(o.id, ids.vl2))).result, "pending_capture");
  assert.equal((await confirmer(o.id)).result, "confirmed");
  await sql("update public.transport_orders set pickup_at = now() + interval '3 hours' where id=$1", [o.id]);
  await as(ids.client, "select public.secoto_od_cancel_order($1,$2)", [o.id, randomUUID()]);
  const n = await sql("select body from public.notifications where account_id=$1 and event_key=$2", [ids.client, `od-cancel-client:${o.id}`]);
  assert.match(n[0].body, /Rien n'avait été prélevé : aucun montant ne vous est débité\./);
  const pay = await row("payments", o.payment_id);
  assert.ok(!["paid", "refund_pending"].includes(pay.status), `aucun encaissement (${pay.status})`);
});
