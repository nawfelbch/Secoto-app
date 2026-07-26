import test from "node:test";
import assert from "node:assert/strict";

import {
  CONVOYAGE_RATES,
  PLATEAU_MARGIN_COEF,
  carrierView,
  clientView,
  computeCarrierPay,
  computeCarrierTotal,
  computeClientPrice,
  computeClientTotal,
  computeMargin,
  computeReinvoicedExpenses,
  round2,
} from "../src/lib/pricing.js";

test("le barème convoyage reste exactement à 1,00 / 0,55 / 0,45 euro par km", () => {
  assert.deepEqual(CONVOYAGE_RATES, { client: 1, carrier: 0.55, margin: 0.45 });
  assert.equal(computeClientPrice({ type: "convoyage", distanceKm: 123.456 }), 123.46);
  assert.equal(computeCarrierPay({ type: "convoyage", distanceKm: 123.456 }), 67.9);
  assert.equal(computeMargin({ type: "convoyage", distanceKm: 123.456 }), 55.56);
});

test("le plateau applique exactement 20 % sans minimum", () => {
  assert.equal(PLATEAU_MARGIN_COEF, 1.2);
  assert.equal(computeClientPrice({ type: "plateau", carrierCost: 100.1 }), 120.12);
  assert.equal(computeCarrierPay({ type: "plateau", carrierCost: 100.1 }), 100.1);
  assert.equal(computeMargin({ type: "plateau", carrierCost: 100.1 }), 20.02);
  assert.equal(computeClientPrice({ type: "plateau", carrierCost: 0.5 }), 0.6);
  assert.equal(computeMargin({ type: "plateau", carrierCost: 0.5 }), 0.1);
});

test("les valeurs négatives, invalides ou absentes ne créent jamais un montant", () => {
  for (const value of [-1, "invalide", undefined, Number.NaN, Number.POSITIVE_INFINITY]) {
    assert.equal(computeClientPrice({ type: "convoyage", distanceKm: value }), 0);
    assert.equal(computeCarrierPay({ type: "plateau", carrierCost: value }), 0);
  }
  assert.equal(computeClientPrice(null), 0);
  assert.equal(computeCarrierPay({ type: "inconnu", carrierCost: 500 }), 0);
});

test("les frais réels restent neutres pour la marge", () => {
  const mission = { type: "convoyage", distanceKm: 100, reinvoicedExpenses: 42.37 };
  assert.equal(computeReinvoicedExpenses(mission), 42.37);
  assert.equal(computeClientTotal(mission), 142.37);
  assert.equal(computeCarrierTotal(mission), 97.37);
  assert.equal(computeMargin(mission), 45);
});

test("les vues financières n'exposent pas les montants de l'autre rôle", () => {
  const mission = { type: "plateau", carrierCost: 250, reinvoicedExpenses: 20 };
  assert.deepEqual(clientView(mission), {
    prestation: 300,
    fraisRefactures: 20,
    total: 320,
  });
  assert.deepEqual(carrierView(mission), {
    remuneration: 250,
    remboursementFrais: 20,
    total: 270,
  });
  assert.equal("remuneration" in clientView(mission), false);
  assert.equal("prestation" in carrierView(mission), false);
  assert.equal("margin" in clientView(mission), false);
  assert.equal("margin" in carrierView(mission), false);
});

test("l'arrondi monétaire reste stable à deux décimales", () => {
  assert.equal(round2(1.005), 1.01);
  assert.equal(round2(10.999), 11);
});
