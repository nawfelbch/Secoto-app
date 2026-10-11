// Tests d'intégration base de données — migration 089 (adresses hors de France).
// Exécution : PGURL=postgres://... node --test tests/db/adresses-europe-089.dbtest.mjs
// Base JETABLE uniquement (données fictives « TEST »). Jamais sur la production.
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
async function service(text, params = []) {
  const c = await pool.connect();
  try {
    await c.query("begin");
    await c.query("set local role service_role");
    const rows = (await c.query(text, params)).rows;
    await c.query("commit");
    return rows;
  } catch (error) {
    await c.query("rollback").catch(() => {});
    throw error;
  } finally { c.release(); }
}

let client;
const inDays = (d) => new Date(Date.now() + d * 86400000).toISOString().slice(0, 10);
const FR_A = { label: "1 rue de Test 92260 Fontenay-aux-Roses", city: "Fontenay-aux-Roses", postcode: "92260", lat: 48.79, lng: 2.29 };
const FR_B = { label: "1 place Test 69002 Lyon", city: "Lyon", postcode: "69002", lat: 45.76, lng: 4.83 };
const DE = { label: "Teststraße 1, 10115 Berlin, Allemagne", city: "Berlin", postcode: "10115", country: "DE", lat: 52.53, lng: 13.38 };
const CH = { label: "Teststrasse 1, 8001 Zürich, Suisse", city: "Zürich", postcode: "8001", country: "CH", lat: 47.37, lng: 8.54 };
const IE_SANS_CP = { label: "Main Street, Galway, Irlande", city: "Galway", country: "ie", lat: 53.27, lng: -9.05 };

const payload = (pickup, delivery) => ({
  mode: "plateau", pickup, delivery,
  vehicle: { model: "TEST Peugeot 308", class: "voiture", category: "standard", rolling: true, constraints: [] },
  schedule: { pickup_date: inDays(6), slot: "matin", flexibility_days: 0 },
});
const ROUTE = { distance_km: 1050, duration_min: 640, provider: "test" };
const devis = async (pickup, delivery, route = ROUTE) =>
  (await service("select public.secoto_quote_create($1,$2,$3) as q", [client, JSON.stringify(payload(pickup, delivery)), route ? JSON.stringify(route) : null]))[0].q;
const flag = (on) => sql("update public.secoto_feature_flags set enabled = $1 where key = 'adresses_internationales'", [on]);

test.before(async () => {
  await sql("update public.secoto_feature_flags set enabled = true where key = 'auto_pricing'");
  client = randomUUID();
  await sql(`insert into public.accounts(id, role, full_name, email, status, is_verified, client_type)
             values ($1,'client','TEST client 089',$2,'active',true,'pro')`, [client, `c089-${client.slice(0, 6)}@test.invalid`]);
  const admin = randomUUID();
  await sql(`insert into public.accounts(id, role, full_name, email, status, is_verified)
             values ($1,'admin','TEST admin 089',$2,'active',true)`, [admin, `a089-${admin.slice(0, 6)}@test.invalid`]);
  await flag(true);
});
test.after(async () => { await flag(true); await pool.end(); });

test("089 : un devis en France ne change pas", async () => {
  const q = await devis(FR_A, FR_B, { distance_km: 465, duration_min: 280, provider: "test" });
  assert.equal(q.status, "priced");
  assert.equal(q.manual_reason, null);
  await assert.rejects(devis({ ...FR_A, postcode: "9226" }, FR_B), /code postal manquant/);
});

test("089 : Allemagne → France, prix immédiat avec le même barème", async () => {
  const q = await devis(DE, FR_A);
  assert.equal(q.status, "priced", JSON.stringify(q));
  assert.ok(q.client_price_cents > 0);
  const stocke = (await sql("select pickup from public.transport_quotes where id=$1", [q.id]))[0].pickup;
  assert.equal(stocke.country, "DE");
  // Même distance en France : même prix (le barème ne dépend pas du pays).
  const fr = await devis(FR_A, FR_B);
  assert.equal(q.client_price_cents, fr.client_price_cents);
});

test("089 : Suisse ou pays sans prix immédiat → devis établi par SECOTO, jamais de blocage", async () => {
  const q = await devis(CH, FR_A);
  assert.equal(q.status, "manual_review");
  assert.equal(q.manual_reason, "international_hors_zone");
  // Code postal absent à l'étranger : accepté, pays en minuscules accepté.
  const ie = await devis(IE_SANS_CP, FR_A);
  assert.equal(ie.status, "manual_review");
  // Traversée en bateau (pas d'itinéraire par la route) : devis établi par SECOTO.
  const sansRoute = await devis(DE, FR_A, null);
  assert.equal(sansRoute.status, "manual_review");
  assert.equal(sansRoute.manual_reason, "itineraire_indisponible");
  // Les demandes à établir arrivent bien chez l'administrateur.
  const notif = await sql("select count(*)::int n from public.notifications where event_key like $1", [`%quote-manual:${q.id}%`]);
  assert.ok(notif[0].n > 0, "notification « devis à établir » créée");
});

test("089 : adresses étrangères mal formées refusées", async () => {
  await assert.rejects(devis({ ...DE, country: "DEU" }, FR_A), /code postal manquant/);
  await assert.rejects(devis({ ...DE, postcode: "<script>" }, FR_A), /code postal manquant/);
  await assert.rejects(devis({ ...DE, lat: null }, FR_A), /non vérifiée/);
});

test("089 : interrupteur éteint → hors de France refusé comme avant, France intacte", async () => {
  await flag(false);
  try {
    await assert.rejects(devis(DE, FR_A), /hors de France/);
    assert.equal((await devis(FR_A, FR_B)).status, "priced");
  } finally {
    await flag(true);
  }
});

test("089 : devis sans compte (visiteur) depuis l'étranger", async () => {
  // (base locale : droits Supabase par défaut absents, appel en propriétaire)
  const r = (await sql("select public.secoto_anon_quote_create($1,$2,$3) as r",
    [JSON.stringify(payload(DE, FR_B)), JSON.stringify(ROUTE), `ip-${randomUUID()}`]))[0].r;
  assert.ok(r.token);
  assert.equal(r.quote.status, "priced");
});
