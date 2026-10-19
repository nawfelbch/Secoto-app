// Tests d'intégration base de données — migration 101 (urgent, propositions,
// modifications SECOTO). Base JETABLE uniquement, jamais la production.
// Exécution : PGURL=postgres://... node --test tests/db/missions-propositions-101.dbtest.mjs
import test from "node:test";
import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import pg from "pg";

const PGURL = process.env.PGURL;
if (!PGURL) throw new Error("PGURL requis (base de test jetable).");
const pool = new pg.Pool({ connectionString: PGURL, max: 6 });

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

const ids = {};
async function account(key, role, type = null) {
  const id = randomUUID();
  ids[key] = id;
  await sql(`insert into public.accounts(id, role, full_name, email, status, is_verified, transporter_type)
             values ($1,$2,$3,$4,'active',true,$5)`, [id, role, `TEST ${key}`, `${key}@test.invalid`, type]);
  return id;
}
async function mission(type, over = {}) {
  const r = await sql(`insert into public.missions(public_ref, type, status, from_city, to_city, vehicle, distance_km, mission_date, vehicle_category)
                       values ($1,$2,'published','Villepinte','Jonquera','TEST Buggy',905, now() + interval '6 days','standard') returning *`,
    [`MIS-TEST-${randomUUID().slice(0, 8)}`, type]);
  if (Object.keys(over).length) {
    await as(ids.admin, "select public.secoto_admin_update_mission($1,$2)", [r[0].id, JSON.stringify(over)]);
  }
  return r[0];
}
const proposer = (who, missionId, price, date, msg = null) =>
  as(ids[who], "select public.secoto_mission_proposer($1,$2,$3,$4) as r", [missionId, price, date, msg]).then((r) => r[0].r);
const inDays = (d) => new Date(Date.now() + d * 86400000).toISOString();

test.before(async () => {
  await sql("update public.secoto_feature_flags set enabled = true where key = 'direct_accept'");
  await account("admin", "admin");
  await account("pl", "transporter", "pl");
  await account("vl", "transporter", "vl");
  await account("conv", "transporter", "convoyeur");
});
test.after(() => pool.end());

test("plateau : une proposition (prix + date) par transporteur, modifiable tant qu'elle est en attente", async () => {
  const m = await mission("plateau");
  await assert.rejects(proposer("pl", m.id, null, inDays(7)), /Indiquez votre prix/);
  await assert.rejects(proposer("pl", m.id, 900, null), /date de disponibilité/);
  const a = await proposer("pl", m.id, 900, inDays(7), "Course cumulable");
  assert.equal(Number(a.proposed_price), 900);
  const b = await proposer("pl", m.id, 850, inDays(8));
  assert.equal(b.id, a.id, "même proposition, pas de doublon");
  assert.equal(Number(b.proposed_price), 850);
  const n = await sql("select count(*)::int n from public.mission_applications where mission_id=$1", [m.id]);
  assert.equal(n[0].n, 1);
  // Le transporteur relit sa propre proposition (prix et date).
  const mine = await as(ids.pl, "select proposed_price, proposed_date from public.mission_applications where mission_id=$1", [m.id]);
  assert.equal(Number(mine[0].proposed_price), 850);
  // Un convoyeur ne peut pas proposer sur un plateau.
  await assert.rejects(proposer("conv", m.id, 500, inDays(7)), /capacités de transport/);
  // Plus d'acceptation directe en plateau.
  await assert.rejects(as(ids.vl, "select public.secoto_mission_accept($1,$2)", [m.id, randomUUID()]), /proposez votre prix/);
  // SECOTO corrige la proposition, puis attribue : la mission prend la date proposée.
  const d = inDays(9);
  await as(ids.admin, "select public.secoto_admin_application_update($1,$2,$3)", [a.id, 800, d]);
  await as(ids.admin, "select public.secoto_assign_mission($1,$2,$3)", [m.id, a.id, randomUUID()]);
  const apres = (await sql("select status, carrier_cost, mission_date from public.missions where id=$1", [m.id]))[0];
  assert.equal(apres.status, "assigned");
  assert.equal(Number(apres.carrier_cost), 800);
  assert.equal(new Date(apres.mission_date).toISOString(), new Date(d).toISOString());
  // Traitée : ni le transporteur ni SECOTO ne modifient plus la proposition.
  await assert.rejects(proposer("pl", m.id, 700, inDays(7)), /déjà été attribuée/);
  await assert.rejects(as(ids.admin, "select public.secoto_admin_application_update($1,$2,$3)", [a.id, 700, null]), /déjà traitée/);
  // Un transporteur ne peut pas modifier la proposition d'un autre (aucune écriture directe).
  await assert.rejects(as(ids.vl, "update public.mission_applications set proposed_price = 1 where id=$1", [a.id]), /permission|denied/i);
});

test("convoyage : acceptation de la date, ou autre date sans toucher au prix", async () => {
  const m = await mission("convoyage");
  const avant = (await sql("select carrier_pay from public.missions where id=$1", [m.id]))[0].carrier_pay;
  const a = await proposer("conv", m.id, 1, inDays(10));
  assert.equal(Number(a.proposed_price), Number(avant), "le prix reste celui du barème");
  const m2 = await mission("convoyage");
  const r = await as(ids.conv, "select public.secoto_mission_accept($1,$2) as r", [m2.id, randomUUID()]);
  assert.equal(r[0].r.result, "assigned");
});

test("SECOTO modifie client et trajet après attribution ; le transporteur est prévenu ; urgent visible", async () => {
  const m = await mission("convoyage", { urgent: true });
  const vue = await as(ids.conv, "select urgent from public.secoto_public_missions_v2 where id=$1", [m.id]);
  assert.equal(vue[0].urgent, true);
  await as(ids.conv, "select public.secoto_mission_accept($1,$2)", [m.id, randomUUID()]);
  const r = await as(ids.admin, "select public.secoto_admin_update_mission($1,$2) as r", [m.id, JSON.stringify({
    pickup_address: "12 rue de Test 93420 Villepinte", client_phone: "+33 6 00 00 00 00", client_name: "TEST Client",
  })]);
  assert.deepEqual(r[0].r.changements, ["adresses", "client"]);
  const row = (await as(ids.conv, "select pickup_address, client_phone, urgent from public.secoto_missions_transporter_v2 where id=$1", [m.id]))[0];
  assert.equal(row.pickup_address, "12 rue de Test 93420 Villepinte");
  assert.equal(row.client_phone, "+33 6 00 00 00 00");
  assert.equal(row.urgent, true);
  const notif = await sql("select title, body from public.notifications where account_id=$1 and type='order_update' and mission_id=$2", [ids.conv, m.id]);
  assert.equal(notif.length, 1);
  assert.match(notif[0].body, /adresses, client/);
  // Contrôles : champs inconnus, villes vides, non-admin.
  await assert.rejects(as(ids.admin, "select public.secoto_admin_update_mission($1,$2)", [m.id, JSON.stringify({ carrier_pay: 1 })]), /non modifiable/);
  await assert.rejects(as(ids.admin, "select public.secoto_admin_update_mission($1,$2)", [m.id, JSON.stringify({ from_city: " " })]), /ne peut pas être vide/);
  await assert.rejects(as(ids.conv, "select public.secoto_admin_update_mission($1,$2)", [m.id, JSON.stringify({ urgent: false })]));
  // Champ vidé volontairement : effacé.
  await as(ids.admin, "select public.secoto_admin_update_mission($1,$2)", [m.id, JSON.stringify({ client_phone: "" })]);
  assert.equal((await sql("select client_phone from public.missions where id=$1", [m.id]))[0].client_phone, null);
});
