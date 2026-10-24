// Tests d'intégration base de données — migration 099 (trois offres, débit à la confirmation).
// Exécution : PGURL=postgres://... node --test tests/db/trois-offres-099.dbtest.mjs
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
const payload = (vehicle = {}) => ({
  mode: "plateau",
  pickup: { label: "1 rue de Test 92260 Fontenay-aux-Roses", city: "Fontenay-aux-Roses", postcode: "92260", lat: 48.79, lng: 2.29 },
  delivery: { label: "1 place Test 69002 Lyon", city: "Lyon", postcode: "69002", lat: 45.76, lng: 4.83 },
  vehicle: { model: "TEST Peugeot 308", class: "voiture", category: "standard", rolling: true, constraints: [], ...vehicle },
  schedule: { pickup_date: inDays(3), slot: "matin", flexibility_days: 0 },
});
async function quote(clientId, vehicle = {}, km = 400) {
  const r = await service("select public.secoto_quote_create($1,$2,$3) as q",
    [clientId, JSON.stringify(payload(vehicle)), JSON.stringify({ distance_km: km, duration_min: 240, provider: "test" })]);
  // Le client lit son devis comme dans l'app.
  return (await as(clientId, "select secoto_private.quote_client_json(q) as j from public.transport_quotes q where q.id=$1", [r[0].q.id], "postgres"))[0].j;
}
const bookOffre = (clientId, quoteId, offre) =>
  as(clientId, "select public.secoto_od_book_offre($1,$2,$3) as r", [quoteId, offre, randomUUID()]).then((r) => r[0].r.order);
const cardSaved = (paymentId) =>
  service("select public.secoto_direct_card_saved($1,$2,'seti_test','pm_test') as r", [paymentId, `evt_${randomUUID()}`]).then((r) => r[0].r);
const offerFor = async (orderId, partnerId) =>
  (await sql("select id from public.transport_offers where order_id=$1 and partner_id=$2 and status='sent'", [orderId, partnerId]))[0]?.id;
const accept = (partnerId, offerId) =>
  as(partnerId, "select public.secoto_offer_accept($1,$2) as r", [offerId, randomUUID()]).then((r) => r[0].r);
const flag = (key, on) => sql("update public.secoto_feature_flags set enabled=$2 where key=$1", [key, on]);
const row = async (table, id) => (await sql(`select * from public.${table} where id=$1`, [id]))[0];
const clientOrder = async (orderId) => (await sql("select secoto_private.order_client_json(o) as j from public.transport_orders o where o.id=$1", [orderId]))[0].j;
const partnerOffer = async (offerId) => (await sql("select secoto_private.offer_partner_json(x) as j from public.transport_offers x where x.id=$1", [offerId]))[0].j;
const VL = ["vl1", "vl2", "vl3"];
const PL = ["pl1", "pl2", "pl3"];

test.before(async () => {
  await sql(`update public.app_settings set value = value || jsonb_build_object('sous_traitance_totale_since', '2026-09-01T00:00:00Z')
             where key = 'dispatch_policy' and value ->> 'sous_traitance_totale_since' is null`);
  await sql("update public.secoto_feature_flags set enabled = true where key in ('auto_pricing','od_payments','connect_payouts','direct_accept','dispatch_notifications','bareme_transporteurs')");
  await flag("plateau_paiement_direct", false);
  await account("client", "client");
  await account("autre", "client");
  await account("admin", "admin");
  for (const k of VL) await account(k, "transporter", { type: "vl" });
  for (const k of PL) await account(k, "transporter", { type: "pl" });
  for (const k of [...VL, ...PL]) {
    await as(ids[k], "select public.secoto_update_dispatch_preferences($1)", [JSON.stringify({ available: true, notify_offline: true, zones: ["92"] })]);
  }
  for (const k of PL) await as(ids[k], "select public.secoto_set_accepte_delai_long(true)");
});
test.after(async () => { await flag("trois_offres", false); await pool.end(); });

test("interrupteur éteint : aucune offre, parcours inchangé", async () => {
  await flag("trois_offres", false);
  const q = await quote(ids.client);
  assert.equal(q.offres, null);
  await assert.rejects(bookOffre(ids.client, q.id, "standard"), /pas encore ouvertes/);
});

test("trois offres calculées depuis la base (voiture, 400 km)", async () => {
  await flag("trois_offres", true);
  const q = await quote(ids.client);
  assert.ok(Array.isArray(q.offres), JSON.stringify(q));
  const by = Object.fromEntries(q.offres.map((o) => [o.cle, o]));
  assert.deepEqual(q.offres.map((o) => o.cle), ["express", "standard", "eco"]);
  // Standard = prix actuel du devis.
  const brut = (await sql("select prix_standard from public.transport_quotes where id=$1", [q.id]))[0].prix_standard;
  assert.equal(by.standard.client_cents, brut.client_cents);
  assert.equal(by.standard.client_cents, q.client_price_cents);
  // Express = Standard x 1,25, client ET transporteur.
  assert.equal(by.express.client_cents, Math.round(by.standard.client_cents * 1.25));
  assert.equal(by.express.partenaire_cents, Math.round(by.standard.partenaire_cents * 1.25));
  // Éco : tranche <= 500 km -> 300 € transporteur, marge 30 % -> 390 €.
  assert.equal(by.eco.partenaire_cents, 30000);
  assert.equal(by.eco.client_cents, 39000);
  assert.equal(by.eco.commission_cents, 9000);
  // Fenêtres par défaut et nombre réel de transporteurs.
  assert.deepEqual([by.express.fenetre_h, by.standard.fenetre_h, by.eco.fenetre_h], [48, 120, 360]);
  assert.equal(by.eco.transporteurs, 3, "seuls les 3 PL volontaires");
  assert.ok(by.standard.transporteurs >= 6, `standard: ${by.standard.transporteurs}`);
  assert.equal(by.standard.recommande, true);
});

test("Éco : tranches de distance, plus chère que Standard -> masquée ; moto plafonnée puis x 1,25 ; pas d'Éco en moto", async () => {
  await flag("trois_offres", true);
  const q800 = await quote(ids.client, {}, 800);
  const eco800 = q800.offres.find((o) => o.cle === "eco");
  assert.equal(eco800.partenaire_cents, 50000);
  assert.equal(eco800.client_cents, 65000);
  const q1500 = await quote(ids.client, {}, 1500);
  const eco1500 = q1500.offres.find((o) => o.cle === "eco");
  assert.equal(eco1500.partenaire_cents, 80000);
  assert.equal(eco1500.client_cents, 96000);
  // Court trajet : l'Éco (390 €) serait plus chère que Standard -> absente.
  const q100 = await quote(ids.client, {}, 100);
  assert.equal(q100.offres.find((o) => o.cle === "eco"), undefined);
  // Moto 900 km, 92 → 69 (hors couloir 117) : Standard dégressif 816 €, Express = 816 x 1,25.
  const moto = await quote(ids.client, { model: "TEST Yamaha MT-07", class: "moto" }, 900);
  const std = moto.offres.find((o) => o.cle === "standard");
  assert.equal(std.client_cents, 81600);
  assert.equal(moto.offres.find((o) => o.cle === "express").client_cents, Math.round(81600 * 1.25));
  assert.equal(moto.offres.find((o) => o.cle === "eco"), undefined);
  // Non roulant : pas d'Éco (porte-voitures).
  const nr = await quote(ids.client, { rolling: false }, 800);
  assert.equal(nr.offres.find((o) => o.cle === "eco"), undefined);
});

test("seuil : une offre n'apparaît qu'avec 3 transporteurs ; aucune -> parcours actuel", async () => {
  await flag("trois_offres", true);
  await sql("update public.app_settings set value = value || '{\"seuil_transporteurs\": 4}' where key='trois_offres'");
  let q = await quote(ids.client, {}, 800);
  assert.equal(q.offres.find((o) => o.cle === "eco"), undefined, "3 PL < seuil 4");
  await sql("update public.app_settings set value = value || '{\"seuil_transporteurs\": 50}' where key='trois_offres'");
  q = await quote(ids.client, {}, 800);
  assert.equal(q.offres, null);
  await sql("update public.app_settings set value = value || '{\"seuil_transporteurs\": 3}' where key='trois_offres'");
});

test("réservation Standard : carte enregistrée sans débit, diffusion jusqu'à la fin de la fenêtre, débit à la confirmation", async () => {
  await flag("trois_offres", true);
  const q = await quote(ids.client);
  const std = q.offres.find((o) => o.cle === "standard");
  await assert.rejects(bookOffre(ids.autre, q.id, "standard"), /introuvable/);
  await assert.rejects(bookOffre(ids.client, q.id, "premium"), /plus disponible/);
  const o = await bookOffre(ids.client, q.id, "standard");
  assert.equal(o.offre, "standard");
  assert.equal(o.client_price_cents, std.client_cents);
  assert.equal(o.debit_a_confirmation, true);
  assert.equal(o.transport_price_cents, std.partenaire_cents);
  const ord = await row("transport_orders", o.id);
  const attendu = Math.max(Date.now(), Date.parse(ord.pickup_at)) + 120 * 3600e3;
  assert.ok(Math.abs(Date.parse(ord.fenetre_fin) - attendu) < 120e3, "fenêtre de 5 jours");
  let pay = await row("payments", o.payment_id);
  assert.equal(pay.capture_method, "manual");
  assert.equal(pay.debit_a_confirmation, true);
  assert.equal(pay.status, "pending");
  // Même offre redemandée (double appui) : même commande.
  const again = await as(ids.client, "select public.secoto_od_book_offre($1,'standard',$2) as r", [q.id, randomUUID()]);
  assert.equal(again[0].r.order.id, o.id);

  // Carte enregistrée -> diffusion, rien n'est débité.
  const saved = await cardSaved(o.payment_id);
  assert.equal(saved.effect, "dispatch_opened");
  pay = await row("payments", o.payment_id);
  assert.equal(pay.status, "requires_capture");
  assert.equal(pay.paid_at, null);
  const offre = await offerFor(o.id, ids.vl1);
  assert.ok(offre);
  const x = await row("transport_offers", offre);
  assert.equal(new Date(x.expires_at).getTime(), new Date((await row("transport_orders", o.id)).fenetre_fin).getTime());
  const vueTransporteur = await partnerOffer(offre);
  assert.equal(vueTransporteur.offre, "standard");
  assert.equal(vueTransporteur.partner_pay_cents, std.partenaire_cents);
  assert.equal(JSON.stringify(vueTransporteur).includes(String(std.client_cents)), false, "jamais le prix client");
  const notif = await sql("select title from public.notifications where account_id=$1 order by created_at desc limit 1", [ids.client]);
  assert.match(notif[0].title, /Carte/);
  assert.equal((await clientOrder(o.id)).transporteurs_sollicites, 6);

  // Acceptation -> le serveur débite (contexte) puis confirme.
  const r = await accept(ids.vl2, await offerFor(o.id, ids.vl2));
  assert.equal(r.result, "pending_capture");
  const ctx = (await service("select public.secoto_differe_charge_context($1) as r", [o.id]))[0].r;
  assert.equal(ctx.amount_cents, std.client_cents);
  assert.equal(ctx.payment_method_id, "pm_test");
  assert.equal(ctx.order_status, "partner_locked");
  await assert.rejects(as(ids.client, "select public.secoto_differe_charge_context($1)", [o.id]), /permission denied/);
  const c = (await service("select public.secoto_od_capture_result($1,true,null) as r", [o.id]))[0].r;
  assert.equal(c.result, "confirmed");
  assert.equal((await row("payments", o.payment_id)).status, "paid");
  assert.equal((await row("transport_orders", o.id)).status, "partner_confirmed");
});

test("3D Secure : mission réservée 24 h, puis rediffusée sans débit si non validée", async () => {
  await flag("trois_offres", true);
  const q = await quote(ids.client);
  const o = await bookOffre(ids.client, q.id, "express");
  await cardSaved(o.payment_id);
  const notifTransp = await sql("select title from public.notifications where account_id=$1 and type='mission_offer' order by created_at desc limit 1", [ids.vl1]);
  assert.match(notifTransp[0].title, /Express/);
  assert.equal((await accept(ids.vl1, await offerFor(o.id, ids.vl1))).result, "pending_capture");
  const na = (await service("select public.secoto_differe_needs_action($1) as r", [o.id]))[0].r;
  assert.equal(na.wait_minutes, 1440);
  const ord = await row("transport_orders", o.id);
  assert.ok(Date.parse(ord.lock_expires_at) - Date.now() > 23 * 3600e3);
  assert.equal((await clientOrder(o.id)).payment_action_required, true);
  // Le client ne valide pas : délai écoulé.
  const exp = (await service("select public.secoto_differe_action_expired($1) as r", [o.id]))[0].r;
  assert.equal(exp.result, "released");
  const after = await row("transport_orders", o.id);
  assert.equal(after.status, "searching_partner");
  const pay = await row("payments", o.payment_id);
  assert.equal(pay.status, "requires_capture");
  assert.equal(pay.direct_action_required_at, null);
  assert.ok(await offerFor(o.id, ids.vl2), "les autres transporteurs peuvent encore confirmer");
  // Une tentative annulée chez Stripe n'annule ni la carte ni la commande.
  await service("select public.secoto_od_apply_payment_event($1,$2,'payment_intent.canceled','pi_x',0,null,null)", [o.payment_id, `evt_${randomUUID()}`]);
  assert.equal((await row("transport_orders", o.id)).status, "searching_partner");
});

test("fenêtre écoulée : aucun débit, annulation automatique, relance en un clic", async () => {
  await flag("trois_offres", true);
  const q = await quote(ids.client);
  const o = await bookOffre(ids.client, q.id, "standard");
  await cardSaved(o.payment_id);
  await sql("update public.transport_orders set offers_expire_at = now() - interval '1 minute', fenetre_fin = now() - interval '1 minute' where id=$1", [o.id]);
  const tick = (await service("select public.secoto_od_maintenance_tick() as r"))[0].r;
  assert.ok(tick.no_partner >= 1);
  assert.equal((await row("transport_orders", o.id)).status, "no_partner");
  const action = tick.payment_actions.find((a) => a.payment_id === o.payment_id);
  assert.equal(action.action, "cancel");
  assert.equal(action.intent_id, null, "rien à rembourser : aucune somme n'a été prise");
  await service("select public.secoto_od_payment_action_result($1,'cancel',true,null)", [o.payment_id]);
  assert.equal((await row("payments", o.payment_id)).status, "cancelled");
  const n = await sql("select body from public.notifications where account_id=$1 and title='Aucun transporteur disponible' order by created_at desc limit 1", [ids.client]);
  assert.match(n[0].body, /Rien n'a été débité/);
  // Relance : nouveau devis, même trajet, offres recalculées (Express proposé).
  const nq = (await as(ids.client, "select public.secoto_od_reproposer($1) as r", [o.id]))[0].r;
  assert.notEqual(nq.id, q.id);
  assert.ok(nq.offres.some((x) => x.cle === "express"));
  assert.equal(nq.offres.find((x) => x.cle === "standard").client_cents, q.offres.find((x) => x.cle === "standard").client_cents);
  await assert.rejects(as(ids.autre, "select public.secoto_od_reproposer($1)", [o.id]), /introuvable/);
});

test("Éco : 107 -> tous les VL/PL reçoivent, au barème fixe", async () => {
  await flag("trois_offres", true);
  const q = await quote(ids.client, {}, 800);
  const o = await bookOffre(ids.client, q.id, "eco");
  await cardSaved(o.payment_id);
  for (const k of PL) assert.ok(await offerFor(o.id, ids[k]), `${k} reçoit`);
  for (const k of VL) assert.ok(await offerFor(o.id, ids[k]), `107 : ${k} reçoit aussi`);
  const x = await row("transport_offers", await offerFor(o.id, ids.pl1));
  assert.equal(x.partner_pay_cents, 50000);
  const ord = await row("transport_orders", o.id);
  assert.ok(Math.abs(Date.parse(ord.fenetre_fin) - (Math.max(Date.now(), Date.parse(ord.pickup_at)) + 360 * 3600e3)) < 120e3);
});

test("préférence « délai long » : ne change pas la disponibilité", async () => {
  await account("neuf", "transporter", { type: "pl" });
  await as(ids.neuf, "select public.secoto_set_accepte_delai_long(true)");
  const p = (await sql("select available, accepte_delai_long from public.partner_dispatch_preferences where account_id=$1", [ids.neuf]))[0];
  assert.deepEqual(p, { available: true, accepte_delai_long: true });
  await as(ids.vl1, "select public.secoto_update_dispatch_preferences($1)", [JSON.stringify({ available: false, zones: ["92"] })]);
  await as(ids.vl1, "select public.secoto_set_accepte_delai_long(true)");
  assert.equal((await sql("select available from public.partner_dispatch_preferences where account_id=$1", [ids.vl1]))[0].available, false);
  await as(ids.vl1, "select public.secoto_update_dispatch_preferences($1)", [JSON.stringify({ available: true, zones: ["92"] })]);
  await assert.rejects(as(ids.client, "select public.secoto_set_accepte_delai_long(true)"), /transporteurs/);
});

test("admin : réglages validés, mesure par offre", async () => {
  const cur = (await as(ids.admin, "select public.secoto_admin_trois_offres() as r"))[0].r;
  assert.equal(cur.actif, true);
  await assert.rejects(as(ids.client, "select public.secoto_admin_trois_offres()"), /./);
  const bad = { ...cur.reglages, express: { coef: 9, fenetre_h: 48 } };
  await assert.rejects(as(ids.admin, "select public.secoto_admin_set_trois_offres($1)", [JSON.stringify(bad)]), /Coefficient Express/);
  const ok = { ...cur.reglages, express: { coef: 1.3, fenetre_h: 36 } };
  const saved = (await as(ids.admin, "select public.secoto_admin_set_trois_offres($1) as r", [JSON.stringify(ok)]))[0].r;
  assert.equal(saved.express.coef, 1.3);
  const q = await quote(ids.client);
  assert.equal(q.offres.find((o) => o.cle === "express").fenetre_h, 36);
  await as(ids.admin, "select public.secoto_admin_set_trois_offres($1)", [JSON.stringify(cur.reglages)]);
  const stats = (await as(ids.admin, "select public.secoto_admin_offres_stats(30) as r"))[0].r;
  const std = stats.offres.find((s) => s.cle === "standard");
  assert.ok(std.affichees >= 1 && std.choisies >= 2 && std.acceptees >= 1, JSON.stringify(std));
  assert.ok(std.fenetre_expiree >= 1);
  assert.ok(std.commission_cents > 0);
});
