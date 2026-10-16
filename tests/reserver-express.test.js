// SECOTO — Réserver sans formulaire d'inscription : nom + e-mail, compte créé
// en arrière-plan, puis paiement (même chemin que l'inscription classique).
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { webcrypto } from "node:crypto";
import { creerCompteExpress, estCompteExistant, motDePasseAleatoire, verifierSaisie } from "../src/lib/compteExpress.js";

const fauxSupabase = (reponse) => {
  const appels = [];
  return { appels, auth: { signUp: async (p) => { appels.push(p); return reponse; } } };
};

test("mot de passe : long, aléatoire, jamais deux fois le même", () => {
  const a = motDePasseAleatoire(webcrypto), b = motDePasseAleatoire(webcrypto);
  assert.equal(a.length, 26);
  assert.notEqual(a, b);
  assert.match(a, /[A-Z]/); assert.match(a, /[a-z]/); assert.match(a, /\d/); assert.match(a, /[^A-Za-z0-9]/);
});

test("saisie : nom et e-mail valides obligatoires", () => {
  assert.match(verifierSaisie({ nom: "", email: "a@b.fr" }), /nom/);
  assert.match(verifierSaisie({ nom: "Karim", email: "karim@" }), /e-mail/);
  assert.equal(verifierSaisie({ nom: "Karim B", email: "Karim@Gmail.com " }), "");
});

test("compte client particulier créé avec téléphone, conditions et provenance", async () => {
  const sb = fauxSupabase({ data: { session: { access_token: "x" }, user: { id: "u1", identities: [{}] } }, error: null });
  const r = await creerCompteExpress({ supabase: sb, nom: " Karim B ", email: " Karim@Gmail.com ", telephone: "+33612345678",
    termsVersion: "2026-10-09", platform: "ios", attribution: { utm_source: "google" }, consentement: true, aleatoire: webcrypto });
  assert.deepEqual(r, { ok: true, userId: "u1" });
  const p = sb.appels[0];
  assert.equal(p.email, "karim@gmail.com");
  assert.equal(p.options.data.role, "client");
  assert.equal(p.options.data.client_type, "particulier");
  assert.equal(p.options.data.full_name, "Karim B");
  assert.equal(p.options.data.phone, "+33612345678");
  assert.equal(p.options.data.terms_version, "2026-10-09");
  assert.equal(p.options.data.terms_platform, "ios");
  assert.equal(p.options.data.attribution.utm_source, "google");
  assert.equal(p.options.data.compte_express, true);
  assert.ok(p.password.length >= 20);
});

test("adresse déjà inscrite → connexion proposée, aucun doublon", async () => {
  assert.equal(estCompteExistant({ code: "user_already_exists", message: "User already registered" }), true);
  assert.equal(estCompteExistant(null, { user: { identities: [] } }), true);
  assert.equal(estCompteExistant(null, { user: { identities: [{}] } }), false);
  const sb = fauxSupabase({ data: { user: null, session: null }, error: { code: "user_already_exists", message: "User already registered" } });
  assert.deepEqual(await creerCompteExpress({ supabase: sb, nom: "Karim", email: "k@b.fr", aleatoire: webcrypto }), { existant: true });
});

test("confirmation d'e-mail exigée → message clair ; autre erreur → remontée", async () => {
  const sb = fauxSupabase({ data: { user: { id: "u2", identities: [{}] }, session: null }, error: null });
  assert.deepEqual(await creerCompteExpress({ supabase: sb, nom: "Karim", email: "k@b.fr", aleatoire: webcrypto }), { confirmation: true });
  const ko = fauxSupabase({ data: null, error: { message: "Too many requests" } });
  await assert.rejects(creerCompteExpress({ supabase: ko, nom: "Karim", email: "k@b.fr", aleatoire: webcrypto }), { message: /Too many/ });
  await assert.rejects(creerCompteExpress({ supabase: ko, nom: "", email: "k@b.fr", aleatoire: webcrypto }), /nom/);
});

test("écran : bloc express sous le prix, fenêtre des notifications retenue pendant le paiement", () => {
  const app = readFileSync(new URL("../src/App.jsx", import.meta.url), "utf8");
  assert.match(app, /!pushGateVue && !repriseEnCours && !devisRepris/);
  assert.match(app, /queueMicrotask\(\(\) => setRepriseEnCours\(true\)\);\s+claimAnonQuote\(token\)/);
  const bloc = readFileSync(new URL("../src/ondemand/ReserverExpress.jsx", import.meta.url), "utf8");
  assert.match(bloc, /creerCompteExpress\(/);
  assert.match(bloc, /checked=\{coche\}/); // case des conditions jamais pré-cochée
  assert.match(bloc, /useState\(false\)/);
});
