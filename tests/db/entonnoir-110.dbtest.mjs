// Migration 110 — comptage anonyme des étapes. Base JETABLE uniquement.
import test from "node:test";
import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import pg from "pg";

const pool = new pg.Pool({ connectionString: process.env.PGURL, max: 4 });
async function as(userId, text, params = [], role = "authenticated") {
  const c = await pool.connect();
  try {
    await c.query("begin");
    await c.query("select set_config('request.jwt.claim.sub', $1, true)", [userId || ""]);
    await c.query(`set local role ${role}`);
    const rows = (await c.query(text, params)).rows;
    await c.query("commit");
    return rows;
  } catch (e) { await c.query("rollback").catch(() => {}); throw e; } finally { c.release(); }
}
const sql = (t, p) => pool.query(t, p).then((r) => r.rows);
test.after(() => pool.end());

test("un visiteur anonyme compte ses étapes une fois ; l'admin lit l'entonnoir ; la table reste fermée", async () => {
  const v1 = randomUUID(); const v2 = randomUUID();
  const etape = (v, e, s = "ads") => as(null, "select public.secoto_etape_formulaire($1,$2,$3,true,false)", [v, e, s], "anon");
  for (const e of ["arrivee", "trajet", "vehicule", "mode", "dates", "contact", "prix"]) await etape(v1, e);
  await etape(v1, "arrivee"); // doublon ignoré
  for (const e of ["arrivee", "trajet"]) await etape(v2, e);
  await etape(v2, "pirate"); // étape inconnue ignorée
  await etape(v2, "adresse_saisie"); await etape(v2, "adresse_choisie"); // 113
  await etape(randomUUID(), "arrivee", "nimporte");
  assert.equal((await sql("select count(*)::int n from public.entonnoir_etapes where visite=$1", [v1]))[0].n, 7);
  assert.equal((await sql("select count(*)::int n from public.entonnoir_etapes where etape='pirate'"))[0].n, 0);
  assert.equal((await sql("select count(*)::int n from public.entonnoir_etapes where source='autre'"))[0].n, 1);
  await assert.rejects(as(null, "select * from public.entonnoir_etapes", [], "anon"), /permission denied/);

  const admin = randomUUID();
  await sql("insert into public.accounts(id, role, full_name, email, status, is_verified) values ($1,'admin','TEST admin','adm110@test.invalid','active',true)", [admin]);
  const r = (await as(admin, "select public.secoto_admin_entonnoir(7) as r"))[0].r;
  const ads = r.find((x) => x.source === "ads");
  assert.equal(ads.etapes.arrivee, 2);
  assert.equal(ads.etapes.trajet, 2);
  assert.equal(ads.etapes.prix, 1);
  assert.equal(ads.etapes.adresse_saisie, 1);
  assert.equal(ads.etapes.adresse_choisie, 1);
  await assert.rejects(as(null, "select public.secoto_admin_entonnoir(7)", [], "anon"), /./);
});
