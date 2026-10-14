// Tests d'intégration base de données — migration 091 (« batterie faible » tarifée tout de suite).
// Exécution : PGURL=postgres://... node --test tests/db/contraintes-sans-devis-091.dbtest.mjs
// Base JETABLE uniquement (données fictives « TEST »). Jamais sur la production.
import test from "node:test";
import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import pg from "pg";

const PGURL = process.env.PGURL;
if (!PGURL) throw new Error("PGURL requis (base de test jetable).");
const pool = new pg.Pool({ connectionString: PGURL, max: 3 });
const sql = async (t, p = []) => (await pool.query(t, p)).rows;

const inDays = (d) => new Date(Date.now() + d * 86400000).toISOString().slice(0, 10);
const devis = async ({ rolling = false, constraints = [], notes = "" } = {}) => (await sql(
  "select public.secoto_anon_quote_create($1,$2,$3) as r",
  [JSON.stringify({
    mode: "plateau",
    pickup: { label: "1 place Test 69002 Lyon", city: "Lyon", postcode: "69002", lat: 45.76, lng: 4.83 },
    delivery: { label: "TEST 27620 Gasny", city: "Gasny", postcode: "27620", lat: 49.09, lng: 1.6 },
    vehicle: { model: "TEST Lexus RX450h", class: "voiture", category: "standard", rolling, constraints, notes },
    schedule: { pickup_date: inDays(7), slot: "matin", flexibility_days: 0 },
  }), JSON.stringify({ distance_km: 460.7, duration_min: 300, provider: "test" }), `ip-${randomUUID()}`],
))[0].r.quote;

test.before(async () => { await sql("update public.secoto_feature_flags set enabled = true where key = 'auto_pricing'"); });
test.after(async () => { await pool.end(); });

test("091 : non roulant + batterie faible + message = prix immédiat, supplément non roulant compris", async () => {
  const base = await devis({ rolling: false, notes: "Ne démarre pas" });
  const batterie = await devis({ rolling: false, constraints: ["batterie_faible"], notes: "Ne démarre pas même avec booster" });
  assert.equal(base.status, "priced");
  assert.equal(batterie.status, "priced");
  assert.equal(batterie.manual_reason ?? null, null);
  assert.equal(batterie.client_price_cents, base.client_price_cents);
  const roulant = await devis({ rolling: true });
  assert.equal(base.client_price_cents - roulant.client_price_cents, 8000, "80 € de plus pour un non roulant");
});

test("091 : les autres contraintes restent en devis manuel", async () => {
  for (const c of ["sans_cle", "gabarit_hors_norme", "garde_au_sol_basse", "non_immatricule", "acces_difficile"]) {
    const q = await devis({ rolling: false, constraints: ["batterie_faible", c] });
    assert.equal(q.status, "manual_review", c);
    assert.equal(q.manual_reason, "contraintes_particulieres", c);
  }
});

test("091 : la liste se règle dans le barème (clé contraintes_sans_devis)", async () => {
  const p = { constraints: ["sans_cle"] };
  assert.deepEqual((await sql("select secoto_private.contraintes_sans_devis('{}'::jsonb) as r"))[0].r, ["batterie_faible"]);
  assert.deepEqual((await sql("select secoto_private.contraintes_sans_devis($1::jsonb) as r", [JSON.stringify({ contraintes_sans_devis: ["sans_cle"] })]))[0].r, ["sans_cle"]);
  assert.ok(p);
});
