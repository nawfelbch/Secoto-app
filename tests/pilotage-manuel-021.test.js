// Migration 021 — pilotage manuel des missions (tarif transporteur + marge
// SECOTO fixés à la main) et message client prêt à envoyer.
import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

import {
  computeCarrierPay,
  computeClientPrice,
  computeClientTotalDue,
  computeCommission,
  computeMargin,
  computeTransportAmount,
  isManualPricing,
  suggestedMargin,
} from "../src/lib/pricing.js";
import {
  buildClientAssignmentMessage,
  buildShortAssignmentMessage,
  buildSmsUrl,
  displayPhone,
  normalizePhone,
} from "../src/lib/missionMessage.js";
import { emptyMissionForm, MISSION_STAGES, missionFromDb } from "../src/lib/mappers.js";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const migration = fs.readFileSync(
  path.join(root, "supabase/migrations/202608290021_pilotage_manuel_missions.sql"),
  "utf8",
);

/* ------------------------------------------------------------------ */
/* Non-régression : sans pilotage manuel, rien ne change               */
/* ------------------------------------------------------------------ */
test("sans pilotage manuel, le barème historique est intact", () => {
  const convoyage = { type: "convoyage", distanceKm: 400 };
  assert.equal(computeClientPrice(convoyage), 390);
  assert.equal(computeCarrierPay(convoyage), 220);
  assert.equal(computeMargin(convoyage), 170);

  const plateau = { type: "plateau", carrierCost: 300 };
  assert.equal(computeClientPrice(plateau), 60);
  assert.equal(computeCommission(plateau), 60);
  assert.equal(computeTransportAmount(plateau), 300);
  assert.equal(computeClientTotalDue(plateau), 360);

  assert.equal(isManualPricing(convoyage), false);
  assert.equal(isManualPricing({ ...plateau, manualPricing: false }), false);
});

/* ------------------------------------------------------------------ */
/* Plateau piloté à la main                                            */
/* ------------------------------------------------------------------ */
test("plateau : la marge SECOTO n'est plus forcément 20 %", () => {
  const m = {
    type: "plateau",
    carrierCost: 300,
    manualPricing: true,
    manualCarrierPay: 450,
    manualMargin: 90,
  };
  assert.equal(isManualPricing(m), true);
  assert.equal(computeCarrierPay(m), 450, "le transporteur touche le montant imposé");
  assert.equal(computeMargin(m), 90, "la marge est celle saisie, pas 20 %");
  assert.equal(computeCommission(m), 90);
  assert.equal(computeClientPrice(m), 90, "SECOTO n'encaisse que sa marge en plateau");
  assert.equal(computeTransportAmount(m), 450, "le transport reste réglé en direct");
  assert.equal(computeClientTotalDue(m), 540);

  // 20 % de 450 donnerait 90 par hasard : on vérifie avec une marge atypique.
  const atypique = { ...m, manualMargin: 35 };
  assert.equal(computeMargin(atypique), 35);
  assert.equal(computeClientTotalDue(atypique), 485);
});

/* ------------------------------------------------------------------ */
/* Convoyage piloté à la main                                          */
/* ------------------------------------------------------------------ */
test("convoyage : SECOTO encaisse la totalité, tarif et marge imposés", () => {
  const m = {
    type: "convoyage",
    distanceKm: 400,
    manualPricing: true,
    manualCarrierPay: 260,
    manualMargin: 140,
  };
  assert.equal(computeCarrierPay(m), 260, "et non 0,55 €/km");
  assert.equal(computeMargin(m), 140);
  assert.equal(computeClientPrice(m), 400, "tarif + marge");
  assert.equal(computeTransportAmount(m), 0, "aucun règlement en direct en convoyage");
  assert.equal(computeClientTotalDue(m), 400);
  assert.equal(computeCommission(m), 0);
});

test("des montants manuels absents ou négatifs valent zéro, jamais NaN", () => {
  const m = { type: "plateau", manualPricing: true };
  assert.equal(computeCarrierPay(m), 0);
  assert.equal(computeMargin(m), 0);
  assert.equal(computeClientTotalDue(m), 0);

  const negatif = { type: "plateau", manualPricing: true, manualCarrierPay: -50, manualMargin: -10 };
  assert.equal(computeCarrierPay(negatif), 0);
  assert.equal(computeMargin(negatif), 0);
});

test("la marge suggérée reste 20 % du tarif transporteur", () => {
  assert.equal(suggestedMargin(450), 90);
  assert.equal(suggestedMargin(0), 0);
  assert.equal(suggestedMargin("300"), 60);
  assert.equal(suggestedMargin(null), 0);
  assert.equal(suggestedMargin("abc"), 0);
});

/* ------------------------------------------------------------------ */
/* Mappers                                                             */
/* ------------------------------------------------------------------ */
test("missionFromDb reprend les colonnes de pilotage sans casser l'existant", () => {
  const mission = missionFromDb({
    id: "m1", public_ref: "MIS-1", type: "plateau", status: "assigned",
    carrier_cost: 450, manual_pricing: true, manual_carrier_pay: 450,
    manual_margin: 90, offline_signed: true, commission_settled_offline: true,
  });
  assert.equal(mission.manualPricing, true);
  assert.equal(mission.manualCarrierPay, 450);
  assert.equal(mission.manualMargin, 90);
  assert.equal(mission.offlineSigned, true);
  assert.equal(mission.commissionSettledOffline, true);

  // Une mission lue avant la migration 021 reste au barème.
  const ancienne = missionFromDb({ id: "m2", public_ref: "MIS-2", type: "plateau", carrier_cost: 300 });
  assert.equal(ancienne.manualPricing, false);
  assert.equal(ancienne.manualCarrierPay, null);
  assert.equal(computeClientTotalDue(ancienne), 360);
});

test("le formulaire de création porte les champs de la mission téléphonique", () => {
  assert.equal(emptyMissionForm.manualPricing, false);
  assert.equal(emptyMissionForm.manualCarrierPay, "");
  assert.equal(emptyMissionForm.manualMargin, "");
  assert.equal(emptyMissionForm.assignedTransporterId, "");
});

test("les étapes proposées sont toutes acceptées par la base", () => {
  const statuts = new Set(["published", "assigned", "completed", "cancelled"]);
  const etapes = new Set([
    "assigned_pending", "pickup_started", "pickup_completed", "in_transit",
    "incident_reported", "delivery_started", "delivery_completed", "completed",
  ]);
  assert.ok(MISSION_STAGES.length >= 5);
  for (const stage of MISSION_STAGES) {
    assert.ok(statuts.has(stage.status), `statut inconnu : ${stage.status}`);
    assert.ok(etapes.has(stage.progressStatus), `étape inconnue : ${stage.progressStatus}`);
    assert.ok(stage.label && stage.label.length > 3);
  }
});

/* ------------------------------------------------------------------ */
/* Message client                                                      */
/* ------------------------------------------------------------------ */
test("le message client reprend le trajet, le véhicule, le tarif et le téléphone", () => {
  const mission = {
    publicRef: "MIS-2026-1234",
    type: "plateau",
    fromCity: "Paris",
    toCity: "Lille",
    vehicle: "Citroën C5",
    plate: "AA-123-BB",
    clientPhone: "0625353235",
    manualPricing: true,
    manualCarrierPay: 450,
    manualMargin: 90,
  };
  const message = buildClientAssignmentMessage(mission, { fullName: "Jean Dupont" });

  assert.match(message, /Paris → Lille/);
  assert.match(message, /Citroën C5 \(AA-123-BB\)/);
  assert.match(message, /Jean Dupont/);
  assert.match(message, /540\.00 €/);
  assert.match(message, /06 25 35 32 35/);
  assert.ok(!message.includes("undefined"), "aucune valeur manquante ne doit fuiter");
  assert.ok(!message.includes("null"));
});

test("le message reste propre quand la fiche est incomplète", () => {
  const message = buildClientAssignmentMessage({ type: "convoyage" });
  assert.ok(!message.includes("undefined"));
  assert.ok(!message.includes("NaN"));
  assert.match(message, /Départ → Arrivée/);
});

test("le message court suit l'exemple « Paris → Lille · Citroën C5 · téléphone »", () => {
  const court = buildShortAssignmentMessage({
    fromCity: "Paris", toCity: "Lille", vehicle: "Citroën C5", clientPhone: "0625353235",
  });
  assert.equal(court, "Paris → Lille · Citroën C5 · 06 25 35 32 35");
});

test("le lien sms: respecte la syntaxe de chaque plateforme", () => {
  const url = buildSmsUrl("0625353235", "Paris → Lille", { apple: false });
  assert.ok(url.startsWith("sms:+33625353235?body="), url);
  assert.match(url, /Paris%20%E2%86%92%20Lille/);

  const ios = buildSmsUrl("0625353235", "Bonjour", { apple: true });
  assert.ok(ios.startsWith("sms:+33625353235&body="), ios);

  // Sans numéro, le composeur s'ouvre quand même avec le texte prêt.
  assert.ok(buildSmsUrl("", "Bonjour", { apple: false }).startsWith("sms:?body="));
});

test("les numéros français sont normalisés pour le lien sms:", () => {
  assert.equal(normalizePhone("06 25 35 32 35"), "+33625353235");
  assert.equal(normalizePhone("+33 6 25 35 32 35"), "+33625353235");
  assert.equal(normalizePhone("0033625353235"), "0033625353235");
  assert.equal(normalizePhone(""), "");
  assert.equal(normalizePhone(null), "");
  assert.equal(displayPhone("0625353235"), "06 25 35 32 35");
});

/* ------------------------------------------------------------------ */
/* Migration SQL                                                       */
/* ------------------------------------------------------------------ */
test("la migration 021 est bien celle attendue", () => {
  for (const colonne of [
    "manual_pricing", "manual_carrier_pay", "manual_margin",
    "offline_signed", "commission_settled_offline",
  ]) {
    assert.match(migration, new RegExp(`add column if not exists ${colonne}`),
      `colonne manquante : ${colonne}`);
  }

  for (const rpc of [
    "secoto_admin_set_mission_pricing",
    "secoto_admin_assign_mission_direct",
    "secoto_admin_set_mission_stage",
    "secoto_admin_settle_commission_offline",
    "secoto_admin_register_signed_devis",
  ]) {
    assert.match(migration, new RegExp(`create or replace function public\\.${rpc}`),
      `RPC manquante : ${rpc}`);
    assert.match(migration, new RegExp(rpc.replace(/_/g, "_") + "\\("),
      "la RPC doit apparaître dans la liste des droits");
  }

  // Chaque RPC est réservée à l'administrateur et idempotente.
  const nbAssertAdmin = (migration.match(/secoto_private\.assert_admin\(\)/g) || []).length;
  assert.ok(nbAssertAdmin >= 5, "toutes les RPC doivent exiger un administrateur");
  const nbLock = (migration.match(/secoto_private\.lock_operation/g) || []).length;
  assert.ok(nbLock >= 5, "toutes les RPC doivent être idempotentes");

  // Les droits sont retirés à anon avant d'être accordés à authenticated.
  assert.match(migration, /revoke all on function %s from public, anon/);
  assert.match(migration, /grant execute on function %s to authenticated/);

  // Les vues cloisonnées existantes ne doivent JAMAIS être supprimées.
  assert.ok(!/drop view[^\n]*secoto_missions_(admin|client|transporter)_v2/i.test(migration),
    "la migration ne doit pas toucher aux vues cloisonnées");

  // La conversion des colonnes générées n'utilise pas SET EXPRESSION (PG 17).
  assert.ok(!/set expression as/i.test(migration),
    "SET EXPRESSION exigerait PostgreSQL 17 : on utilise DROP EXPRESSION (PG 13+)");
  assert.match(migration, /drop expression/);

  // Le trigger doit passer en dernier parmi les BEFORE.
  assert.match(migration, /create trigger zzz_secoto_mission_amounts/);
});

test("la migration reste transactionnelle et recharge le cache PostgREST", () => {
  assert.match(migration, /^begin;/m);
  assert.match(migration, /^commit;/m);
  assert.match(migration, /notify pgrst, 'reload schema'/);
  // Le rechargement doit venir APRÈS le commit.
  assert.ok(
    migration.lastIndexOf("notify pgrst") > migration.lastIndexOf("\ncommit;"),
    "notify pgrst doit suivre le commit",
  );
});
