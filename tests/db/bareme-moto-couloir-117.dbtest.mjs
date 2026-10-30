// Migration 117 — moto : plafond 382 € seulement entre l'Île-de-France et le Sud-Est. Base JETABLE uniquement.
// Exécution : PGURL=postgres://... node --test tests/db/bareme-moto-couloir-117.dbtest.mjs
import test from "node:test";
import assert from "node:assert/strict";
import pg from "pg";

const PGURL = process.env.PGURL;
if (!PGURL) throw new Error("PGURL requis (base de test jetable).");
const pool = new pg.Pool({ connectionString: PGURL, max: 3 });
const sql = async (t, p = []) => (await pool.query(t, p)).rows;
test.after(async () => { await pool.end(); });

const moto = { class: "moto", model: "TEST Fat Boy", category: "standard", rolling: true, constraints: [] };
const voiture = { ...moto, class: "voiture", model: "TEST Clio" };
const lieu = (postcode) => ({ postcode, city: "TEST" });
// Barème de départ (aucun transporteur éligible dans la base jetable) : prix transporteur, prix client.
async function prix(vehicule, de, vers, km) {
  const [r] = await sql(
    "select secoto_private.market_price('{}'::jsonb, $1::jsonb, $2::jsonb, $3::numeric, now() + interval '5 days', $4::jsonb) as p",
    [JSON.stringify(vehicule), JSON.stringify(lieu(de)), km, JSON.stringify(lieu(vers))]);
  return { transporteur: r.p.partner_cents, client: r.p.client_cents, plafond: r.p.detail?.[0]?.plafond };
}

test("117 : Paris ↔ 06 / 83 / 13 garde le plafond 382 €, dans les deux sens", async () => {
  for (const [de, vers] of [["75015", "06000"], ["83270", "92100"], ["13001", "77000"], ["91000", "83000"]]) {
    const p = await prix(moto, de, vers, 930);
    assert.equal(p.client, 38200, `${de} → ${vers}`);
    assert.equal(p.transporteur, 31833);
    assert.equal(p.plafond, true);
  }
});

test("117 : ailleurs, plus de plafond et prix dégressif au-delà de 400 km", async () => {
  // Chamblet → Saint-Cyr-sur-Mer, 606,3 km (121) : 400 × 1,10 + 206,3 × 0,88 = 621,54 € ; client × 1,2.
  const harley = await prix(moto, "03170", "83270", 606.3);
  assert.equal(harley.transporteur, 62154);
  assert.equal(harley.client, 74585);
  assert.equal(harley.plafond, false);
  // Moins de 400 km : tarif plein (121 : 1,10 €/km).
  const court = await prix(moto, "69001", "13001", 300);
  assert.equal(court.transporteur, 33000);
  // Ancienne signature (sans destination) : plafond partout, comme avant.
  const [r] = await sql("select secoto_private.market_price('{}'::jsonb, $1::jsonb, $2::jsonb, 606.3, now() + interval '5 days') as p",
    [JSON.stringify(moto), JSON.stringify(lieu("03170"))]);
  assert.equal(r.p.client_cents, 38200);
});

test("117 : les voitures ne changent pas", async () => {
  const p = await prix(voiture, "03170", "83270", 606.3);
  assert.equal(p.transporteur, 60630);
  assert.equal(p.plafond, true); // aucun couloir défini pour la voiture : règle d'avant (pas de plafond voiture)
});
