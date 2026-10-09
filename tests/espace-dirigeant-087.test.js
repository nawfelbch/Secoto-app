import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import {
  decaler, euros, eurosEntiers, periodeADeclarer, periodeEnCours, periodeMois, periodeTrimestre, totauxAnnee,
} from "../src/lib/dirigeantUtil.js";

const lire = (f) => readFileSync(new URL(`../${f}`, import.meta.url), "utf8");
const sp = (s) => s.replace(/[\u202f\u00a0]/g, " ");

test("périodes URSSAF : mois et trimestres, début inclus et fin exclue", () => {
  assert.deepEqual([periodeMois(2026, 9).debut, periodeMois(2026, 9).fin], ["2026-09-01", "2026-10-01"]);
  assert.deepEqual([periodeMois(2026, 12).debut, periodeMois(2026, 12).fin], ["2026-12-01", "2027-01-01"]);
  assert.equal(periodeMois(2026, 10).label, "Octobre 2026");
  const t3 = periodeTrimestre(2026, 3);
  assert.deepEqual([t3.debut, t3.fin, t3.label, t3.detail], ["2026-07-01", "2026-10-01", "3e trimestre 2026", "juillet à septembre"]);
  assert.deepEqual([periodeTrimestre(2026, 4).fin, periodeTrimestre(2026, 1).label], ["2027-01-01", "1er trimestre 2026"]);
});

test("période à déclarer = la dernière période terminée", () => {
  const oct = new Date(2026, 9, 9);
  assert.equal(periodeADeclarer("mois", oct).debut, "2026-09-01");
  assert.equal(periodeADeclarer("trimestre", oct).debut, "2026-07-01");
  const janvier = new Date(2027, 0, 15);
  assert.equal(periodeADeclarer("mois", janvier).debut, "2026-12-01");
  assert.equal(periodeADeclarer("trimestre", janvier).debut, "2026-10-01");
  assert.equal(periodeEnCours(periodeMois(2026, 9), oct), false);
  assert.equal(periodeEnCours(periodeMois(2026, 10), oct), true);
});

test("navigation entre périodes, y compris au changement d'année", () => {
  assert.equal(decaler(periodeMois(2026, 1), -1).debut, "2025-12-01");
  assert.equal(decaler(periodeMois(2026, 12), 1).debut, "2027-01-01");
  assert.equal(decaler(periodeTrimestre(2026, 1), -1).debut, "2025-10-01");
  assert.equal(decaler(periodeTrimestre(2026, 4), 1).debut, "2027-01-01");
});

test("montants : deux décimales pour le détail, euros entiers pour la déclaration", () => {
  assert.equal(sp(euros(123456)), "1 234,56 €");
  assert.equal(sp(euros(-500)), "-5,00 €");
  assert.equal(euros("x"), "—");
  assert.equal(sp(eurosEntiers(1235)), "1 235 €");
  const t = totauxAnnee([
    { encaisse_cents: 48000, reverse_cents: 40000, rembourse_cents: 0, commission_cents: 8000, operations: 1 },
    { encaisse_cents: "1000", reverse_cents: 0, rembourse_cents: 1000, commission_cents: 0, operations: 1 },
  ]);
  assert.deepEqual(t, { encaisse: 49000, reverse: 40000, rembourse: 1000, commission: 8000, operations: 2 });
});

test("l'onglet n'apparaît que si la base confirme l'accès", () => {
  const app = lire("src/App.jsx");
  assert.match(app, /espaceDirigeant \? \[\{ title: "Dirigeant"/);
  assert.match(app, /adminTab === "dirigeant" && espaceDirigeant/);
  const lib = lire("src/lib/dirigeant.js");
  assert.match(lib, /error \? false : data === true/);
});

test("migration 087 : additive, accès nominatif, lecture seule", () => {
  const m = lire("supabase/migrations/202610090087_espace_dirigeant.sql");
  assert.doesNotMatch(m, /\b(drop table|drop column|alter column|drop policy|truncate)\b/i);
  assert.doesNotMatch(m, /\b(update|delete from|insert into) public\./i);
  assert.match(m, /a\.role = 'admin'/);
  for (const f of ["secoto_dirigeant_tableau", "secoto_dirigeant_urssaf", "secoto_dirigeant_litiges"]) {
    const corps = m.split(`function public.${f}`)[1].split("$f$;")[0];
    assert.match(corps, /perform secoto_private\.assert_dirigeant\(\)/, f);
  }
});
