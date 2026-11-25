import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";

const source = (p) => readFile(new URL(p, import.meta.url), "utf8");

test("159 : un frais de convoyage validé rejoint le versement Stripe (ou un versement séparé)", async () => {
  const sql = await source("../supabase/migrations/202611250159_frais_rembourses_automatiquement.sql");
  assert.match(sql, /array\['mission', 'late_cancel', 'frais'\]/);
  assert.match(sql, /m\.type <> 'convoyage'/, "convoyage seulement");
  assert.match(sql, /if p\.status = 'to_pay' then[\s\S]*amount_cents = amount_cents \+ v_cents/, "ajout au versement pas encore parti");
  assert.match(sql, /p\.status in \('paid', 'processing', 'failed'\)[\s\S]*'frais'/, "versement séparé si déjà parti ou en cours");
  assert.match(sql, /f\.payout_id is not null then return 'ignore'/, "jamais versé deux fois");
  assert.match(sql, /payment_circuit = 'direct'[\s\S]*Frais à rembourser à la main/, "paiement direct : admin prévenu");
  assert.match(sql, /validated_at >= '2026-11-23'/, "rattrapage limité aux frais depuis la 158");
  const copie = await source("../deliverables/SECOTO-159-frais-rembourses-automatiquement-a-coller-dans-Supabase.sql");
  assert.equal(copie, sql);
});

test("159 : le transfert Stripe d'un versement de frais porte un libellé clair", async () => {
  const js = await source("../netlify/functions/od-maintenance.js");
  assert.match(js, /p\.kind === "frais" \? "SECOTO — remboursement carburant et péages"/);
});
