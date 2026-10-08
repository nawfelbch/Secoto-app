// Tests d'intégration base de données — migrations 084 (mise en relation, SAV, verrouillage) et 085 (barème transporteurs).
// Exécution : PGURL=postgres://... node --test tests/db/mise-en-relation-084-085.dbtest.mjs
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
  // Sous-traitance totale en vigueur (réglage de production depuis septembre).
  await sql(`update public.app_settings set value = value || jsonb_build_object('sous_traitance_totale_since', '2026-09-01T00:00:00Z')
             where key = 'dispatch_policy' and value ->> 'sous_traitance_totale_since' is null`);
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
const setFlag084 = (on) => sql("update public.secoto_feature_flags set enabled = $1 where key = 'mise_en_relation_v2'", [on]);
const setFlag085 = (on) => sql("update public.secoto_feature_flags set enabled = $1 where key = 'bareme_transporteurs'", [on]);
test.after(async () => { await setFlag(false); await setFlag084(false); await setFlag085(false); await pool.end(); });

async function confirmedOrder() {
  await setFlag(true);
  const o = await book(ids.client);
  await cardSaved(o.payment_id);
  const { confirmed } = await acceptAndCharge(o, ids.ready);
  return { ...o, mission_id: confirmed.mission_id };
}
const adminCall = (text, params) => as(ids.admin, text, params);
const clientOrder = async (orderId) => (await as(ids.client, "select secoto_private.order_client_json(o) as j from public.transport_orders o where o.id=$1", [orderId], "postgres"))[0].j;

// ------------------------------------------------------------------ 084 --------
test("084 éteint : rien ne change (modification admin possible, pas de coordonnées)", async () => {
  if (!ids.admin) await account("admin", "admin");
  await setFlag084(false);
  const o = await confirmedOrder();
  await adminCall("select public.secoto_admin_od_update_conditions($1,$2,$3)", [o.id, JSON.stringify({ pickup_at: new Date(Date.now() + 6 * 86400000).toISOString() }), "test date"]);
  assert.equal((await clientOrder(o.id)).partner_contact, null);
});

test("084 : course acceptée verrouillée, coordonnées du transporteur visibles", async () => {
  await setFlag084(true);
  const o = await confirmedOrder();
  await assert.rejects(adminCall("select public.secoto_admin_od_update_conditions($1,$2,$3)", [o.id, JSON.stringify({ client_price_cents: 99900 }), "test prix"]), /ne peut plus être modifiée/);
  await assert.rejects(adminCall("select public.secoto_admin_od_replace_partner($1,$2)", [o.id, "test remplacement"]), /ne peut plus le remplacer/);
  await assert.rejects(adminCall("select public.secoto_admin_od_cancel_order($1,$2,false)", [o.id, "test annulation"]), /remboursement intégral/);
  const j = await clientOrder(o.id);
  assert.equal(j.partner_contact.legal_name, "TEST Transports SARL");
  assert.equal(j.partner_contact.siren, "123456789");
  // L'annulation avec remboursement intégral reste possible.
  await adminCall("select public.secoto_admin_od_cancel_order($1,$2,true)", [o.id, "test annulation SAV"]);
  assert.equal((await sql("select status from public.transport_orders where id=$1", [o.id]))[0].status, "cancelled");
});

test("084 : attribution manuelle désactivée, mission plateau verrouillée, convoyage libre", async () => {
  await setFlag084(true);
  await setFlag(true);
  const o = await book(ids.client);
  await cardSaved(o.payment_id);
  await assert.rejects(adminCall("select public.secoto_admin_od_lock_for_partner($1,$2)", [o.id, ids.ready]), /Attribution manuelle désactivée/);
  // 086 : le pilotage des missions reste entier, même pour une course acceptée
  // dans l'application (étapes, réouverture, tarif).
  const acceptee = await confirmedOrder();
  await adminCall("select public.secoto_admin_reopen_field_step($1,'pickup',null,$2)", [acceptee.mission_id, randomUUID()]).catch((e) => {
    assert.doesNotMatch(e.message, /validées par le transporteur/);
  });
  await adminCall("select public.secoto_admin_set_mission_pricing($1,true,300,50,$2)", [acceptee.mission_id, randomUUID()]);
  const verrou = (await adminCall("select public.secoto_admin_locked_mission_ids() as ids"))[0].ids;
  assert.equal(verrou.length, 0);
  // Mission saisie par SECOTO (téléphone) : reste pilotable, mais le client voit son transporteur.
  const plateau = (await sql(`insert into public.missions(public_ref, type, status, from_city, to_city, client_account_id, assigned_transporter_id)
      values ('MIS-TEST-' || substr(md5(random()::text),1,6), 'plateau', 'assigned', 'Massy', 'Lyon', $1, $2) returning id`, [ids.client, ids.ready]))[0].id;
  await adminCall("select public.secoto_admin_set_mission_pricing($1,true,300,50,$2)", [plateau, randomUUID()]);
  assert.ok(!verrou.includes(plateau));
  const v = (await as(ids.client, "select transporter_contact from public.secoto_missions_client_v2 where id=$1", [plateau]))[0];
  assert.equal(v.transporter_contact.siren, "123456789");
  const conv = (await sql(`insert into public.missions(public_ref, type, status, from_city, to_city, client_account_id, assigned_transporter_id)
      values ('MIS-TEST-' || substr(md5(random()::text),1,6), 'convoyage', 'assigned', 'Massy', 'Lyon', $1, $2) returning id`, [ids.client, ids.convoyeur]))[0].id;
  await adminCall("select public.secoto_admin_set_mission_pricing($1,true,100,50,$2)", [conv, randomUUID()]);
});

test("084 : SAV — le client écrit, l'administrateur traite, le client est prévenu", async () => {
  await setFlag084(true);
  assert.equal((await as(ids.client, "select public.secoto_client_has_course() as r"))[0].r, true);
  assert.equal((await as(ids.other, "select public.secoto_client_has_course() as r"))[0].r, false);
  const courses = (await as(ids.client, "select public.secoto_sav_courses() as r"))[0].r;
  assert.ok(courses.length > 0);
  const c = courses.find((x) => x.kind === "order");
  const r = (await as(ids.client, "select public.secoto_sav_create($1,null,'retard',$2,null) as r", [c.id, "TEST le transporteur est en retard"]))[0].r;
  assert.match(r.public_ref, /^SAV-/);
  await assert.rejects(as(ids.other, "select public.secoto_sav_create($1,null,'retard',$2,null)", [c.id, "TEST pas ma commande"]), /introuvable/);
  assert.equal((await as(ids.other, "select count(*)::int n from public.sav_requests"))[0].n, 0, "un client ne voit pas les demandes des autres");
  const list = (await adminCall("select public.secoto_admin_sav_list(null) as r"))[0].r;
  assert.ok(list.some((x) => x.id === r.id));
  await adminCall("select public.secoto_admin_sav_update($1,'resolue','rappelé')", [r.id]);
  const mine = (await as(ids.client, "select public.secoto_sav_my_requests() as r"))[0].r;
  assert.equal(mine.find((x) => x.id === r.id).status, "resolue");
  assert.equal((await sql("select count(*)::int n from public.notifications where account_id=$1 and title='SAV SECOTO'", [ids.client]))[0].n, 1);
  await assert.rejects(as(ids.client, "insert into public.sav_requests(account_id, motif, message) values ($1,'autre','TEST direct')", [ids.client]), /permission denied/);
});

// ------------------------------------------------------------------ 085 --------
const quoteCents = async (over = {}, km = 400) => {
  const q = await createQuote(ids.client, over, km);
  return { client: q.client_price_cents, partner: (await sql("select partner_pay_cents from public.transport_quotes where id=$1", [q.id]))[0].partner_pay_cents };
};

test("085 éteint : le barème SECOTO s'applique comme avant", async () => {
  await setFlag085(false);
  const p = await quoteCents();
  assert.deepEqual(p, { client: 48000, partner: 40000 });
});

test("085 : barème de départ = prix inchangés voiture, utilitaire 1,25/1,10, moto plafonnée à 382 €", async () => {
  await setFlag(true);
  await setFlag085(true);
  assert.deepEqual(await quoteCents(), { client: 48000, partner: 40000 });
  assert.deepEqual(await quoteCents({ vehicle: { model: "TEST Master", class: "utilitaire", category: "standard", rolling: true, constraints: [] } }),
    { client: 50000, partner: 44000 });
  const moto = await quoteCents({ vehicle: { model: "TEST MT-07", class: "moto", category: "standard", rolling: true, constraints: [] } }, 900);
  assert.equal(moto.client, 38200);
  assert.equal(moto.partner, 31833);
  const nr = await quoteCents({ vehicle: { model: "TEST 308", class: "voiture", category: "standard", rolling: false, constraints: [] } });
  assert.equal(nr.partner, 46667);
  assert.equal(nr.client, 56000);
  const court = await quoteCents({}, 30);
  assert.deepEqual(court, { client: 11500, partner: 9583 });
});

test("085 : le transporteur valide ou modifie son barème ; preuve conservée", async () => {
  await setFlag085(true);
  const s0 = (await as(ids.ready, "select public.secoto_carrier_rates_status() as s"))[0].s;
  assert.equal(s0.required, true);
  assert.equal(s0.rates.voiture.eur_per_km, 1);
  assert.equal((await as(ids.client, "select public.secoto_carrier_rates_status() as s"))[0].s.concerned, false);
  const s1 = (await as(ids.ready, "select public.secoto_carrier_rates_save($1,'web') as s", [JSON.stringify({})]))[0].s;
  assert.equal(s1.required, false);
  assert.equal((await sql("select source from public.carrier_rates_confirmations where account_id=$1 order by confirmed_at desc limit 1", [ids.ready]))[0].source, "defaut");
  await assert.rejects(as(ids.ready, "select public.secoto_carrier_rates_save($1)", [JSON.stringify({ voiture: { eur_per_km: 12, minimum_eur: 90, non_rolling_eur: 60 } })]), /Prix au km/);
  await as(ids.ready, "select public.secoto_carrier_rates_save($1)", [JSON.stringify({ voiture: { eur_per_km: 0.9, minimum_eur: 90, non_rolling_eur: 60 } })]);
  assert.equal((await sql("select source from public.carrier_rates_confirmations where account_id=$1 order by confirmed_at desc limit 1", [ids.ready]))[0].source, "modifie");
});

test("085 : prix client = prix des transporteurs disponibles + commission ; diffusion à 5 % près", async () => {
  await setFlag(true);
  await setFlag085(true);
  // Seul transporteur prêt : 0,90 €/km -> 360 € pour lui, 432 € pour le client.
  assert.deepEqual(await quoteCents(), { client: 43200, partner: 36000 });
  // Un deuxième transporteur à 0,94 €/km (moins de 5 % au-dessus) et un troisième à 1,40 €/km.
  await account("t2", "transporter", { type: "vl" });
  await account("t3", "transporter", { type: "vl" });
  for (const [k, acct, rate] of [["t2", "acct_t2", 0.94], ["t3", "acct_t3", 1.40]]) {
    await as(ids[k], "select public.secoto_update_dispatch_preferences($1)", [JSON.stringify({ available: true, notify_offline: true, zones: ["92"] })]);
    await makeReady(ids[k], acct);
    await as(ids[k], "select public.secoto_carrier_rates_save($1)", [JSON.stringify({ voiture: { eur_per_km: rate, minimum_eur: 90, non_rolling_eur: 60 } })]);
  }
  await sql("update public.app_settings set value = value || '{\"min_carriers\": 1}' where key='bareme_transporteurs'");
  const o = await book(ids.client);
  await cardSaved(o.payment_id);
  assert.equal(o.client_price_cents, 43200);
  assert.ok(await offerFor(o.id, ids.ready), "le moins cher reçoit");
  assert.ok(await offerFor(o.id, ids.t2), "à moins de 5 % au-dessus : reçoit en même temps");
  assert.equal(await offerFor(o.id, ids.t3), undefined, "trop cher : ne reçoit pas");
  // Avec 3 transporteurs minimum, le prix monte au 3e moins cher pour que tous puissent la prendre.
  await sql("update public.app_settings set value = value || '{\"min_carriers\": 3}' where key='bareme_transporteurs'");
  assert.deepEqual(await quoteCents(), { client: 67200, partner: 56000 });
  // Premier qui accepte = attribué directement.
  const r = await accept(ids.t2, await offerFor(o.id, ids.t2));
  assert.equal(r.result, "pending_capture");
});

test("085 : un devis non calculé par les barèmes part à tous ; personne au prix -> SECOTO prévenu", async () => {
  await setFlag(true);
  await setFlag085(false);
  const ancien = await book(ids.client);
  await setFlag085(true);
  await cardSaved(ancien.payment_id);
  assert.ok(await offerFor(ancien.id, ids.t3), "prix SECOTO : diffusé à tous, sans filtre de barème");
  // Tous les transporteurs remontent leur prix après le devis.
  const o = await book(ids.client);
  for (const k of ["ready", "t2", "t3", "notReady"]) {
    await as(ids[k], "select public.secoto_carrier_rates_save($1)", [JSON.stringify({ voiture: { eur_per_km: 3, minimum_eur: 90, non_rolling_eur: 60 } })]);
  }
  await cardSaved(o.payment_id);
  assert.equal((await sql("select count(*)::int n from public.transport_offers where order_id=$1", [o.id]))[0].n, 0);
  assert.ok((await sql("select count(*)::int n from public.notifications where account_id=$1 and title='Aucun transporteur à ce prix'", [ids.admin]))[0].n >= 1);
});

test("085 : un chauffeur salarié ne fixe pas le barème", async () => {
  await setFlag085(true);
  await account("driver", "transporter", { type: "vl" });
  const biz = (await sql("insert into public.business_accounts(name, kind, payout_account_id, created_by) values ('TEST Transports', 'transporteur', $1, $1) returning id", [ids.t3]))[0].id;
  await sql("insert into public.business_members(business_id, account_id, role) values ($1,$2,'owner'),($1,$3,'member')", [biz, ids.t3, ids.driver]);
  assert.equal((await as(ids.driver, "select public.secoto_carrier_rates_status() as s"))[0].s.concerned, false);
  await assert.rejects(as(ids.driver, "select public.secoto_carrier_rates_save('{}')"), /Seul le transporteur/);
});
