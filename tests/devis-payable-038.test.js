// Migration 038 — devis payable en un clic (sans réseau).
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const SQL = readFileSync(new URL("../supabase/migrations/202609230038_devis_payable_en_un_clic.sql", import.meta.url), "utf8");
const FONCTION = readFileSync(new URL("../netlify/functions/devis-pay.js", import.meta.url), "utf8");
const { page } = await import("../netlify/functions/devis-pay.js");

test("un seul lien de paiement vivant par mission", () => {
  // Deux adresses valides encaisseraient deux fois la même course.
  assert.match(SQL, /create unique index if not exists devis_payment_links_actif_idx/);
  assert.match(SQL, /where revoked_at is null and paid_at is null/);
});

test("le motif devis_course est autorisé sur les paiements", () => {
  const contrainte = SQL.slice(SQL.indexOf("payments_purpose_check"));
  assert.match(contrainte, /'devis_course'/);
});

test("le lien n'est ouvrable ni par un visiteur ni par un compte connecté", () => {
  assert.match(SQL, /revoke all on function public\.secoto_devis_link_open\(text\) from public, anon, authenticated/);
  assert.match(SQL, /revoke all on table public\.devis_payment_links from anon, authenticated/);
});

test("un lien payé, révoqué, expiré ou annulé ne prépare aucun paiement", () => {
  const ouverture = SQL.slice(SQL.indexOf("function public.secoto_devis_link_open"));
  for (const motif of ["deja_paye", "lien_revoque", "lien_expire", "course_annulee"]) {
    assert.match(ouverture, new RegExp(`'error', '${motif}'`));
  }
});

test("le montant vient de la base, jamais de l'URL", () => {
  // La fonction Netlify ne transmet qu'un jeton ; le montant est relu ensuite.
  assert.match(FONCTION, /secoto_devis_link_open", \{ p_token: token \}/);
  assert.doesNotMatch(FONCTION, /queryStringParameters\?\.(amount|montant)/);
  assert.match(FONCTION, /unit_amount: data\.amount_cents/);
});

test("le jeton doit ressembler à un jeton avant tout appel", () => {
  assert.match(FONCTION, /\/\^\[a-f0-9\]\{24,64\}\$\//);
});

test("le retour depuis Stripe ne relance pas de paiement", () => {
  const retour = FONCTION.slice(FONCTION.indexOf('retour === "ok"'));
  assert.match(retour, /paiement est enregistré/);
  assert.ok(FONCTION.indexOf('retour === "ok"') < FONCTION.indexOf("secoto_devis_link_open"));
});

test("le paiement vaut acceptation : le devis passe en signé et le bon part", () => {
  const trigger = SQL.slice(SQL.indexOf("function secoto_private.devis_course_paid"));
  assert.match(trigger, /statut = 'signe'::public\.secoto_doc_statut/);
  assert.match(trigger, /secoto_release_mission_order\(new\.mission_id\)/);
  assert.match(trigger, /new\.purpose <> 'devis_course' or new\.status <> 'paid'/);
});

test("la page client reste lisible et sans jargon", () => {
  const html = page("Lien inutilisable", "Ce lien a expiré.");
  assert.match(html, /<html lang="fr">/);
  assert.match(html, /Ce lien a expiré\./);
  assert.doesNotMatch(html, /mission_id|payment_id|acct_/);
});
