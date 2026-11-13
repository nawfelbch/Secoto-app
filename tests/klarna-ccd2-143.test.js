import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync, readdirSync } from "node:fs";
import * as copy from "../src/lib/orderCopy.js";

const lire = (p) => readFileSync(new URL(`../${p}`, import.meta.url), "utf8");

test("143 : texte approuvé Klarna et avertissement obligatoire, mot pour mot", () => {
  assert.equal(copy.KLARNA_3_FOIS, "Choisissez Klarna. Payez en 3 fois.");
  assert.equal(copy.KLARNA_AVERTISSEMENT, "Attention ! Un crédit coûte de l’argent et doit être remboursé.");
  const klarna = copy.MODES_REGLEMENT.find((m) => m.cle === "klarna");
  assert.equal(klarna.libelle, "Klarna");
  assert.ok(klarna.detail.startsWith(`${copy.KLARNA_3_FOIS} ${copy.KLARNA_AVERTISSEMENT}`));
});

test("143 : Klarna réservé aux particuliers (interdit en B2B)", () => {
  const order = { especes_possible: true, virement_possible: true };
  assert.ok(copy.modesReglementPossibles(order).some((m) => m.cle === "klarna"));
  assert.ok(!copy.modesReglementPossibles({ ...order, client_pro: true }).some((m) => m.cle === "klarna"));
  const sql = lire("supabase/migrations/202611130143_klarna_ccd2_et_b2b.sql");
  assert.match(sql, /p_mode = 'klarna' and exists[\s\S]*a\.client_type = 'pro'/);
});

test("143 : plus aucun « Klarna en plusieurs fois » ni exemple « 3 × » dans nos textes", () => {
  const fichiers = [
    "src/App.jsx", "src/lib/orderCopy.js", "src/lib/messageDevis.js", "src/lib/faqReservation.js",
    ...readdirSync(new URL("../src/ondemand/", import.meta.url)).filter((f) => f.endsWith(".jsx")).map((f) => `src/ondemand/${f}`),
    "netlify/lib/devis-direct.js", "netlify/functions/devis-pay.js",
  ];
  for (const f of fichiers) {
    const t = lire(f);
    assert.doesNotMatch(t, /Klarna en plusieurs fois|plusieurs fois avec Klarna|Klarna \((en )?plusieurs fois\)|en plusieurs fois \(Klarna\)/, f);
    assert.doesNotMatch(t, /3 × \$\{/, f);
  }
  const sql = lire("supabase/migrations/202611130143_klarna_ccd2_et_b2b.sql");
  assert.match(sql, /virement%4\$s ou avec Klarna/);
  assert.match(sql, /jusqu''au %6\$s/);
});

test("143 : pages de paiement Stripe sans Klarna pour un compte pro", async () => {
  const { sansKlarnaPourPro } = await import("../netlify/functions/create-payment-intent.js");
  assert.deepEqual(sansKlarnaPourPro({ client_type: "pro" }), { excluded_payment_method_types: ["klarna"] });
  assert.deepEqual(sansKlarnaPourPro({ client_type: "particulier" }), {});
  assert.deepEqual(sansKlarnaPourPro(null), {});
  const src = lire("netlify/functions/create-payment-intent.js");
  assert.equal((src.match(/\.\.\.sansKlarnaPourPro\(account\)/g) || []).length, 6);
  assert.match(src, /select\("id,email,full_name,stripe_customer_id,client_type"\)/);
});
