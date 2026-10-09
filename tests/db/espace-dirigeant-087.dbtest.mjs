// Tests d'intégration base de données — migration 087 (espace dirigeant).
// Exécution : PGURL=postgres://... node --test tests/db/espace-dirigeant-087.dbtest.mjs
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
async function book(clientId) {
  const q = (await service("select public.secoto_quote_create($1,$2,$3) as q",
    [clientId, JSON.stringify(quotePayload()), JSON.stringify({ distance_km: 400, duration_min: 240, provider: "test" })]))[0].q;
  return (await as(clientId, "select public.secoto_od_book_quote($1,false,$2) as r", [q.id, randomUUID()]))[0].r.order;
}
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

test.before(async () => {
  await sql(`update public.app_settings set value = value || jsonb_build_object('sous_traitance_totale_since', '2026-09-01T00:00:00Z')
             where key = 'dispatch_policy' and value ->> 'sous_traitance_totale_since' is null`);
  await sql("update public.secoto_feature_flags set enabled = true where key in ('auto_pricing','od_payments','connect_payouts','direct_accept','dispatch_notifications')");
  await account("dirigeant", "admin");
  await account("autreAdmin", "admin");
  await account("client", "client");
  await account("ready", "transporter", { type: "vl" });
  await as(ids.ready, "select public.secoto_update_dispatch_preferences($1)", [JSON.stringify({ available: true, notify_offline: true, zones: ["92"] })]);
  await makeReady(ids.ready, `acct_test_${randomUUID().slice(0, 8)}`);
});
test.after(async () => { await setDirect(false); await pool.end(); });

test("087 : personne n'a accès tant que la liste est vide, puis seul le dirigeant", async () => {
  assert.equal((await as(ids.dirigeant, "select public.secoto_dirigeant_acces() as r"))[0].r, false);
  await assert.rejects(as(ids.dirigeant, "select public.secoto_dirigeant_tableau(null)"), /réservé au dirigeant/);

  await sql("insert into secoto_private.dirigeants(account_id) values ($1)", [ids.dirigeant]);
  assert.equal((await as(ids.dirigeant, "select public.secoto_dirigeant_acces() as r"))[0].r, true);
  assert.equal((await as(ids.autreAdmin, "select public.secoto_dirigeant_acces() as r"))[0].r, false);
  for (const who of [ids.autreAdmin, ids.client, ids.ready]) {
    await assert.rejects(as(who, "select public.secoto_dirigeant_tableau(null)"), /réservé au dirigeant/);
    await assert.rejects(as(who, "select public.secoto_dirigeant_urssaf('2026-01-01','2026-02-01')"), /réservé au dirigeant/);
    await assert.rejects(as(who, "select public.secoto_dirigeant_litiges()"), /réservé au dirigeant/);
  }
  // Personne ne lit la liste ni les lignes directement.
  await assert.rejects(as(ids.dirigeant, "select * from secoto_private.dirigeants"), /permission denied/);
  await assert.rejects(as(ids.dirigeant, "select * from secoto_private.dirigeant_lignes()"), /permission denied/);
  await assert.rejects(as(null, "select public.secoto_dirigeant_acces()", [], "anon"), /permission denied/);
  // Un client ne peut pas s'ajouter à la liste.
  await assert.rejects(as(ids.client, "insert into secoto_private.dirigeants(account_id) values ($1)", [ids.client]), /permission denied/);
  // Un compte retiré du rôle administrateur perd l'accès, même inscrit.
  await sql("insert into secoto_private.dirigeants(account_id) values ($1)", [ids.client]);
  assert.equal((await as(ids.client, "select public.secoto_dirigeant_acces() as r"))[0].r, false);
  await sql("delete from secoto_private.dirigeants where account_id=$1", [ids.client]);
});

test("087 : ancien circuit (prix complet encaissé) — commission = prix client − part transporteur", async () => {
  await setDirect(false);
  const o = await book(ids.client);
  await paidOld(o.payment_id);
  const r = await urssaf(ids.dirigeant);
  const l = ligne(r, o.public_ref);
  assert.ok(l, "la commande payée apparaît");
  assert.equal(l.encaisse_cents, 48000);
  assert.equal(l.reverse_cents, 40000);
  assert.equal(l.commission_cents, 8000);
  assert.equal(l.trajet, "Fontenay-aux-Roses → Lyon");
  // Le versement réellement créé remplace la part prévue.
  const m = (await sql(`insert into public.missions(public_ref, type, status, from_city, to_city, client_account_id)
      values ('MIS-TEST-' || substr(md5(random()::text),1,6), 'plateau', 'assigned', 'Fontenay', 'Lyon', $1) returning id`, [ids.client]))[0].id;
  await sql("insert into public.partner_payouts(mission_id, order_id, partner_id, amount_cents) values ($1,$2,$3,39000)", [m, o.id, ids.ready]);
  assert.equal(ligne(await urssaf(ids.dirigeant), o.public_ref).commission_cents, 9000);
  // Remboursement intégral : plus de commission.
  await sql("delete from public.partner_payouts where order_id=$1", [o.id]);
  await sql("update public.transport_orders set status='cancelled', cancelled_at=now() where id=$1", [o.id]);
  await sql("update public.payments set status='refunded', refunded_amount_cents=amount_cents where id=$1", [o.payment_id]);
  const apres = ligne(await urssaf(ids.dirigeant), o.public_ref);
  assert.equal(apres.commission_cents, 0);
  assert.equal(apres.rembourse_cents, 48000);
});

test("087 : paiement direct au transporteur — seule la commission revient à SECOTO", async () => {
  await setDirect(true);
  const o = await book(ids.client);
  await cardSaved(o.payment_id);
  const r1 = (await as(ids.ready, "select public.secoto_offer_accept($1,$2) as r", [await offerFor(o.id, ids.ready), randomUUID()]))[0].r;
  assert.equal(r1.result, "pending_capture", JSON.stringify(r1));
  await service("select public.secoto_direct_charge_context($1)", [o.id]);
  await service("select public.secoto_od_capture_result($1,true,null)", [o.id]);
  const l = ligne(await urssaf(ids.dirigeant), o.public_ref);
  assert.ok(l, "la commande payée en direct apparaît");
  assert.equal(l.encaisse_cents, 48000);
  assert.equal(l.commission_cents, 8000);
  assert.equal(l.reverse_cents, 40000);
  // Remboursement partiel : la commission baisse à proportion (Stripe rend la même part des frais).
  await sql("update public.payments set refunded_amount_cents=24000 where id=$1", [o.payment_id]);
  assert.equal(ligne(await urssaf(ids.dirigeant), o.public_ref).commission_cents, 4000);
  // Contestation bancaire : visible dans les litiges.
  await sql("update public.payments set dispute_status='open', last_event_at=now() where id=$1", [o.payment_id]);
  const lit = (await as(ids.dirigeant, "select public.secoto_dirigeant_litiges() as r"))[0].r;
  const c = lit.contestations.find((x) => x.reference === o.public_ref);
  assert.equal(c.statut, "open");
  assert.equal(c.montant_cents, 48000);
  await setDirect(false);
});

test("087 : commission réglée hors application et commission en espèces due", async () => {
  const ref = `MIS-TEST-${randomUUID().slice(0, 6)}`;
  const m = (await sql(`insert into public.missions(public_ref, type, status, from_city, to_city, client_account_id, assigned_transporter_id, payment_method)
      values ($1, 'plateau', 'completed', 'Massy', 'Lille', $2, $3, 'especes') returning id`, [ref, ids.client, ids.ready]))[0].id;
  await as(ids.dirigeant, "select public.secoto_admin_set_mission_pricing($1,true,300,60,$2)", [m, randomUUID()]);
  const com = Math.round(Number((await sql("select coalesce(nullif(commission_amount,0), margin) c from public.missions where id=$1", [m]))[0].c) * 100);
  assert.ok(com > 0);
  // Due, pas encore réglée : dans « commissions espèces dues », pas dans l'URSSAF.
  await sql("update public.missions set commission_due_since=now() where id=$1", [m]);
  let t = (await as(ids.dirigeant, "select public.secoto_dirigeant_tableau(null) as r"))[0].r;
  assert.ok(t.commissions_especes_dues.liste.some((x) => x.reference === ref));
  assert.equal(ligne(await urssaf(ids.dirigeant), ref), undefined);
  // Réglée : elle sort des dues et entre dans la commission du mois.
  await sql("update public.missions set commission_settled_offline=true, commission_settled_at=now() where id=$1", [m]);
  t = (await as(ids.dirigeant, "select public.secoto_dirigeant_tableau(null) as r"))[0].r;
  assert.ok(!t.commissions_especes_dues.liste.some((x) => x.reference === ref));
  const l = ligne(await urssaf(ids.dirigeant), ref);
  assert.equal(l.commission_cents, com);
  assert.equal(l.libelle, "Commission réglée hors application");
});

test("087 : tableau de bord — 12 mois, totaux cohérents avec la déclaration, en attente", async () => {
  const o = await book(ids.client); // reste en attente de paiement
  const t = (await as(ids.dirigeant, "select public.secoto_dirigeant_tableau(null) as r"))[0].r;
  assert.equal(t.mois.length, 12);
  const mois = t.mois[now.getUTCMonth()];
  const r = await urssaf(ids.dirigeant);
  assert.equal(Number(mois.commission_cents), Number(r.commission_cents));
  assert.equal(r.a_declarer_euros, Math.round(Math.max(r.commission_cents, 0) / 100));
  assert.ok(t.en_attente.liste.some((x) => x.reference === o.public_ref));
  assert.ok(t.annees.includes(now.getUTCFullYear()));
  // Période invalide refusée.
  await assert.rejects(as(ids.dirigeant, "select public.secoto_dirigeant_urssaf('2026-02-01','2026-01-01')"), /Période invalide/);
});

test("087 : SAV comptées dans le suivi des litiges", async () => {
  const before = (await as(ids.dirigeant, "select public.secoto_dirigeant_litiges() as r"))[0].r.sav;
  await sql("insert into public.sav_requests(public_ref, account_id, motif, message) values ('SAV-TEST-' || substr(md5(random()::text),1,6), $1, 'dommage', 'TEST rayure')", [ids.client]);
  const after = (await as(ids.dirigeant, "select public.secoto_dirigeant_litiges() as r"))[0].r.sav;
  assert.equal(after.ouvertes, before.ouvertes + 1);
  assert.equal(after.dommages_ouverts, before.dommages_ouverts + 1);
});
