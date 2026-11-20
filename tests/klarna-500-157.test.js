import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { klarnaSousPrix, klarnaPossible, modesReglementPossibles, KLARNA_MIN_CENTS } from "../src/lib/orderCopy.js";

test("157 : Klarna seulement à partir de 500 € (écrans)", () => {
  assert.equal(KLARNA_MIN_CENTS, 50000);
  assert.equal(klarnaSousPrix(49999), "");
  assert.equal(klarnaSousPrix(50000), "ou payez avec Klarna, à la livraison");
  assert.equal(klarnaPossible({ client_price_cents: 38200 }), false);
  assert.equal(klarnaPossible({ client_price_cents: 93000 }), true);
  assert.equal(klarnaPossible({ client_price_cents: 93000, client_pro: true }), false);
  assert.ok(!modesReglementPossibles({ client_price_cents: 38200 }).some((m) => m.cle === "klarna"));
  assert.ok(modesReglementPossibles({ client_price_cents: 93000 }).some((m) => m.cle === "klarna"));
});

test("157 : Stripe ne propose pas Klarna sous 500 €, ni aux pros", async () => {
  const { sansKlarnaPourPro } = await import("../netlify/functions/create-payment-intent.js");
  assert.deepEqual(sansKlarnaPourPro({ client_type: "particulier" }, 38200), { excluded_payment_method_types: ["klarna"] });
  assert.deepEqual(sansKlarnaPourPro({ client_type: "particulier" }, 93000), {});
  assert.deepEqual(sansKlarnaPourPro({ client_type: "pro" }, 93000), { excluded_payment_method_types: ["klarna"] });
});

test("157 : la base refuse Klarna sous 500 €", () => {
  const sql = readFileSync(new URL("../supabase/migrations/202611200157_klarna_des_500.sql", import.meta.url), "utf8");
  assert.match(sql, /'min_cents', 50000/);
  assert.match(sql, /Klarna est disponible à partir de 500 €/);
});
