// SECOTO — Référencement : l'app n'est pas indexée, la provenance « Google
// naturel » est reconnue, le barème public ne livre que les prix clients.
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { provenanceNaturelle, SOURCE_GOOGLE_NATUREL } from "../src/lib/attribution.js";
import { libelleSource } from "../src/lib/sourcesProvenance.js";

const lire = (f) => readFileSync(new URL(`../${f}`, import.meta.url), "utf8");

test("app jamais indexée : balise robots + en-tête Netlify + page de paiement", () => {
  assert.match(lire("index.html"), /<meta name="robots" content="noindex, nofollow" \/>/);
  assert.doesNotMatch(lire("index.html"), /content="index, follow"/);
  assert.match(lire("netlify.toml"), /for = "\/\*"\s+\[headers\.values\]\s+X-Robots-Tag = "noindex, nofollow"/);
  assert.match(lire("netlify/functions/devis-pay.js"), /"X-Robots-Tag": "noindex, nofollow"/);
});

test("Google naturel : venu du site depuis Google, ou de Google directement, jamais avec un gclid", () => {
  assert.deepEqual(
    provenanceNaturelle({ utm_source: "site", utm_medium: "organic_page", utm_campaign: "transport-moto", utm_content: "google-naturel" }, ""),
    { utm_source: SOURCE_GOOGLE_NATUREL, utm_medium: "organic_page", utm_campaign: "transport-moto", utm_content: "google-naturel" });
  assert.deepEqual(provenanceNaturelle({}, "https://www.google.fr/"), { utm_source: "google-naturel", utm_medium: "organic" });
  assert.deepEqual(provenanceNaturelle({}, "https://google.com/search?q=x"), { utm_source: "google-naturel", utm_medium: "organic" });
  assert.deepEqual(provenanceNaturelle({}, "https://www.bing.com/"), {});
  assert.deepEqual(provenanceNaturelle({}, "https://google.evil.example/"), {});
  assert.deepEqual(provenanceNaturelle({ gclid: "abc" }, "https://www.google.fr/"), { gclid: "abc" });
  assert.deepEqual(provenanceNaturelle({ utm_source: "site", utm_campaign: "accueil" }, ""), { utm_source: "site", utm_campaign: "accueil" });
  assert.equal(libelleSource("google-naturel"), "Google naturel");
  assert.equal(libelleSource("site"), "Site (autres visites)");
  assert.equal(libelleSource("google"), "google");
});

test("migration 098 : barème public en lecture seule, sans rémunération transporteur", () => {
  const sql = lire("supabase/migrations/202610170098_bareme_public.sql");
  assert.match(sql, /grant execute on function public\.secoto_bareme_public\(\) to anon/);
  assert.match(sql, /client_eur_per_km/);
  assert.doesNotMatch(sql, /'partner_eur_per_km'|partner_cap_eur|min_margin|\binsert\b|\bupdate\b|\bdelete\b|\bdrop\b/i);
});
