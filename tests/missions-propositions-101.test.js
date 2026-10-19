// SECOTO 101 — URGENT, modifications SECOTO, propositions plateau / convoyage.
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { missionFromDb, publicMissionFromDb, applicationFromDb } from "../src/lib/mappers.js";

const lire = (f) => readFileSync(new URL(`../${f}`, import.meta.url), "utf8");

test("mappers : urgent et date proposée", () => {
  assert.equal(missionFromDb({ id: "m", urgent: true }).urgent, true);
  assert.equal(missionFromDb({ id: "m" }).urgent, false);
  assert.equal(publicMissionFromDb({ id: "m", urgent: true }).urgent, true);
  assert.equal(applicationFromDb({ id: "a", proposed_date: "2026-10-25T18:30:00Z" }).proposedDate, "2026-10-25T18:30:00Z");
});

test("modification : seules les valeurs changées partent, champ vidé = effacé", async () => {
  const { patchMission } = await import("../src/lib/missionPatch.js");
  const mission = { fromCity: "Villepinte", toCity: "Jonquera", clientPhone: "+33 6 14 10 61 27", notes: "x", urgent: false, missionDate: null };
  const form = { fromCity: "Villepinte", toCity: "Jonquera", pickupAddress: "12 rue Test", clientPhone: "", notes: "x", urgent: true };
  assert.deepEqual(patchMission(mission, form), { pickup_address: "12 rue Test", client_phone: "", urgent: true });
});

test("écrans : URGENT partout, plateau = prix + date, convoyage = accepter ou autre date", () => {
  const app = lire("src/App.jsx");
  assert.equal((app.match(/<UrgentBadge mission=\{mission\} \/>/g) || []).length, 2);
  assert.match(app, /<PropositionTransporteur/);
  assert.match(app, /<MissionEditPanel/);
  assert.match(app, /<PropositionAdmin/);
  assert.match(app, /"urgent",\n\]\.join/);
  assert.match(app, /"proposed_date",\n\]\.join/);
  const ui = lire("src/MissionPropositions.jsx");
  assert.match(ui, /Un seul prix et une seule date par mission/);
  assert.match(ui, /Proposer une autre date/);
  assert.match(ui, /Accepter le \$\{formatDateTime\(mission\.missionDate\)\}/);
  const sql = lire("supabase/migrations/202610190101_missions_urgent_propositions.sql");
  assert.doesNotMatch(sql, /\b(drop table|drop column|alter column|truncate|delete from)\b/i);
  assert.match(sql, /Transport par plateau : proposez votre prix/);
});
