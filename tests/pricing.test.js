import test from "node:test";
import assert from "node:assert/strict";

import {
  CONVOYAGE_MINIMUM,
  CONVOYEUR_RATE,
  PLATEAU_COMMISSION_PCT,
  carrierView,
  clientView,
  computeCarrierPay,
  computeCarrierTotal,
  computeClientPrice,
  computeClientTotal,
  computeClientTotalDue,
  computeCommission,
  computeConvoyageBase,
  computeMargin,
  computeReinvoicedExpenses,
  computeTransportAmount,
  round2,
} from "../src/lib/pricing.js";

test("le barème convoyage applique des paliers CUMULATIFS, jamais un tarif unique", () => {
  // Cas de contrôle imposés par la règle métier.
  assert.equal(computeConvoyageBase(80), 115);   // plancher
  assert.equal(computeConvoyageBase(400), 390);  // 300x1,00 + 100x0,90
  assert.equal(computeConvoyageBase(935), 864.8); // 300x1,00 + 300x0,90 + 335x0,88

  assert.equal(computeClientPrice({ type: "convoyage", distanceKm: 80 }), 115);
  assert.equal(computeClientPrice({ type: "convoyage", distanceKm: 400 }), 390);
  assert.equal(computeClientPrice({ type: "convoyage", distanceKm: 935 }), 864.8);

  // Le piège à éviter : 935 km au tarif unique de 1,00 € donnerait 935,00 €.
  assert.notEqual(computeClientPrice({ type: "convoyage", distanceKm: 935 }), 935);
});

test("les bornes exactes des tranches sont respectées", () => {
  assert.equal(CONVOYAGE_MINIMUM, 115);
  assert.equal(computeConvoyageBase(115), 115);   // plancher encore actif
  assert.equal(computeConvoyageBase(116), 116);   // premier km au-dessus du plancher
  assert.equal(computeConvoyageBase(300), 300);   // fin de la 1re tranche
  assert.equal(computeConvoyageBase(301), 300.9); // 300 + 1x0,90
  assert.equal(computeConvoyageBase(600), 570);   // 300 + 300x0,90
  assert.equal(computeConvoyageBase(601), 570.88);
  assert.equal(computeConvoyageBase(0), 115);
});

test("les suppléments sont des multiplicateurs cumulables", () => {
  const base = { type: "convoyage", distanceKm: 400 }; // 390,00
  assert.equal(computeClientPrice({ ...base, surchargeUrgent: true }), 507);   // x1,30
  assert.equal(computeClientPrice({ ...base, surchargeWeekend: true }), 468);  // x1,20
  assert.equal(
    computeClientPrice({ ...base, surchargeUrgent: true, surchargeWeekend: true }),
    608.4, // 390 x 1,30 x 1,20
  );
  assert.equal(computeClientPrice({ ...base, surchargeOversizePct: 40 }), 546); // x1,40
  // Le supplément gabarit est borné à 40 % même si la valeur saisie déborde.
  assert.equal(computeClientPrice({ ...base, surchargeOversizePct: 200 }), 546);
  assert.equal(computeClientPrice({ ...base, surchargeOversizePct: -10 }), 390);
});

test("la rémunération du convoyeur reste à 0,55 euro par km, sans supplément", () => {
  assert.equal(CONVOYEUR_RATE, 0.55);
  assert.equal(computeCarrierPay({ type: "convoyage", distanceKm: 400 }), 220);
  // Les suppléments profitent à SECOTO, pas au convoyeur.
  assert.equal(
    computeCarrierPay({ type: "convoyage", distanceKm: 400, surchargeUrgent: true }),
    220,
  );
  assert.equal(computeMargin({ type: "convoyage", distanceKm: 400 }), 170);
});

test("en plateau SECOTO n'encaisse QUE la commission de 20 pour cent", () => {
  assert.equal(PLATEAU_COMMISSION_PCT, 20);
  const mission = { type: "plateau", carrierCost: 100 };
  assert.equal(computeCommission(mission), 20);
  assert.equal(computeClientPrice(mission), 20);      // encaissé par SECOTO
  assert.equal(computeTransportAmount(mission), 100); // jamais encaissé par SECOTO
  assert.equal(computeClientTotalDue(mission), 120);  // déboursé par le client
  assert.equal(computeCarrierPay(mission), 100);      // reversé en direct
  assert.equal(computeMargin(mission), 20);
});

test("la commission plateau n'a aucun plancher et suit le tarif libre du transporteur", () => {
  assert.equal(computeClientPrice({ type: "plateau", carrierCost: 0.5 }), 0.1);
  assert.equal(computeClientPrice({ type: "plateau", carrierCost: 100.1 }), 20.02);
  assert.equal(computeClientTotalDue({ type: "plateau", carrierCost: 100.1 }), 120.12);
  // Le forfait minimum du convoyage ne doit JAMAIS contaminer le plateau.
  assert.equal(computeClientPrice({ type: "plateau", carrierCost: 10 }), 2);
});

test("aucun supplément convoyage ne s'applique à une mission plateau", () => {
  const mission = {
    type: "plateau",
    carrierCost: 100,
    surchargeUrgent: true,
    surchargeWeekend: true,
    surchargeOversizePct: 40,
  };
  assert.equal(computeClientPrice(mission), 20);
  assert.equal(computeClientTotalDue(mission), 120);
});

test("les valeurs négatives, invalides ou absentes ne créent jamais un montant", () => {
  for (const value of [-1, "invalide", undefined, Number.NaN, Number.POSITIVE_INFINITY]) {
    // Le convoyage retombe sur le forfait minimum, jamais sur un montant absurde.
    assert.equal(computeClientPrice({ type: "convoyage", distanceKm: value }), 115);
    assert.equal(computeCarrierPay({ type: "plateau", carrierCost: value }), 0);
    assert.equal(computeCommission({ type: "plateau", carrierCost: value }), 0);
  }
  assert.equal(computeClientPrice(null), 0);
  assert.equal(computeCarrierPay({ type: "inconnu", carrierCost: 500 }), 0);
  assert.equal(computeCommission({ type: "convoyage", distanceKm: 400 }), 0);
  assert.equal(computeTransportAmount({ type: "convoyage", distanceKm: 400 }), 0);
});

test("les frais réels restent neutres pour la marge", () => {
  const mission = { type: "convoyage", distanceKm: 400, reinvoicedExpenses: 42.37 };
  assert.equal(computeReinvoicedExpenses(mission), 42.37);
  assert.equal(computeClientTotal(mission), 432.37);
  assert.equal(computeCarrierTotal(mission), 262.37);
  assert.equal(computeMargin(mission), 170);
});

test("les vues financières n'exposent pas les montants de l'autre rôle", () => {
  const plateau = { type: "plateau", carrierCost: 250 };
  assert.deepEqual(clientView(plateau), {
    commission: 50,
    transport: 250,
    fraisRefactures: 0,
    total: 300,
  });
  assert.deepEqual(carrierView(plateau), {
    remuneration: 250,
    remboursementFrais: 0,
    total: 250,
  });

  const convoyage = { type: "convoyage", distanceKm: 400, reinvoicedExpenses: 20 };
  assert.deepEqual(clientView(convoyage), {
    prestation: 390,
    fraisRefactures: 20,
    total: 410,
  });

  assert.equal("remuneration" in clientView(plateau), false);
  assert.equal("prestation" in carrierView(plateau), false);
  assert.equal("margin" in clientView(plateau), false);
  assert.equal("margin" in carrierView(plateau), false);
});

test("l'arrondi monétaire reste stable à deux décimales", () => {
  assert.equal(round2(1.005), 1.01);
  assert.equal(round2(10.999), 11);
});
