// Tests d'intégration base de données — migrations 030 à 032.
// Exécution : PGURL=postgres://... node --test tests/db/od-subscription-live.dbtest.mjs
// Base JETABLE uniquement (données fictives « TEST »). Jamais sur la production.
import test from "node:test";
import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import pg from "pg";

const PGURL = process.env.PGURL;
if (!PGURL) throw new Error("PGURL requis (base de test jetable).");
const pool = new pg.Pool({ connectionString: PGURL, max: 20 });

async function sql(text, params = []) {
  const c = await pool.connect();
  try { return (await c.query(text, params)).rows; } finally { c.release(); }
}
// Exécute une requête sous l'identité d'un utilisateur authentifié.
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
const one = async (p) => Object.values((await p)[0])[0];

const ids = {};
async function account(key, role, extra = {}) {
  const id = randomUUID();
  ids[key] = id;
  await sql(`insert into public.accounts(id, role, full_name, email, status, is_verified, transporter_type, client_type)
             values ($1,$2,$3,$4,'active',$5,$6,$7)`,
    [id, role, `TEST ${key}`, `${key}@test.invalid`, extra.verified ?? true, extra.type ?? null, extra.clientType ?? "pro"]);
  return id;
}
const tomorrow = () => new Date(Date.now() + 3 * 86400000).toISOString().slice(0, 10);
const quotePayload = (over = {}) => ({
  mode: "convoyage",
  pickup: { label: "1 rue de Test 92260 Fontenay-aux-Roses", city: "Fontenay-aux-Roses", postcode: "92260", lat: 48.79, lng: 2.29 },
  delivery: { label: "1 place Test 69002 Lyon", city: "Lyon", postcode: "69002", lat: 45.76, lng: 4.83 },
  vehicle: { model: "TEST Peugeot 308", class: "voiture", category: "standard", rolling: true, constraints: [] },
  schedule: { pickup_date: tomorrow(), slot: "matin", flexibility_days: 0 },
  ...over,
});
async function createQuote(clientId, over = {}, km = 120) {
  const r = await service("select public.secoto_quote_create($1,$2,$3) as q",
    [clientId, JSON.stringify(quotePayload(over)), JSON.stringify({ distance_km: km, duration_min: 90, provider: "test" })]);
  return r[0].q;
}
async function capturable(paymentId) {
  return service("select public.secoto_od_apply_payment_event($1,$2,'payment_intent.amount_capturable_updated','pi_' || $1::uuid::text,0,null,null) as r",
    [paymentId, `evt_${randomUUID()}`]);
}

test.before(async () => {
  await sql("update public.secoto_feature_flags set enabled = true");
  await account("admin", "admin");
  await account("client", "client");
  await account("client2", "client");
  for (const k of ["p1", "p2", "p3"]) await account(k, "transporter", { type: "convoyeur" });
  await account("pExpired", "transporter", { type: "convoyeur" });
  await account("pUnavailable", "transporter", { type: "convoyeur" });
  await account("plateau", "transporter", { type: "vl" });
  for (const k of ["p1", "p2", "p3", "pExpired", "plateau"]) {
    await as(ids[k], "select public.secoto_update_dispatch_preferences($1)", [JSON.stringify({ available: true, notify_offline: true, zones: ["92"] })]);
  }
  await as(ids.pUnavailable, "select public.secoto_update_dispatch_preferences($1)", [JSON.stringify({ available: false })]);
  await sql(`insert into public.documents(account_id, type, doc_type, status, valid_until) values ($1,'assurance_rc_pro',null,'approved', current_date - 1)`, [ids.pExpired]);
});
test.after(async () => { await pool.end(); });

test("barème : prix identique au barème validé (paliers cumulatifs, plancher)", async () => {
  const q = await createQuote(ids.client, {}, 400);
  assert.equal(q.status, "priced");
  assert.equal(q.client_price_cents, 39000); // 300×1,00 + 100×0,90
  assert.equal(q.partner_pay_cents, undefined, "le client ne voit jamais la rémunération partenaire");
  assert.equal(q.margin_cents, undefined);
  const small = await createQuote(ids.client, {}, 40);
  assert.equal(small.client_price_cents, 11500);
  const util = await createQuote(ids.client, { vehicle: { ...quotePayload().vehicle, class: "utilitaire" } }, 200);
  assert.equal(util.status, "manual_review");
  assert.equal(util.manual_reason, "categorie_vehicule_hors_bareme");
  const far = await createQuote(ids.client, {}, 850);
  assert.equal(far.manual_reason, "distance_hors_bareme_automatique");
  const plateau = await createQuote(ids.client, { mode: "plateau" }, 100);
  assert.equal(plateau.manual_reason, "aucun_bareme_actif");
  const noRoute = await service("select public.secoto_quote_create($1,$2,null) as q", [ids.client, JSON.stringify(quotePayload())]);
  assert.equal(noRoute[0].q.manual_reason, "itineraire_indisponible");
});

test("devis : le client ne peut pas créer ni falsifier un devis", async () => {
  await assert.rejects(as(ids.client, "select public.secoto_quote_create($1,$2,$3)",
    [ids.client, JSON.stringify(quotePayload()), JSON.stringify({ distance_km: 1 })]), /permission denied/);
  await assert.rejects(as(ids.client, "select * from public.transport_quotes"), /permission denied/);
});

let mainOrder;
test("attribution : acceptations simultanées → un seul gagnant, capture, mission créée", async () => {
  const q = await createQuote(ids.client);
  const booked = (await as(ids.client, "select public.secoto_od_book_quote($1,false,$2) as r", [q.id, randomUUID()]))[0].r;
  mainOrder = booked.order;
  assert.equal(mainOrder.status, "awaiting_payment");
  assert.equal(mainOrder.payment_strategy, "authorize_then_capture");
  const offersBefore = await sql("select count(*)::int n from public.transport_offers where order_id = $1", [mainOrder.id]);
  assert.equal(offersBefore[0].n, 0, "aucune diffusion avant validation du paiement");

  await capturable(mainOrder.payment_id);
  const offers = await sql("select id, partner_id from public.transport_offers where order_id = $1 order by partner_id", [mainOrder.id]);
  const partners = offers.map((o) => o.partner_id).sort();
  assert.deepEqual(partners, [ids.p1, ids.p2, ids.p3].sort(), "diffusion limitée aux partenaires compatibles, disponibles, documents valides");
  const notif = await sql("select push_screen, ref_id from public.notifications where type='mission_offer' and account_id=$1", [ids.p1]);
  assert.equal(notif[0].push_screen, "offre");

  const results = await Promise.all(offers.map((o) =>
    as(o.partner_id, "select public.secoto_offer_accept($1,$2) as r", [o.id, randomUUID()]).then((r) => ({ partner: o.partner_id, r: r[0].r }))));
  const winners = results.filter((x) => x.r.result === "pending_capture");
  assert.equal(winners.length, 1, JSON.stringify(results));
  assert.equal(results.filter((x) => x.r.result === "already_assigned").length, 2);

  const confirmed = (await service("select public.secoto_od_capture_result($1,true,null) as r", [mainOrder.id]))[0].r;
  assert.equal(confirmed.result, "confirmed");
  const mission = (await sql("select * from public.missions where id = $1", [confirmed.mission_id]))[0];
  assert.equal(mission.status, "assigned");
  assert.equal(mission.assigned_transporter_id, winners[0].partner);
  assert.equal(Number(mission.client_price), 120);
  assert.equal(Number(mission.carrier_pay), 66);
  // Webhook « succeeded » reçu après la capture : aucun effet indésirable.
  const again = (await service("select public.secoto_od_apply_payment_event($1,$2,'payment_intent.succeeded','pi_' || $1::uuid::text,0,null,null) as r", [mainOrder.payment_id, "evt_succ_1"]))[0].r;
  assert.equal(again.status, "paid");
  const replay = (await service("select public.secoto_od_apply_payment_event($1,$2,'payment_intent.succeeded','pi_' || $1::uuid::text,0,null,null) as r", [mainOrder.payment_id, "evt_succ_1"]))[0].r;
  assert.equal(replay.reason, "event_already_processed");
  // Désordre : « autorisé » après « encaissé » ne fait pas régresser.
  const late = (await service("select public.secoto_od_apply_payment_event($1,$2,'payment_intent.amount_capturable_updated','pi_' || $1::uuid::text,0,null,null) as r", [mainOrder.payment_id, "evt_late"]))[0].r;
  assert.equal(late.status, "paid");
  const loser = results.find((x) => x.r.result === "already_assigned");
  const loserOffer = offers.find((o) => o.partner_id === loser.partner);
  const view = (await as(loser.partner, "select public.secoto_offer_get($1) as r", [loserOffer.id]))[0].r;
  assert.equal(view.state, "already_assigned");
  assert.equal(view.client_price_cents, undefined, "le partenaire ne voit pas le prix client");
  const winnerOffer = offers.find((o) => o.partner_id === winners[0].partner);
  const winnerView = (await as(winners[0].partner, "select public.secoto_offer_get($1) as r", [winnerOffer.id]))[0].r;
  assert.equal(winnerView.state, "confirmed");
  assert.equal(winnerView.partner_pay_cents, 6600);
  const orders = (await as(ids.client, "select public.secoto_od_my_orders() as r"))[0].r;
  const mine = orders.find((o) => o.id === mainOrder.id);
  assert.equal(mine.status, "partner_confirmed");
  assert.equal(mine.payment_status, "paid");
  assert.equal(mine.partner_pay_cents, undefined, "le client ne voit pas le coût partenaire");
  ids.mainMission = confirmed.mission_id;
  ids.mainPartner = winners[0].partner;
});

test("idempotence : une acceptation rejouée avec la même clé ne produit rien de plus", async () => {
  const q = await createQuote(ids.client);
  const order = (await as(ids.client, "select public.secoto_od_book_quote($1,false,$2) as r", [q.id, randomUUID()]))[0].r.order;
  const key = randomUUID();
  const bookAgain = (await as(ids.client, "select public.secoto_od_book_quote($1,false,$2) as r", [q.id, randomUUID()]))[0].r;
  assert.equal(bookAgain.already_booked, true, "double réservation impossible");
  await service("select public.secoto_od_apply_payment_event($1,$2,'payment_intent.succeeded','pi_x',0,null,null)", [order.payment_id, `evt_${randomUUID()}`]);
  const offer = (await sql("select id from public.transport_offers where order_id=$1 and partner_id=$2", [order.id, ids.p2]))[0];
  const a = (await as(ids.p2, "select public.secoto_offer_accept($1,$2) as r", [offer.id, key]))[0].r;
  assert.equal(a.result, "confirmed", "paiement déjà encaissé : confirmation immédiate");
  const b = (await as(ids.p2, "select public.secoto_offer_accept($1,$2) as r", [offer.id, key]))[0].r;
  assert.deepEqual(a, b);
  const missions = await sql("select count(*)::int n from public.transport_orders where id=$1 and mission_id is not null", [order.id]);
  assert.equal(missions[0].n, 1);
});

test("échec de capture : aucune mission confirmée, commande de nouveau disponible", async () => {
  const q = await createQuote(ids.client);
  const order = (await as(ids.client, "select public.secoto_od_book_quote($1,false,$2) as r", [q.id, randomUUID()]))[0].r.order;
  await capturable(order.payment_id);
  const offer = (await sql("select id from public.transport_offers where order_id=$1 and partner_id=$2", [order.id, ids.p1]))[0];
  const r = (await as(ids.p1, "select public.secoto_offer_accept($1,$2) as r", [offer.id, randomUUID()]))[0].r;
  assert.equal(r.result, "pending_capture");
  const cancelWhileLocked = as(ids.client, "select public.secoto_od_cancel_order($1,$2)", [order.id, randomUUID()]);
  await assert.rejects(cancelWhileLocked, /en cours de confirmation/);
  const fail = (await service("select public.secoto_od_capture_result($1,false,'card_declined') as r", [order.id]))[0].r;
  assert.equal(fail.result, "capture_failed");
  const row = (await sql("select o.status, o.mission_id, p.status pstatus from public.transport_orders o join public.payments p on p.id=o.payment_id where o.id=$1", [order.id]))[0];
  assert.equal(row.status, "searching_partner");
  assert.equal(row.mission_id, null);
  assert.equal(row.pstatus, "capture_failed");
  const view = (await as(ids.p1, "select public.secoto_offer_get($1) as r", [offer.id]))[0].r;
  assert.notEqual(view.state, "confirmed");
});

test("absence de partenaire : fin de diffusion et restitution du paiement", async () => {
  const q = await createQuote(ids.client, {
    pickup: { label: "1 rue Test 13001 Marseille", city: "Marseille", postcode: "13001", lat: 43.3, lng: 5.37 } });
  const order = (await as(ids.client, "select public.secoto_od_book_quote($1,false,$2) as r", [q.id, randomUUID()]))[0].r.order;
  await capturable(order.payment_id);
  assert.equal((await sql("select count(*)::int n from public.transport_offers where order_id=$1", [order.id]))[0].n, 0, "zone 13 : aucun partenaire");
  for (let i = 0; i < 3; i += 1) {
    await sql("update public.transport_orders set offers_expire_at = now() - interval '1 second' where id=$1", [order.id]);
    await service("select public.secoto_od_maintenance_tick()");
  }
  const o = (await sql("select status from public.transport_orders where id=$1", [order.id]))[0];
  assert.equal(o.status, "no_partner");
  const tick = (await service("select public.secoto_od_maintenance_tick() as r"))[0].r;
  const action = tick.payment_actions.find((a) => a.payment_id === order.payment_id);
  assert.equal(action.action, "cancel", "autorisation à libérer, rien n'est débité");
  await service("select public.secoto_od_payment_action_result($1,'cancel',true,null)", [order.payment_id]);
  assert.equal((await sql("select status from public.payments where id=$1", [order.payment_id]))[0].status, "cancelled");
});

test("hausse de rémunération : dans la marge ou validation admin explicite", async () => {
  const q = await createQuote(ids.client, {
    pickup: { label: "2 rue Test 33000 Bordeaux", city: "Bordeaux", postcode: "33000", lat: 44.8, lng: -0.57 } });
  const order = (await as(ids.client, "select public.secoto_od_book_quote($1,false,$2) as r", [q.id, randomUUID()]))[0].r.order;
  await capturable(order.payment_id);
  await assert.rejects(as(ids.p1, "select public.secoto_admin_od_set_partner_pay($1,9000,false,null)", [order.id]), /administrateur/);
  await assert.rejects(as(ids.admin, "select public.secoto_admin_od_set_partner_pay($1,11000,false,null)", [order.id]), /seuil/);
  const ok = (await as(ids.admin, "select public.secoto_admin_od_set_partner_pay($1,9000,false,null) as r", [order.id]))[0].r;
  assert.equal(ok.margin_cents, 3000);
  const forced = (await as(ids.admin, "select public.secoto_admin_od_set_partner_pay($1,11500,true,'Urgence validée TEST') as r", [order.id]))[0].r;
  assert.equal(forced.margin_cents, 500);
  const audit = await sql("select count(*)::int n from public.secoto_audit_log where entity_id=$1 and action='order_partner_pay_changed'", [order.id]);
  assert.equal(audit[0].n, 2);
});

test("permissions : tables inaccessibles, fonctions admin et service refusées", async () => {
  for (const table of ["transport_orders", "transport_offers", "payments", "mission_live_positions", "subscription_reservations", "eligibility_history_rows", "secoto_audit_log", "pricing_grids"]) {
    if (table === "payments") continue; // lecture propre autorisée par la politique existante
    await assert.rejects(as(ids.client, `select * from public.${table}`), /permission denied/, table);
  }
  await assert.rejects(as(ids.client, "select public.secoto_admin_od_orders(null)"), /administrateur/);
  await assert.rejects(as(ids.p1, "select public.secoto_admin_accounting_export(current_date - 1, current_date)"), /administrateur/);
  await assert.rejects(as(ids.client, "select public.secoto_od_capture_result($1,true,null)", [mainOrder.id]), /permission denied/);
  await assert.rejects(as(ids.client, "select public.secoto_od_apply_payment_event($1,'e','payment_intent.succeeded',null,0,null,null)", [mainOrder.payment_id]), /permission denied/);
  await assert.rejects(as(null, "select public.secoto_feature_flags()", [], "anon"), /permission denied/);
  const other = (await as(ids.client2, "select public.secoto_od_my_orders() as r"))[0].r;
  assert.equal(other.length, 0, "un client ne voit pas les commandes d'autrui");
  const offersForClient = (await as(ids.client, "select public.secoto_offer_get((select id from public.transport_offers limit 1)) as r", [], "authenticated").catch(() => [{ r: null }]))[0].r;
  assert.equal(offersForClient, null);
  const exp = (await as(ids.admin, "select * from public.secoto_admin_accounting_export(current_date - 1, current_date)"));
  assert.ok(exp.length >= 1);
});

test("GPS : activation après récupération, position périmée signalée, accès restreint, arrêt à la livraison", async () => {
  const m = ids.mainMission;
  await assert.rejects(as(ids.mainPartner, "select public.secoto_live_start($1,true)", [m]), /après « Véhicule récupéré »/);
  await sql("update public.missions set progress_status='pickup_completed' where id=$1", [m]);
  assert.equal((await sql("select status from public.transport_orders where mission_id=$1", [m]))[0].status, "picked_up");
  await assert.rejects(as(ids.mainPartner, "select public.secoto_live_start($1,false)", [m]), /accord explicite/);
  const otherPartner = [ids.p1, ids.p2, ids.p3].find((p) => p !== ids.mainPartner);
  await assert.rejects(as(otherPartner, "select public.secoto_live_start($1,true)", [m]), /introuvable/);
  await as(ids.mainPartner, "select public.secoto_live_start($1,true)", [m]);
  const now = new Date();
  const push = (await as(ids.mainPartner, "select public.secoto_live_push_positions($1,$2) as r", [m, JSON.stringify([
    { lat: 48.5, lng: 2.5, accuracy_m: 12, recorded_at: new Date(now - 20000).toISOString() },
    { lat: 48.51, lng: 2.51, accuracy_m: 12, recorded_at: new Date(now - 18000).toISOString() }, // trop rapproché
    { lat: 91, lng: 2.5, recorded_at: now.toISOString() }, // invalide
    { lat: 48.52, lng: 2.52, accuracy_m: 10, recorded_at: now.toISOString() },
  ])]))[0].r;
  assert.equal(push.accepted, 2);
  const live = (await as(ids.client, "select public.secoto_live_view($1) as r", [m]))[0].r;
  assert.equal(live.freshness, "live");
  assert.equal(live.position_source, "telephone_du_transporteur");
  await assert.rejects(as(ids.client2, "select public.secoto_live_view($1)", [m]), /introuvable/);
  await assert.rejects(as(otherPartner, "select public.secoto_live_view($1)", [m]), /introuvable/);
  await sql("update public.mission_live_positions set recorded_at = now() - interval '12 minutes' where mission_id=$1", [m]);
  const stale = (await as(ids.client, "select public.secoto_live_view($1) as r", [m]))[0].r;
  assert.equal(stale.freshness, "stale");
  assert.ok(stale.age_seconds >= 700);
  await sql("update public.missions set progress_status='delivery_completed' where id=$1", [m]);
  const after = (await as(ids.client, "select public.secoto_live_view($1) as r", [m]))[0].r;
  assert.equal(after.sharing, "stopped");
  assert.equal(after.position, undefined, "plus aucune position exposée après livraison");
  const late = (await as(ids.mainPartner, "select public.secoto_live_push_positions($1,$2) as r", [m, JSON.stringify([{ lat: 48, lng: 2, recorded_at: new Date().toISOString() }])]))[0].r;
  assert.equal(late.accepted, 0);
  assert.equal((await sql("select status from public.transport_orders where mission_id=$1", [m]))[0].status, "delivered");
  assert.equal((await sql("select amount_cents from public.partner_payouts where mission_id=$1", [m]))[0].amount_cents, 6600);
});

test("GPS : réattribution arrête le partage", async () => {
  const q = await createQuote(ids.client);
  const order = (await as(ids.client, "select public.secoto_od_book_quote($1,false,$2) as r", [q.id, randomUUID()]))[0].r.order;
  await service("select public.secoto_od_apply_payment_event($1,$2,'payment_intent.succeeded','pi_y',0,null,null)", [order.payment_id, `evt_${randomUUID()}`]);
  const offer = (await sql("select id from public.transport_offers where order_id=$1 and partner_id=$2", [order.id, ids.p3]))[0];
  const res = (await as(ids.p3, "select public.secoto_offer_accept($1,$2) as r", [offer.id, randomUUID()]))[0].r;
  await sql("update public.missions set progress_status='in_transit' where id=$1", [res.mission_id]);
  await as(ids.p3, "select public.secoto_live_start($1,true)", [res.mission_id]);
  await sql("update public.missions set assigned_transporter_id=$2 where id=$1", [res.mission_id, ids.p1]);
  assert.equal((await sql("select status, stop_reason from public.mission_live_sessions where mission_id=$1", [res.mission_id]))[0].stop_reason, "reassigned");
});

test("abonnement : dossier, import contrôlé, proposition au pire cas, quotas atomiques, restitution", async () => {
  const start = (await as(ids.client, "select public.secoto_eligibility_start('TEST Garage Martin','123456789') as r"))[0].r;
  const appId = start.application.id;
  const businessId = start.business.id;
  await as(ids.client, "select public.secoto_eligibility_save_questionnaire($1,$2)", [appId, JSON.stringify({
    trips_per_month: 8, zones: ["92", "75", "69"], typical_km: 120, max_km: 500, vehicle_classes: ["voiture"], modes: ["convoyage"], lead_time: "48h" })]);
  const d = (n) => new Date(Date.now() - n * 86400000).toISOString().slice(0, 10);
  const rows = (await as(ids.client, "select public.secoto_eligibility_replace_rows($1,$2) as r", [appId, JSON.stringify([
    { date: d(10), from: "Paris 75011", to: "Lyon 69002", distance_km: "465", vehicle: "Clio", mode: "convoyage", amount_eur: "430", receipt_ref: "F1" },
    { date: d(10), from: "Paris 75011", to: "Lyon 69002", distance_km: "465", vehicle: "Clio", mode: "convoyage", amount_eur: "430", receipt_ref: "F1" },
    { date: "2099-01-01", from: "Paris", to: "Lyon", distance_km: "abc", vehicle: "", mode: "bateau", amount_eur: "=SUM(A1)" },
  ])]))[0].r;
  assert.deepEqual([rows.counts.valid, rows.counts.warning, rows.counts.error], [1, 1, 1]);
  assert.ok(rows.rows[1].issues.includes("doublon_probable"));
  await assert.rejects(as(ids.client, "select public.secoto_eligibility_submit($1)", [appId]), /erreur/);
  await as(ids.client, "select public.secoto_eligibility_replace_rows($1,$2)", [appId, JSON.stringify([
    { date: d(10), from: "Paris 75011", to: "Lyon 69002", distance_km: "465", vehicle: "Clio", mode: "convoyage", amount_eur: "430" }])]);
  await as(ids.client, "select public.secoto_eligibility_submit($1)", [appId]);
  await assert.rejects(as(ids.client2, "select public.secoto_eligibility_rows($1)", [appId]), /introuvable/, "historique privé");
  const summary = (await as(ids.admin, "select public.secoto_admin_eligibility_summary($1) as r", [appId]))[0].r;
  assert.equal(summary.totals.trips, 1);

  const base = { application_id: appId, km_cap_total: 300, max_km_per_trip: 200, zones: ["92", "75", "69"], modes: ["convoyage"],
    lead_time_hours: 24, cancellation_notice_hours: 24, included_fees: "Convoyeur, états des lieux", exclusions: "Carburant et péages au réel",
    carry_over_rule: "Aucun report des droits non utilisés", cancellation_rule: "Annulation > 24 h : droit restitué", termination_rule: "Résiliable à chaque échéance",
    effective_date: new Date().toISOString().slice(0, 10), valid_until: tomorrow(),
    allowances: [{ category: "convoyage:voiture", quantity: 2, partner_cost_per_km_eur: 0.55, fees_per_trip_eur: 0 }] };
  const tooCheap = (await as(ids.admin, "select public.secoto_admin_save_proposal($1) as r", [JSON.stringify({ ...base, monthly_price_cents: 17000 })]))[0].r;
  assert.equal(tooCheap.worst_case.worst_case_cost_eur, 165); // 300 km × 0,55 : pire cas borné par le plafond
  await assert.rejects(as(ids.admin, "select public.secoto_admin_send_proposal($1)", [tooCheap.id]), /Envoi refusé/);
  const good = (await as(ids.admin, "select public.secoto_admin_save_proposal($1) as r", [JSON.stringify({ ...base, monthly_price_cents: 40000 })]))[0].r;
  await as(ids.admin, "select public.secoto_admin_send_proposal($1)", [good.id]);
  const overviewProposal = (await as(ids.client, "select public.secoto_sub_my_overview() as r"))[0].r.proposals[0];
  assert.equal(overviewProposal.worst_case, undefined, "la simulation interne n'est pas exposée");
  const acc = (await as(ids.client, "select public.secoto_sub_accept_proposal($1) as r", [good.id]))[0].r;
  await assert.rejects(as(ids.client, "select public.secoto_od_book_quote(null,true,$1)", [randomUUID()]));
  const periodStart = new Date(Date.now() - 86400000).toISOString();
  const periodEnd = new Date(Date.now() + 25 * 86400000).toISOString();
  await service("select public.secoto_sub_apply_billing_event($1,'evt_inv_1','invoice.paid','sub_test',$2,$3)", [acc.subscription_id, periodStart, periodEnd]);
  const replay = (await service("select public.secoto_sub_apply_billing_event($1,'evt_inv_1','invoice.paid','sub_test',$2,$3) as r", [acc.subscription_id, periodStart, periodEnd]))[0].r;
  assert.equal(replay.reason, "event_already_processed");

  // Trois réservations simultanées pour deux droits.
  const quotes = [];
  for (let i = 0; i < 3; i += 1) quotes.push(await createQuote(ids.client, { business_id: businessId }, 120));
  const attempts = await Promise.allSettled(quotes.map((q) =>
    as(ids.client, "select public.secoto_od_book_quote($1,true,$2) as r", [q.id, randomUUID()])));
  const okBookings = attempts.filter((a) => a.status === "fulfilled");
  assert.equal(okBookings.length, 2, JSON.stringify(attempts.map((a) => a.reason?.message)));
  assert.match(attempts.find((a) => a.status === "rejected").reason.message, /Droits épuisés/);
  let usage = (await as(ids.client, "select public.secoto_sub_my_overview() as r"))[0].r.usage.categories[0];
  assert.deepEqual([usage.included, usage.reserved, usage.available], [2, 2, 0]);
  const booked = okBookings[0].value[0].r.order;
  assert.equal(booked.payment_id, null, "mission incluse : aucun paiement supplémentaire");

  // Annulation avant attribution : droit restitué, nouvelle réservation possible.
  await as(ids.client, "select public.secoto_od_cancel_order($1,$2)", [booked.id, randomUUID()]);
  usage = (await as(ids.client, "select public.secoto_sub_my_overview() as r"))[0].r.usage.categories[0];
  assert.equal(usage.available, 1);
  const retry = (await as(ids.client, "select public.secoto_od_book_quote($1,true,$2) as r", [(await createQuote(ids.client, { business_id: businessId }, 120)).id, randomUUID()]))[0].r;
  assert.equal(retry.order.funding, "subscription");

  // Plafond kilométrique : 180 km réservés, un trajet de 150 km dépasserait 300 km.
  await as(ids.admin, "select public.secoto_admin_od_cancel_order($1,'Annulation TEST sans partenaire',true)", [retry.order.id]);
  await as(ids.client, "select public.secoto_od_cancel_order($1,$2)", [okBookings[1].value[0].r.order.id, randomUUID()]);
  const big = await createQuote(ids.client, { business_id: businessId }, 180);
  await as(ids.client, "select public.secoto_od_book_quote($1,true,$2)", [big.id, randomUUID()]);
  const tooFar = await createQuote(ids.client, { business_id: businessId }, 150);
  await assert.rejects(as(ids.client, "select public.secoto_od_book_quote($1,true,$2)", [tooFar.id, randomUUID()]), /Plafond kilométrique/);
  const overTrip = await createQuote(ids.client, { business_id: businessId }, 250);
  await assert.rejects(as(ids.client, "select public.secoto_od_book_quote($1,true,$2)", [overTrip.id, randomUUID()]), /distance maximale/);

  // Prélèvement échoué : nouvelles réservations suspendues.
  await service("select public.secoto_sub_apply_billing_event($1,'evt_inv_fail','invoice.payment_failed','sub_test',null,null)", [acc.subscription_id]);
  const q2 = await createQuote(ids.client, { business_id: businessId }, 50);
  await assert.rejects(as(ids.client, "select public.secoto_od_book_quote($1,true,$2)", [q2.id, randomUUID()]), /suspendues/);
  await assert.rejects(as(ids.client2, "select public.secoto_od_book_quote($1,true,$2)", [q2.id, randomUUID()]), /introuvable/);
});

test("concurrence répétée : 15 commandes × 3 acceptations simultanées → toujours un seul gagnant", async () => {
  for (let i = 0; i < 15; i += 1) {
    const q = await createQuote(ids.client);
    const order = (await as(ids.client, "select public.secoto_od_book_quote($1,false,$2) as r", [q.id, randomUUID()]))[0].r.order;
    // Moitié autorisation, moitié encaissement préalable.
    const evt = i % 2 ? "payment_intent.succeeded" : "payment_intent.amount_capturable_updated";
    await service("select public.secoto_od_apply_payment_event($1,$2,$3,'pi_' || $1::uuid::text,0,null,null)", [order.payment_id, `evt_${randomUUID()}`, evt]);
    const offers = await sql("select id, partner_id from public.transport_offers where order_id=$1", [order.id]);
    const res = await Promise.all(offers.map((o) => as(o.partner_id, "select public.secoto_offer_accept($1,$2) as r", [o.id, randomUUID()]).then((r) => r[0].r.result)));
    const wins = res.filter((r) => r === "confirmed" || r === "pending_capture");
    assert.equal(wins.length, 1, `itération ${i}: ${res}`);
    const confirmedMissions = await sql("select count(*)::int n from public.missions m join public.transport_orders o on o.mission_id = m.id where o.id=$1", [order.id]);
    assert.equal(confirmedMissions[0].n, i % 2 ? 1 : 0, "autorisation seule : pas de mission avant capture");
  }
});

test("webhooks dans le désordre : annulation puis autorisation tardive → reste annulé, aucune diffusion", async () => {
  const q = await createQuote(ids.client);
  const order = (await as(ids.client, "select public.secoto_od_book_quote($1,false,$2) as r", [q.id, randomUUID()]))[0].r.order;
  await service("select public.secoto_od_apply_payment_event($1,'evt_c1','payment_intent.canceled',null,0,null,null)", [order.payment_id]);
  const r = (await service("select public.secoto_od_apply_payment_event($1,'evt_c2','payment_intent.amount_capturable_updated',null,0,null,null) as r", [order.payment_id]))[0].r;
  assert.equal(r.status, "cancelled");
  assert.equal((await sql("select status from public.transport_orders where id=$1", [order.id]))[0].status, "cancelled");
  assert.equal((await sql("select count(*)::int n from public.transport_offers where order_id=$1", [order.id]))[0].n, 0);
  const failed = (await service("select public.secoto_od_apply_payment_event($1,'evt_c3','payment_intent.payment_failed',null,0,null,'x') as r", [order.payment_id]))[0].r;
  assert.equal(failed.status, "cancelled");
});

test("refus : aucune pénalité, le partenaire n'est plus sollicité pour cette commande seulement", async () => {
  const q = await createQuote(ids.client);
  const order = (await as(ids.client, "select public.secoto_od_book_quote($1,false,$2) as r", [q.id, randomUUID()]))[0].r.order;
  await capturable(order.payment_id);
  const offer = (await sql("select id from public.transport_offers where order_id=$1 and partner_id=$2", [order.id, ids.p1]))[0];
  assert.equal((await as(ids.p1, "select public.secoto_offer_decline($1) as r", [offer.id]))[0].r.result, "declined");
  await sql("update public.transport_orders set offers_expire_at = now() - interval '1 second' where id=$1", [order.id]);
  await service("select public.secoto_od_maintenance_tick()");
  const round2 = await sql("select partner_id from public.transport_offers where order_id=$1 and round=2", [order.id]);
  assert.ok(!round2.some((r) => r.partner_id === ids.p1));
  assert.ok(round2.some((r) => r.partner_id === ids.p2));
  const other = await createQuote(ids.client);
  const order2 = (await as(ids.client, "select public.secoto_od_book_quote($1,false,$2) as r", [other.id, randomUUID()]))[0].r.order;
  await capturable(order2.payment_id);
  assert.equal((await sql("select count(*)::int n from public.transport_offers where order_id=$1 and partner_id=$2", [order2.id, ids.p1]))[0].n, 1);
});

test("flags désactivés : devis manuel et aucun paiement en ligne", async () => {
  await sql("update public.secoto_feature_flags set enabled = false where key in ('auto_pricing','od_payments')");
  try {
    const q = await createQuote(ids.client);
    assert.equal(q.status, "manual_review");
    assert.equal(q.manual_reason, "prix_automatique_desactive");
    const priced = (await as(ids.admin, "select public.secoto_admin_price_quote($1,15000,8000,24,'TEST',false) as r", [q.id]))[0].r;
    assert.equal(priced.status, "manual_priced");
    await assert.rejects(as(ids.client, "select public.secoto_od_book_quote($1,false,$2)", [q.id, randomUUID()]), /pas encore ouvert/);
  } finally {
    await sql("update public.secoto_feature_flags set enabled = true");
  }
});

test("non-régression : paiement à la livraison d'une mission historique inchangé, mission prépayée = frais seuls", async () => {
  const legacy = (await sql(`insert into public.missions(public_ref, type, status, distance_km, client_account_id, assigned_transporter_id)
    values ('MIS-TEST-LEGACY','convoyage','assigned',100,$1,$2) returning id, client_price`, [ids.client, ids.p1]))[0];
  const r = (await as(ids.client, "select public.secoto_prepare_delivery_payment($1,$2) as r", [legacy.id, randomUUID()]))[0].r;
  assert.equal(r.amount_cents, Math.round(Number(legacy.client_price) * 100));
  assert.equal(r.frais_only, false);
  await assert.rejects(as(ids.client, "select public.secoto_prepare_delivery_payment($1,$2)", [ids.mainMission, randomUUID()]), /deja reglee/);
});
