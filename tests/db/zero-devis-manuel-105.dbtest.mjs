// Migration 105 — plus aucun devis manuel, marge minimale toujours garantie.
// Base JETABLE uniquement. PGURL=postgres://... node --test tests/db/zero-devis-manuel-105.dbtest.mjs
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
const FR_A = { label: "1 rue Test 06130 Grasse", city: "Grasse", postcode: "06130", lat: 43.66, lng: 6.92 };
const FR_B = { label: "1 rue Test 69002 Lyon", city: "Lyon", postcode: "69002", lat: 45.76, lng: 4.83 };
const MAROC = { label: "Mohammédia, Maroc", city: "Mohammédia", country: "MA", lat: 33.69, lng: -7.38 };
const payload = (over = {}) => ({
  mode: "plateau", pickup: FR_A, delivery: FR_B,
  vehicle: { model: "TEST", class: "voiture", category: "standard", rolling: true, constraints: [] },
  schedule: { pickup_date: inDays(6), slot: "matin", flexibility_days: 0 }, ...over,
});
let client;
let dernierExclu = [];
const prestigeExclu = () => dernierExclu;
async function devis(over, route = { distance_km: 470, duration_min: 300, provider: "test" }) {
  return (await service("select public.secoto_quote_create($1,$2,$3) as q", [client, JSON.stringify(payload(over)), route ? JSON.stringify(route) : null]))[0].q;
}
async function rentable(q) {
  assert.equal(q.manual_reason ?? null, null, `encore manuel : ${q.manual_reason}`);
  const [row] = await sql("select client_price_cents c, partner_pay_cents p, status from public.transport_quotes where id=$1", [q.id]);
  assert.equal(row.status, "priced");
  assert.ok(row.c > 0 && row.p > 0, JSON.stringify(row));
  assert.ok(row.c - row.p >= Math.floor(row.c * 0.10) - 1, `marge ≥ 10 % (${JSON.stringify(row)})`);
}

test.before(async () => {
  await sql("update public.secoto_feature_flags set enabled = true where key in ('auto_pricing','adresses_internationales')");
  client = randomUUID();
  await sql("insert into public.accounts(id, role, full_name, email, status, is_verified) values ($1,'client','TEST c','c105@test.invalid','active',true)", [client]);
});

test("contraintes, prestige, catégorie « autre » : prix immédiat avec supplément affiché", async () => {
  const base = await devis({});
  await rentable(base);
  const contrainte = await devis({ vehicle: { model: "TEST", class: "voiture", category: "standard", rolling: true, constraints: ["sans_cle", "acces_difficile"] } });
  await rentable(contrainte);
  assert.equal(contrainte.client_price_cents - base.client_price_cents, 12000, "2 contraintes × 60 €");
  const prestige = await devis({ vehicle: { model: "TEST Porsche", class: "voiture", category: "luxury", rolling: true, constraints: [] } });
  await rentable(prestige);
  assert.ok(prestige.client_price_cents > base.client_price_cents * 1.29);
  const autre = await devis({ vehicle: { model: "TEST quad", class: "autre", category: "standard", rolling: true, constraints: [] } });
  await rentable(autre);
});

test("itinéraire introuvable : distance estimée et signalée ; hors zone (Maroc) : + 30 %", async () => {
  const estime = await devis({}, null);
  await rentable(estime);
  assert.ok(estime.distance_km > 0);
  assert.ok(estime.lines.some((l) => /Distance estimée/.test(l.label)));
  const maroc = await devis({ delivery: MAROC }, null);
  dernierExclu = maroc.excluded || [];
  await rentable(maroc);
  assert.ok(maroc.lines.some((l) => /hors zone/.test(l.label)));
  assert.ok(!JSON.stringify(prestigeExclu()).includes("prestige"), "plus de « prestige : devis personnalisé »");
});

test("délai court et marge trop faible : supplément / prix relevé, jamais manuel", async () => {
  const [{ g }] = await sql("select params as g from public.pricing_grids where mode='plateau' and status='active'");
  const court = (await sql("select secoto_private.price_with_grid('plateau', $1, 300, $2, 2) as r",
    [g, JSON.stringify({ class: "voiture", category: "standard", rolling: true, constraints: [] })]))[0].r;
  assert.equal(court.manual_reason, undefined);
  assert.ok(court.lines.some((l) => /Délai court/.test(l.label)));
  const serre = { ...g, class_rates: { ...g.class_rates, voiture: { client_eur_per_km: 1, partner_eur_per_km: 0.98 } } };
  const r = (await sql("select secoto_private.price_with_grid('plateau', $1, 300, $2, 200) as r",
    [serre, JSON.stringify({ class: "voiture", category: "standard", rolling: true, constraints: [] })]))[0].r;
  assert.equal(r.manual_reason, undefined);
  assert.ok(r.margin_cents >= Math.floor(r.client_cents * 0.10) - 1, JSON.stringify(r));
});

test("convoyage sans clé : refusé à la saisie (plateau proposé) ; Corse : traversée facturée", async () => {
  await assert.rejects(devis({ mode: "convoyage", vehicle: { model: "TEST", class: "moto", category: "standard", rolling: true, constraints: ["sans_cle"] } }),
    /choisissez le transport sur plateau/);
  const corse = await devis({ pickup: { label: "Quai Test 20169 Bonifacio", city: "Bonifacio", postcode: "20169", lat: 41.39, lng: 9.16 } });
  await rentable(corse);
  assert.ok(corse.lines.some((l) => /Traversée maritime Corse/.test(l.label)));
});
