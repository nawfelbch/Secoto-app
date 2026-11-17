import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { brevoSmsPayload } from "../netlify/lib/sms-brevo.js";

const lire = (p) => readFileSync(new URL(`../${p}`, import.meta.url), "utf8");
const sql = lire("supabase/migrations/202611170152_politique_sms_missions.sql");
const tick = sql.slice(sql.indexOf("create or replace function public.secoto_automatisation_tick()"), sql.indexOf("revoke all on function public.secoto_automatisation_tick()"));

test("152 : plus aucun SMS aux transporteurs — relance par e-mail, SMS en attente annulés", () => {
  assert.ok(tick.length > 1000);
  assert.match(tick, /queue_email\(t\.partner_id,/);
  assert.match(tick, /'od-relance-mail:'/);
  assert.doesNotMatch(tick, /queue_sms\(t\.partner_id/);
  assert.match(sql, /set status = 'skipped'[\s\S]*event_key like 'od-sms:%'/);
});

test("152 : un seul SMS client, 1 h après le prix, devis non réservé, jamais la nuit", () => {
  assert.ok(sql.includes("'sms_devis_apres_min', 60"));
  assert.match(tick, /not v_nuit and coalesce\(\(s ->> 'sms_devis_actif'\)::boolean, true\)/);
  assert.match(tick, /not exists \(select 1 from public\.transport_orders x where x\.quote_id = q\.id\)/);
  assert.match(tick, /'devis-sms:' \|\| q\.id::text/);               // un par devis
  assert.match(tick, /\?reprendre=%s/);
  assert.equal((tick.match(/queue_sms\(/g) || []).length, 1);
});

test("152 : invitation SMS des prospects — admin, marketing avec STOP, jamais un inscrit, une seule fois", () => {
  const f = sql.slice(sql.indexOf("secoto_admin_inviter_transporteur_sms(p_telephone"));
  assert.match(f, /assert_admin\(\)/);
  assert.match(f, /\[STOP CODE\]/);
  assert.match(f, /'marketing'\)/);
  assert.match(f, /déjà inscrit chez SECOTO/);
  assert.match(f, /'invite:' \|\| v_chiffres/);
});

test("152 : Brevo — type marketing pour les invitations, transactionnel sinon", () => {
  assert.equal(brevoSmsPayload({ to_phone: "+33600000000", body: "x", sms_type: "marketing" }).type, "marketing");
  assert.equal(brevoSmsPayload({ to_phone: "+33600000000", body: "x" }).type, "transactional");
});

test("152 : missions manuelles — liste à appeler dans « Publiées » + Google géocodé par adresse", () => {
  assert.match(lire("src/App.jsx"), /mission\.status === "published" && <TransporteursAAppeler mission=\{mission\} \/>/);
  const c = lire("src/ondemand/TransporteursAAppeler.jsx");
  assert.match(c, /transporteursAAppelerMission/);
  assert.match(c, /Inviter par SMS/);
  assert.match(lire("netlify/functions/places-transporteurs.js"), /geocodeFrenchAddress\(/);
  assert.match(sql, /alter table public\.mission_appels enable row level security/);
});
