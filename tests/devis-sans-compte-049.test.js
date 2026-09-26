// Migration 049 — le prix avant le compte.
// La publicité promet un tarif immédiat ; le visiteur devait créer un compte
// avant de voir le moindre prix. Le devis est désormais établi sans compte,
// puis rattaché au compte créé pour réserver.
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const SQL49 = readFileSync(new URL("../supabase/migrations/202609270049_devis_sans_compte.sql", import.meta.url), "utf8");
const FONCTION = readFileSync(new URL("../netlify/functions/quote-public.js", import.meta.url), "utf8");
const API = readFileSync(new URL("../src/lib/onDemand.js", import.meta.url), "utf8");
const ECRAN = readFileSync(new URL("../src/ondemand/OnDemandBooking.jsx", import.meta.url), "utf8");
const APP = readFileSync(new URL("../src/App.jsx", import.meta.url), "utf8");
const { empreinteVisiteur } = await import("../netlify/functions/quote-public.js");

test("un seul chemin de prix : le devis anonyme passe par le calcul normal", () => {
  // Deux calculs séparés finiraient par diverger ; celui-ci réutilise
  // secoto_quote_create, donc le même barème et les mêmes validations.
  const creation = SQL49.slice(SQL49.indexOf("function public.secoto_anon_quote_create"));
  assert.match(creation, /public\.secoto_quote_create\(null, p_payload, p_route\)/);
});

test("le visiteur ne transmet aucun montant", () => {
  assert.match(FONCTION, /price\|cents\|amount\|pay\|margin\|distance/);
  assert.match(FONCTION, /delete payload\.business_id/);
});

test("l'adresse du visiteur n'est ni conservée ni réversible", () => {
  const a = empreinteVisiteur({ headers: { "x-forwarded-for": "81.2.3.4" } }, "2026-09-27");
  const b = empreinteVisiteur({ headers: { "x-forwarded-for": "81.2.3.4" } }, "2026-09-28");
  const c = empreinteVisiteur({ headers: { "x-forwarded-for": "81.2.3.5" } }, "2026-09-27");
  assert.match(a, /^[a-f0-9]{64}$/);
  assert.notEqual(a, b, "l'empreinte doit changer chaque jour");
  assert.notEqual(a, c);
  assert.doesNotMatch(a, /81\.2\.3\.4/);
  assert.equal(empreinteVisiteur({ headers: {} }), null);
});

test("un visiteur compare, il n'aspire pas le barème", () => {
  assert.match(SQL49, /anon_quotes_per_hour/);
  assert.match(SQL49, /Trop de demandes depuis cet appareil/);
  assert.match(SQL49, /created_at > now\(\) - interval '1 hour'/);
});

test("un devis sans propriétaire porte toujours un jeton", () => {
  assert.match(SQL49, /check \(account_id is not null or anon_token is not null\)/);
  assert.match(SQL49, /create unique index if not exists transport_quotes_anon_token_idx/);
});

test("le rattachement efface le jeton et refuse une date dépassée", () => {
  const claim = SQL49.slice(SQL49.indexOf("function public.secoto_anon_quote_claim"));
  assert.match(claim, /anon_token = null/);
  assert.match(claim, /anon_ip_hash = null/);
  assert.match(claim, /claimed_at = now\(\)/);
  assert.match(claim, /pickup_at <= now\(\)/);
  // Un devis déjà rattaché ne peut pas être repris par quelqu'un d'autre.
  assert.match(claim, /q\.account_id is null/);
});

test("seul le serveur peut établir un devis anonyme", () => {
  assert.match(SQL49, /revoke all on function public\.secoto_anon_quote_create\(jsonb, jsonb, text\) from public, anon, authenticated/);
  assert.match(SQL49, /grant execute on function public\.secoto_anon_quote_claim\(text\) to authenticated/);
});

test("l'écran de prix fonctionne sans session", () => {
  assert.match(ECRAN, /anonyme \? await publicQuote\(payload\) : await requestQuote\(payload\)/);
  // Sans compte, il n'y a pas de forfait à interroger.
  assert.match(ECRAN, /if \(anonyme \|\| !flags\?\.subscriptions\) return/);
  assert.match(API, /headers: \{ "Content-Type": "application\/json" \}/);
});

test("le prix survit à la création du compte", () => {
  assert.match(API, /sessionStorage\.setItem\(CLE_DEVIS_ANONYME, token\)/);
  assert.match(APP, /claimAnonQuote\(token\)/);
  assert.match(APP, /initialQuote=\{devisRepris\}/);
  // Le jeton est consommé une seule fois.
  assert.match(API, /sessionStorage\.removeItem\(CLE_DEVIS_ANONYME\)/);
});

test("la page d'accueil affiche le prix, pas un bouton d'inscription", () => {
  const landing = APP.slice(APP.indexOf("function PublicLanding"), APP.indexOf("function PasswordRecoveryScreen"));
  assert.match(landing, /<OnDemandBooking\s+anonyme/);
  assert.doesNotMatch(landing, /Obtenir mon prix et payer/);
});
