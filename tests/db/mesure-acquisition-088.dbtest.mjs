// Tests d'intégration base de données — migration 088 (mesure de l'acquisition, test, réseau, couverture).
// Exécution : PGURL=postgres://... node --test tests/db/mesure-acquisition-088.dbtest.mjs
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
const quotePayload = () => ({
  mode: "plateau",
  pickup: { label: "1 rue de Test 92260 Fontenay-aux-Roses", city: "Fontenay-aux-Roses", postcode: "92260", lat: 48.79, lng: 2.29 },
  delivery: { label: "1 place Test 69002 Lyon", city: "Lyon", postcode: "69002", lat: 45.76, lng: 4.83 },
  vehicle: { model: "TEST Peugeot 308", class: "voiture", category: "standard", rolling: true, constraints: [] },
  schedule: { pickup_date: inDays(5), slot: "matin", flexibility_days: 0 },
});
async function quote(clientId, over = {}) {
  const p = quotePayload();
  return (await service("select public.secoto_quote_create($1,$2,$3) as q",
    [clientId, JSON.stringify({ ...p, ...over }), JSON.stringify({ distance_km: 400, duration_min: 240, provider: "test" })]))[0].q;
}
async function bookQuote(clientId, q) {
  return (await as(clientId, "select public.secoto_od_book_quote($1,false,$2) as r", [q.id, randomUUID()]))[0].r.order;
}
async function book(clientId) { return bookQuote(clientId, await quote(clientId)); }
const setDirect = (on) => sql("update public.secoto_feature_flags set enabled = $1 where key = 'plateau_paiement_direct'", [on]);
const cardSaved = (paymentId) =>
  service("select public.secoto_direct_card_saved($1,$2,'seti_test','pm_test') as r", [paymentId, `evt_${randomUUID()}`]);
const paidOld = (paymentId) => service("select public.secoto_od_apply_payment_event($1,$2,'payment_intent.succeeded','pi_' || $1::uuid::text,0,null,null) as r",
  [paymentId, `evt_${randomUUID()}`]);
const offerFor = async (orderId, partnerId) =>
  (await sql("select id from public.transport_offers where order_id=$1 and partner_id=$2 and status='sent'", [orderId, partnerId]))[0]?.id;
async function makeReady(partnerId, acct) {
  await sql(`update public.accounts set stripe_connect_account_id=$2, stripe_connect_status='active',
             stripe_transfers_enabled=true, stripe_payouts_enabled=true, stripe_card_payments_enabled=true, stripe_payouts_manual=true where id=$1`, [partnerId, acct]);
  await as(partnerId, "select public.secoto_carrier_accept_billing_mandate($1,$2,$3,$4,$5,$6)",
    ["2026-10-08", "TEST Transports SARL", "123 456 789", "1 rue du Test 92000 Nanterre", "franchise", null]);
}

const now = new Date();
const debutMois = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), 1)).toISOString().slice(0, 10);
const debutMoisSuivant = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth() + 1, 1)).toISOString().slice(0, 10);
const urssaf = (who) => as(who, "select public.secoto_dirigeant_urssaf($1::date,$2::date) as r", [debutMois, debutMoisSuivant]).then((r) => r[0].r);
const ligne = (r, ref) => r.lignes.find((l) => l.reference === ref);


const conv = (paymentId) => sql("select * from public.ad_conversions where payment_id=$1", [paymentId]).then((r) => r[0]);

test.before(async () => {
  await sql(`update public.app_settings set value = value || jsonb_build_object('sous_traitance_totale_since', '2026-09-01T00:00:00Z')
             where key = 'dispatch_policy' and value ->> 'sous_traitance_totale_since' is null`);
  await sql("update public.secoto_feature_flags set enabled = true where key in ('auto_pricing','od_payments','connect_payouts','direct_accept','dispatch_notifications')");
  await setDirect(false);
  await account("admin", "admin");
  await account("client", "client");
  await account("client2", "client");
  await account("ready", "transporter", { type: "vl" });
  await account("interne", "transporter", { type: "vl" });
  await sql("insert into secoto_private.dirigeants(account_id) values ($1)", [ids.admin]);
  await as(ids.ready, "select public.secoto_update_dispatch_preferences($1)", [JSON.stringify({ available: true, notify_offline: true, zones: ["92"] })]);
  await makeReady(ids.ready, `acct_test_${randomUUID().slice(0, 8)}`);
});
test.after(async () => { await pool.end(); });

const ATTR = { utm_source: "google", utm_medium: "cpc", utm_campaign: "plateau-idf", utm_content: "annonce-a", gclid: "Cj0TEST_gclid-123", fbclid: "IwTEST", at: new Date().toISOString() };

test("088 : provenance du devis recopiée sur la commande, valeurs nettoyées", async () => {
  const q = await quote(ids.client);
  await service("select public.secoto_attribution_devis($1,$2,$3)", [q.id, JSON.stringify({ ...ATTR, utm_campaign: "plateau<script>idf" }), true]);
  const qq = (await sql("select * from public.transport_quotes where id=$1", [q.id]))[0];
  assert.equal(qq.utm_campaign, "plateauscriptidf", "caractères dangereux retirés");
  assert.equal(qq.gclid, ATTR.gclid);
  // Premier remplissage conservé : un second appel ne l'écrase pas.
  await service("select public.secoto_attribution_devis($1,$2,null)", [q.id, JSON.stringify({ utm_source: "autre" })]);
  assert.equal((await sql("select utm_source from public.transport_quotes where id=$1", [q.id]))[0].utm_source, "google");
  const o = await bookQuote(ids.client, q);
  const oo = (await sql("select * from public.transport_orders where id=$1", [o.id]))[0];
  assert.equal(oo.utm_source, "google");
  assert.equal(oo.utm_campaign, "plateauscriptidf");
  assert.equal(oo.gclid, ATTR.gclid);
  assert.equal(oo.consentement_pub, true);
  assert.equal(oo.is_test, false);
  // Un client ne peut pas appeler la fonction réservée au serveur.
  await assert.rejects(as(ids.client, "select public.secoto_attribution_devis($1,'{}'::jsonb,true)", [q.id]), /permission denied/);
});

test("088 : compte créé avec la provenance de l'inscription ; le client met à jour son choix", async () => {
  const id = randomUUID();
  await sql("insert into auth.users(id, email, raw_user_meta_data) values ($1,$2,$3)",
    [id, `meta-${id.slice(0, 6)}@test.invalid`, JSON.stringify({ attribution: { utm_source: "facebook", utm_campaign: "moto", fbclid: "IwABC" }, consentement_pub: false })]);
  await sql(`insert into public.accounts(id, role, full_name, email, status, is_verified, client_type)
             values ($1,'client','TEST meta',$2,'active',true,'particulier') on conflict (id) do nothing`, [id, `meta-${id.slice(0, 6)}@test.invalid`]);
  let a = (await sql("select * from public.accounts where id=$1", [id]))[0];
  assert.equal(a.utm_source, "facebook");
  assert.equal(a.fbclid, "IwABC");
  assert.equal(a.consentement_pub, false);
  await as(id, "select public.secoto_mon_attribution($1,true)", [JSON.stringify({ utm_source: "google" })]);
  a = (await sql("select * from public.accounts where id=$1", [id]))[0];
  assert.equal(a.utm_source, "facebook", "la provenance d'origine n'est pas écrasée");
  assert.equal(a.consentement_pub, true);
  await assert.rejects(as(null, "select public.secoto_mon_attribution(null,true)", [], "anon"), /permission denied/);
});

test("088 : commande payée -> conversion (valeur = commission), seulement avec consentement", async () => {
  await sql("update public.accounts set consentement_pub = true where id=$1", [ids.client]);
  const q = await quote(ids.client);
  await service("select public.secoto_attribution_devis($1,$2,true)", [q.id, JSON.stringify(ATTR)]);
  const o = await bookQuote(ids.client, q);
  await paidOld(o.payment_id);
  const c = await conv(o.payment_id);
  assert.ok(c, "une conversion est créée au paiement");
  assert.equal(c.value_cents, 8000);
  assert.equal(c.event_id, `cmd-${o.payment_id}`);
  assert.equal(c.meta_status, "pending");
  assert.match(c.email_sha256, /^[0-9a-f]{64}$/);
  const aEnvoyer = (await service("select public.secoto_conversions_meta_a_envoyer(50) as r"))[0].r;
  const ligne = aEnvoyer.find((x) => x.event_id === c.event_id);
  assert.equal(Number(ligne.value), 80);
  assert.equal(ligne.fbclid, "IwTEST");
  await service("select public.secoto_conversion_meta_resultat($1,true,null)", [c.id]);
  assert.equal((await conv(o.payment_id)).meta_status, "sent");
  const google = (await service("select public.secoto_conversions_google() as r"))[0].r;
  assert.ok(google.some((x) => x.event_id === c.event_id && x.gclid === ATTR.gclid));
  // Refus : la conversion est notée mais jamais envoyée.
  await sql("update public.accounts set consentement_pub = false where id=$1", [ids.client2]);
  const o2 = await book(ids.client2);
  await paidOld(o2.payment_id);
  assert.equal((await conv(o2.payment_id)).meta_status, "skipped");
  const aEnvoyer2 = (await service("select public.secoto_conversions_meta_a_envoyer(50) as r"))[0].r;
  assert.ok(!aEnvoyer2.some((x) => x.event_id === `cmd-${o2.payment_id}`));
  // Commande de test : aucune conversion.
  const o3 = await book(ids.client);
  await sql("update public.transport_orders set is_test = true where id=$1", [o3.id]);
  await paidOld(o3.payment_id);
  assert.equal(await conv(o3.payment_id), undefined);
  // Personne d'autre que le serveur ne lit ces lignes.
  await assert.rejects(as(ids.client, "select * from public.ad_conversions"), /permission denied/);
  await assert.rejects(as(ids.admin, "select public.secoto_conversions_meta_a_envoyer(5)"), /permission denied/);
});

test("088 : missions et commandes de test exclues de l'espace dirigeant et de l'URSSAF", async () => {
  const o = await book(ids.client);
  await paidOld(o.payment_id);
  assert.ok(ligne(await urssaf(ids.admin), o.public_ref), "visible avant");
  await sql("update public.transport_orders set is_test = true where id=$1", [o.id]);
  assert.equal(ligne(await urssaf(ids.admin), o.public_ref), undefined, "exclue une fois marquée test");
  const ref = `MIS-TEST-${randomUUID().slice(0, 6)}`;
  await sql(`insert into public.missions(public_ref, type, status, from_city, to_city, client_account_id, payment_method, commission_settled_offline, commission_settled_at, is_test)
             values ($1,'plateau','completed','Montrouge','Montrouge',$2,'especes',true,now(),true)`, [ref, ids.client]);
  const mid = (await sql("select id from public.missions where public_ref=$1", [ref]))[0].id;
  await as(ids.admin, "select public.secoto_admin_set_mission_pricing($1,true,300,60,$2)", [mid, randomUUID()]);
  assert.equal(ligne(await urssaf(ids.admin), ref), undefined);
});

test("088 : tableau d'acquisition (admin) par source et campagne", async () => {
  const debut = new Date(Date.now() - 86400000).toISOString().slice(0, 10);
  const fin = new Date(Date.now() + 2 * 86400000).toISOString().slice(0, 10);
  const r = (await as(ids.admin, "select public.secoto_admin_acquisition($1::date,$2::date) as r", [debut, fin]))[0].r;
  const g = r.lignes.find((l) => l.source === "google" && l.campagne === "plateau-idf");
  assert.ok(g, JSON.stringify(r.lignes));
  assert.ok(g.prix_affiches >= 1);
  assert.ok(g.commandes_payees >= 1);
  assert.ok(Number(g.commission_cents) >= 8000);
  assert.ok(r.lignes.some((l) => l.source === "facebook"), "compte venu de Facebook compté");
  await assert.rejects(as(ids.client, "select public.secoto_admin_acquisition($1::date,$2::date)", [debut, fin]), /./);
});

test("088 : réseau sans les comptes internes ; couverture départements + moto", async () => {
  await sql("update public.accounts set is_internal = true where id=$1", [ids.interne]);
  const avant = (await as(ids.admin, "select public.secoto_admin_reseau() as r"))[0].r;
  const total = avant.resume.transporteurs;
  await sql("update public.accounts set is_internal = false where id=$1", [ids.interne]);
  const apres = (await as(ids.admin, "select public.secoto_admin_reseau() as r"))[0].r;
  assert.equal(apres.resume.transporteurs, total + 1, "le compte interne était exclu");
  await sql("update public.accounts set is_internal = true where id=$1", [ids.interne]);

  let s = (await as(ids.ready, "select public.secoto_carrier_coverage_status() as r"))[0].r;
  assert.equal(s.required, true);
  assert.equal(s.moto, false, "moto décochée par défaut");
  await assert.rejects(as(ids.ready, "select public.secoto_carrier_coverage_save($1,false)", [["99"]]), /Département inconnu/);
  await assert.rejects(as(ids.ready, "select public.secoto_carrier_coverage_save($1,false)", [[]]), /au moins un département/);
  s = (await as(ids.ready, "select public.secoto_carrier_coverage_save($1,false) as r", [["92", "75", "2a"]]))[0].r;
  assert.equal(s.required, false);
  let p = (await sql("select zones, departements_base, vehicle_classes from public.partner_dispatch_preferences where account_id=$1", [ids.ready]))[0];
  assert.deepEqual([...p.departements_base].sort(), ["2A", "75", "92"]);
  assert.deepEqual(p.zones, [], "aucune restriction : il reçoit les missions de toute la France");
  assert.ok(!p.vehicle_classes.includes("moto"));
  assert.ok(p.vehicle_classes.includes("voiture"));
  s = (await as(ids.ready, "select public.secoto_carrier_coverage_save($1,true) as r", [["92"]]))[0].r;
  assert.equal(s.moto, true);
  p = (await sql("select vehicle_classes from public.partner_dispatch_preferences where account_id=$1", [ids.ready]))[0];
  assert.ok(p.vehicle_classes.includes("moto"));
  // Un client n'est jamais concerné.
  assert.equal((await as(ids.client, "select public.secoto_carrier_coverage_status() as r"))[0].r.required, false);
  await assert.rejects(as(ids.client, "select public.secoto_carrier_coverage_save($1,true)", [["92"]]), /Réservé aux transporteurs/);
});
