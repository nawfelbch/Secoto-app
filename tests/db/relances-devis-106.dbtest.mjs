// Migration 106 — relances e-mail des devis non réservés. Base JETABLE uniquement.
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
const inDays = (d) => new Date(Date.now() + d * 86400000).toISOString().slice(0, 10);
const payload = {
  mode: "plateau",
  pickup: { label: "1 rue Test 17300 Rochefort", city: "Rochefort", postcode: "17300", lat: 45.94, lng: -0.96 },
  delivery: { label: "1 rue Test 91480 Quincy", city: "Quincy-sous-Sénart", postcode: "91480", lat: 48.67, lng: 2.53 },
  vehicle: { model: "TEST Clio", class: "voiture", category: "standard", rolling: true, constraints: [] },
  schedule: { pickup_date: inDays(9), slot: "matin", flexibility_days: 0 },
};
const relancer = () => service("select public.secoto_devis_relances(50) as r").then((r) => r[0].r);
const mails = (id) => sql("select subject, body_text, event_key from public.email_outbox where event_key like $1 order by created_at", [`relance-devis:${id}:%`]);

test("trois rappels au plus, un seul par étape, lien de reprise, devis expiré réactivé, interrupteur", async () => {
  await sql("update public.secoto_feature_flags set enabled = true where key = 'auto_pricing'");
  const q = (await sql("select public.secoto_anon_quote_create($1,$2,$3) as q",
    [JSON.stringify(payload), JSON.stringify({ distance_km: 470, duration_min: 300, provider: "test" }), "a".repeat(64)]))[0].q;
  const id = q.quote?.id || q.id;
  await sql("update public.transport_quotes set contact_email='client106@test.invalid', created_at = now() - interval '3 hours' where id=$1", [id]);
  await relancer();
  let m = await mails(id);
  assert.equal(m.length, 1);
  assert.match(m[0].subject, /Votre prix SECOTO/);
  assert.match(m[0].body_text, /0 € aujourd'hui/);
  assert.match(m[0].body_text, /Klarna \(par exemple 3 × /);
  assert.match(m[0].body_text, /https:\/\/app\.secoto-transport\.fr\/\?reprendre=[0-9a-f]{64}/);
  await relancer();
  assert.equal((await mails(id)).length, 1, "pas de doublon");
  // Devis expiré depuis longtemps : un seul rappel, le dernier, et prix réactivé.
  await sql("update public.transport_quotes set status='expired', valid_until=now()-interval '2 days', created_at=now()-interval '4 days' where id=$1", [id]);
  await relancer();
  m = await mails(id);
  assert.equal(m.length, 2);
  assert.match(m[1].subject, /Dernier rappel/);
  const [row] = await sql("select status, valid_until > now() as valide from public.transport_quotes where id=$1", [id]);
  assert.equal(row.status, "priced");
  assert.equal(row.valide, true);
  await relancer();
  assert.equal((await mails(id)).length, 2, "rien après le dernier rappel");
  // Interrupteur éteint : rien.
  await sql("update public.app_settings set value = value || '{\"actif\": false}' where key='relances_devis'");
  assert.equal((await relancer()).actif, false);
  await sql("update public.app_settings set value = value || '{\"actif\": true}' where key='relances_devis'");
});
