// 110 — comptage anonyme des étapes : provenance réduite et taux de passage.
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const { sourceVisite, ETAPES } = await import("../src/lib/entonnoir.js").catch(() => ({}));

test("provenance : ads, naturel, direct, autre", { skip: !sourceVisite && "supabaseClient non importable sous Node" }, () => {
  assert.equal(sourceVisite({ gclid: "x" }), "ads");
  assert.equal(sourceVisite({ utm_medium: "cpc", utm_source: "google" }), "ads");
  assert.equal(sourceVisite({ utm_source: "google-naturel" }), "naturel");
  assert.equal(sourceVisite(null), "direct");
  assert.equal(sourceVisite({ utm_source: "facebook" }), "autre");
  assert.ok(ETAPES.includes("contact") && ETAPES.includes("prix"));
});

test("le formulaire compte chaque étape, sans envoyer son contenu", () => {
  const src = readFileSync(new URL("../src/ondemand/OnDemandBooking.jsx", import.meta.url), "utf8");
  const express = readFileSync(new URL("../src/ondemand/ReserverExpress.jsx", import.meta.url), "utf8");
  for (const e of ["arrivee", "trajet", "vehicule", "mode", "dates", "contact", "prix", "erreur_prix", "reserver"]) {
    assert.ok(src.includes(`"${e}"`) || express.includes(`"${e}"`), `étape ${e} branchée`);
  }
  const lib = readFileSync(new URL("../src/lib/entonnoir.js", import.meta.url), "utf8");
  assert.match(lib, /sessionStorage/);
  assert.doesNotMatch(lib, /localStorage\.setItem|document\.cookie|pickup|phone|email/);
  const sql = readFileSync(new URL("../supabase/migrations/202610210110_entonnoir_formulaire.sql", import.meta.url), "utf8");
  assert.match(sql, /grant execute on function public\.secoto_etape_formulaire\(uuid, text, text, boolean, boolean\) to anon, authenticated/);
  assert.match(sql, /90 days/);
});
