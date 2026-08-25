import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { buildApplicationRpcPayload } from "../src/lib/applicationOffer.js";

const app = readFileSync(new URL("../src/App.jsx", import.meta.url), "utf8");
const bank = readFileSync(
  new URL("../src/BankAccountPanel.jsx", import.meta.url),
  "utf8",
);
const mappers = readFileSync(
  new URL("../src/lib/mappers.js", import.meta.url),
  "utf8",
);
const reliabilityMigration = readFileSync(
  new URL(
    "../supabase/migrations/202608250013_release_reliability.sql",
    import.meta.url,
  ),
  "utf8",
);

test("l'urgence désactivée n'est plus proposée dans le formulaire mission", () => {
  assert.doesNotMatch(app, /Urgence sous 24 h/);
  assert.doesNotMatch(app, /name="surchargeUrgent"/);
});

test("les disponibilités et le tarif groupé remontent jusqu'à l'administration", () => {
  for (const field of [
    "proposed_price_grouped",
    "pickup_earliest_at",
    "pickup_latest_at",
    "delivery_earliest_at",
    "delivery_latest_at",
  ]) {
    assert.match(app, new RegExp(field), field);
    assert.match(mappers, new RegExp(field), field);
  }
  assert.match(app, /ApplicationAvailabilitySummary/);
  assert.match(app, /Tarif si groupé/);

  const payload = buildApplicationRpcPayload({
    missionId: "mission-1",
    idempotencyKey: "operation-1",
    proposedPrice: "850",
    proposedPriceGrouped: "790",
    pickupEarliestAt: "2026-08-25T08:00:00+02:00",
    pickupLatestAt: "2026-08-25T10:00:00+02:00",
    deliveryEarliestAt: "2026-08-25T16:00:00+02:00",
    deliveryLatestAt: "2026-08-25T19:00:00+02:00",
    message: "Disponible",
  });
  assert.deepEqual(Object.keys(payload).sort(), [
    "p_delivery_earliest_at",
    "p_delivery_latest_at",
    "p_idempotency_key",
    "p_message",
    "p_mission_id",
    "p_pickup_earliest_at",
    "p_pickup_latest_at",
    "p_proposed_price",
    "p_proposed_price_grouped",
  ]);
  assert.equal(payload.p_pickup_earliest_at, "2026-08-25T06:00:00.000Z");
  assert.equal(payload.p_proposed_price_grouped, 790);
});

test("la RPC Supabase accepte réellement tous les champs envoyés par le front", () => {
  assert.match(
    reliabilityMigration,
    /create or replace function public\.secoto_apply_to_mission\([\s\S]*?p_pickup_earliest_at timestamptz[\s\S]*?p_proposed_price_grouped numeric/,
  );
  assert.match(reliabilityMigration, /grant execute on function public\.secoto_apply_to_mission/);
  assert.match(reliabilityMigration, /notify pgrst, 'reload schema'/);
});

test("les coordonnées bancaires utilisent uniquement les RPC sécurisées", () => {
  assert.match(bank, /secoto_my_bank_account/);
  assert.match(bank, /secoto_set_bank_account/);
  assert.doesNotMatch(bank, /\.from\(["']partner_bank_accounts["']\)/);
});

test("l'onglet bancaire est réservé au véritable compte transporteur", () => {
  assert.match(app, /label: "Coordonnées bancaires"/);
  assert.match(app, /account\.role === "transporter"/);
  assert.match(app, /transporterTab === "bank" && !isAdmin/);
  assert.match(app, /<BankAccountPanel account=\{account\}/);
});
