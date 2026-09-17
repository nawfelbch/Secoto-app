// Migration 031 — import de l'historique : aucune formule évaluée, macros refusées.
import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import { parseCsv, parseXlsx, mapRows, markDuplicates, readHistoryFile, templateCsv } from "../src/lib/historyImport.js";

const fixture = (name) => fs.readFileSync(new URL(`./fixtures/${name}`, import.meta.url));

test("CSV : séparateur point-virgule, guillemets, BOM, formule laissée en texte", () => {
  const table = parseCsv('﻿date;depart;destination;distance_km;vehicule;mode;montant_eur\r\n12/06/2026;"Paris; 11e";Lyon 69002;465;Clio;Convoyage;=SUM(A1)\r\n');
  const { rows, missingColumns } = mapRows(table);
  assert.deepEqual(missingColumns, []);
  assert.equal(rows[0].from, "Paris; 11e");
  assert.equal(rows[0].date, "2026-06-12");
  assert.equal(rows[0].mode, "convoyage");
  assert.equal(rows[0].amount_eur, "=SUM(A1)");
  assert.ok(rows[0].issues.includes("Montant invalide"));
});

test("XLSX : valeurs lues sans évaluation, dates converties, formules signalées", async () => {
  const { rows, formulaCells } = await parseXlsx(fixture("historique-formule.xlsx"));
  assert.equal(formulaCells, 1);
  const mapped = mapRows(rows);
  assert.equal(mapped.rows[0].date, "2026-06-12");
  assert.equal(mapped.rows[0].distance_km, "465");
  assert.notEqual(mapped.rows[0].fees_eur, "15", "la formule =10+5 n'est jamais calculée");
});

test("XLSX à macros refusé", async () => {
  await assert.rejects(parseXlsx(fixture("classeur-macro.xlsx")), /macros/);
  const fake = { name: "export.xlsm", size: 10, text: async () => "" };
  await assert.rejects(readHistoryFile(fake), /Format refusé/);
});

test("colonnes manquantes, doublons et modèle téléchargeable", () => {
  assert.deepEqual(mapRows([["date", "depart"]]).missingColumns, ["destination", "distance_km", "vehicule", "mode", "montant_eur"]);
  const base = { date: "2026-06-01", from: "A", to: "B", vehicle: "Clio", amount_eur: "100", issues: [] };
  const marked = markDuplicates([base, { ...base }]);
  assert.deepEqual(marked[1].issues, ["Doublon probable"]);
  const template = mapRows(parseCsv(templateCsv()));
  assert.deepEqual(template.missingColumns, []);
  assert.deepEqual(template.rows[0].issues, []);
  const publicTemplate = fs.readFileSync(new URL("../public/modeles/secoto-historique-transports.csv", import.meta.url), "utf8");
  assert.deepEqual(mapRows(parseCsv(publicTemplate)).missingColumns, []);
});
