// Migration 122 — prestige : barème dédié, transport fermé au choix. Base JETABLE uniquement.
// Exécution : PGURL=postgres://... node --test tests/db/prestige-122.dbtest.mjs
import test from "node:test";
import assert from "node:assert/strict";
import pg from "pg";

const PGURL = process.env.PGURL;
if (!PGURL) throw new Error("PGURL requis (base de test jetable).");
const pool = new pg.Pool({ connectionString: PGURL, max: 3 });
const sql = async (t, p = []) => (await pool.query(t, p)).rows;
test.after(async () => { await pool.end(); });

const vehicule = (category, constraints = []) => ({ class: "voiture", model: "TEST Dino 308 GT4", category, rolling: true, constraints });
async function prix(v, km) {
  const [r] = await sql(
    "select secoto_private.market_price('{}'::jsonb, $1::jsonb, '{\"postcode\":\"75015\"}'::jsonb, $2::numeric, now() + interval '5 days', '{\"postcode\":\"78126\"}'::jsonb) as p",
    [JSON.stringify(v), km]);
  return { transporteur: r.p.partner_cents, client: r.p.client_cents };
}

test("122 : prestige ouvert × 1,5 (min 250 €), fermé × 2,1 (min 350 €), standard inchangé", async () => {
  assert.deepEqual(await prix(vehicule("standard"), 53), { transporteur: 9583, client: 11500 });
  assert.deepEqual(await prix(vehicule("luxury"), 53), { transporteur: 25000, client: 30000 });
  assert.deepEqual(await prix(vehicule("luxury", ["transport_ferme"]), 53), { transporteur: 35000, client: 42000 });
  assert.deepEqual(await prix(vehicule("luxury"), 300), { transporteur: 45000, client: 54000 });
  assert.deepEqual(await prix(vehicule("luxury", ["transport_ferme"]), 300), { transporteur: 63000, client: 75600 });
});

test("122 : la contrainte « transport fermé » ne déclenche rien hors prestige", async () => {
  const [r] = await sql("select secoto_private.transport_ferme_demande($1::jsonb) f, secoto_private.prix_prestige_cents($2::jsonb, 9583) p",
    [JSON.stringify(vehicule("luxury", ["transport_ferme"])), JSON.stringify(vehicule("standard", ["transport_ferme"]))]);
  assert.equal(r.f, true);
  assert.equal(r.p, 9583);
});
