// Migration 108 — l'admin reçoit tout, et chaque notification ouvre le bon onglet.
// Base JETABLE uniquement. PGURL=postgres://... node --test tests/db/notifications-admin-108.dbtest.mjs
import test from "node:test";
import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import pg from "pg";

const pool = new pg.Pool({ connectionString: process.env.PGURL, max: 4 });
const sql = (t, p) => pool.query(t, p).then((r) => r.rows);
async function service(text, params = []) {
  const c = await pool.connect();
  try {
    await c.query("begin"); await c.query("set local role service_role");
    const rows = (await c.query(text, params)).rows; await c.query("commit"); return rows;
  } catch (e) { await c.query("rollback").catch(() => {}); throw e; } finally { c.release(); }
}
test.after(() => pool.end());

test("client inscrit au bouton de paiement -> « Nouvelle demande » détaillée vers « À la demande » ; sans compte : notification classique, même onglet", async () => {
  await sql("update public.secoto_feature_flags set enabled = true where key = 'auto_pricing'");
  const admin = randomUUID(); const client = randomUUID();
  await sql(`insert into public.accounts(id, role, full_name, email, phone, status, is_verified) values
    ($1,'admin','TEST admin','adm108@test.invalid',null,'active',true),
    ($2,'client','TEST Mourad','cl108@test.invalid','+33600000108','active',true)`, [admin, client]);
  // L'admin avait coupé missions et documents : 108 rétablit tout (rejouée ici sur ce nouveau compte).
  await sql("insert into public.notification_preferences(account_id, push_enabled, mute_missions, mute_documents) values ($1, true, true, true)", [admin]);
  await sql(`update public.notification_preferences set push_enabled = true, mute_missions = false, mute_documents = false, mute_frais = false
              where account_id in (select id from public.accounts where role::text = 'admin')`);

  const payload = {
    mode: "plateau",
    pickup: { label: "1 rue Test 74100 Annemasse", city: "Annemasse", postcode: "74100", lat: 46.19, lng: 6.24 },
    delivery: { label: "1 rue Test 75011 Paris", city: "Paris", postcode: "75011", lat: 48.86, lng: 2.38 },
    vehicle: { model: "TEST Combo", class: "utilitaire", category: "standard", rolling: false, constraints: [] },
    schedule: { pickup_date: new Date(Date.now() + 6 * 86400000).toISOString().slice(0, 10), slot: "matin", flexibility_days: 0 },
  };
  const q = (await service("select public.secoto_quote_create($1,$2,$3) as q",
    [client, JSON.stringify(payload), JSON.stringify({ distance_km: 540, duration_min: 480, provider: "test" })]))[0].q;
  const [n] = await sql("select title, body, push_screen, type from public.notifications where account_id=$1 and event_key=$2",
    [admin, `admin-demande:${q.id}:${admin}`]);
  assert.ok(n, "notification « Nouvelle demande » créée");
  assert.equal(n.title, "Nouvelle demande · client inscrit");
  assert.equal(n.push_screen, "offre", "ouvre « À la demande », pas l'ancien onglet « Demandes »");
  for (const morceau of ["Annemasse (74) → Paris (75)", "plateau", "TEST Combo (NON ROULANT)", "€", "TEST Mourad", "+33600000108"]) {
    assert.ok(n.body.includes(morceau), `${morceau} dans « ${n.body} »`);
  }
  const [outbox] = await sql("select count(*)::int n from public.push_outbox o join public.notifications x on x.id = o.notification_id where x.account_id=$1 and x.event_key=$2",
    [admin, `admin-demande:${q.id}:${admin}`]);
  assert.equal(outbox.n, 1, "part en push");
  // Même devis mis à jour : pas de doublon.
  await sql("update public.transport_quotes set client_price_cents = client_price_cents + 100 where id=$1", [q.id]);
  assert.equal((await sql("select count(*)::int n from public.notifications where event_key like $1", [`admin-demande:${q.id}:%`]))[0].n,
    (await sql("select count(*)::int n from public.accounts where role::text='admin' and deleted_at is null"))[0].n);

  // Ancienne notification de devis (onglet « requests ») : redirigée pour l'admin, intacte pour un transporteur.
  await sql("select secoto_private.notify_admins_event('new_request','Nouveau contact devis','X → Y','requests','test108-contact',null)");
  assert.equal((await sql("select push_screen from public.notifications where event_key=$1", [`test108-contact:${admin}`]))[0].push_screen, "offre");
  // Une notification liée à une mission garde son onglet.
  const [m] = await sql("select id from public.missions limit 1");
  if (m) {
    await sql("insert into public.notifications(account_id, type, title, body, mission_id, push_screen, event_key) values ($1,'course_assigned','t','b',$2,'courses','test108-mission')", [admin, m.id]);
    assert.equal((await sql("select push_screen from public.notifications where event_key='test108-mission'"))[0].push_screen, "courses");
  }
});
