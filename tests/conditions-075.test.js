// SECOTO 075 — acceptation des conditions : contrôles statiques et page de lien.
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const lire = (chemin) => readFileSync(new URL(`../${chemin}`, import.meta.url), "utf8");
const SQL = lire("supabase/migrations/202610090075_acceptation_conditions.sql");
const APP = lire("src/App.jsx");
const GATE = lire("src/ConditionsGate.jsx");
const LIB = lire("src/lib/conditions.js");
const { pageRenonciation, liensConditions } = await import("../netlify/functions/devis-pay.js");

const CONDITIONS = {
  version: "2026-10-09-projet",
  documents: ["cgu", "confidentialite"],
  urls: { cgu: "/cgu.html", confidentialite: "/politique-confidentialite.html" },
};

test("075 est additive : aucune suppression ni modification destructive", () => {
  assert.doesNotMatch(SQL, /\bdrop table\b|\bdrop column\b|\btruncate\b|\bdelete from\b/i);
  assert.doesNotMatch(SQL, /alter column/i);
  // Les deux interrupteurs naissent éteints (valeur par défaut de la table).
  assert.match(SQL, /insert into public\.secoto_feature_flags\(key\) values \('conditions_v2'\) on conflict \(key\) do nothing/);
  assert.match(SQL, /insert into public\.secoto_feature_flags\(key\) values \('commission_client'\) on conflict \(key\) do nothing/);
  // Aucune clé d'interrupteur existante n'est retirée.
  for (const cle of ["auto_pricing", "od_payments", "subscriptions", "dispatch_notifications", "live_tracking", "direct_accept", "connect_payouts", "plateau_paiement_direct"]) {
    assert.match(SQL, new RegExp(`'${cle}'`));
  }
});

test("la preuve est protégée : RLS, lecture de ses seules lignes, écriture par fonction", () => {
  assert.match(SQL, /alter table public\.terms_acceptances enable row level security/);
  assert.match(SQL, /revoke all on public\.terms_acceptances from public, anon, authenticated/);
  assert.match(SQL, /using \(account_id = auth\.uid\(\) or secoto_private\.current_is_admin\(\)\)/);
  assert.match(SQL, /unique \(account_id, terms_version\)/);
});

test("la fenêtre bloque tout, sauf pour l'administrateur", () => {
  const avant = APP.indexOf("conditionsStatut?.required");
  const app = APP.indexOf('const isAdmin = account.role === "admin";');
  assert.ok(avant > 0 && avant < app, "la fenêtre doit précéder l'application");
  assert.match(APP, /account\.role !== "admin"/);
  assert.match(SQL, /coalesce\(v_role, 'client'\) not in \('client', 'transporter'\)/);
});

test("une seule case, jamais pré-cochée, un seul bouton « Accepter »", () => {
  assert.equal((GATE.match(/type="checkbox"/g) || []).length, 1);
  assert.match(GATE, /useState\(false\)/);
  assert.doesNotMatch(GATE, /defaultChecked|checked=\{true\}/);
  assert.match(GATE, /disabled=\{!coche \|\| busy\}/);
  assert.match(GATE, />\s*\{busy \? "Enregistrement…" : "Accepter"\}/);
});

test("inscription : la case n'apparaît qu'interrupteur allumé et bloque l'envoi", () => {
  assert.match(APP, /termsPublic\(\)\.then/);
  assert.match(APP, /const \[conditionsCochees, setConditionsCochees\] = useState\(false\)/);
  assert.match(APP, /disabled=\{loading \|\| Boolean\(conditions && !conditionsCochees\)\}/);
  assert.match(APP, /terms_version: conditions && conditionsCochees \? conditions\.version : null/);
});

test("un incident technique n'enferme personne hors de l'application", () => {
  assert.match(LIB, /if \(error \|\| !data\) return \{ required: false \}/);
  assert.match(LIB, /if \(error \|\| !data\) return \{ active: false \}/);
});

test("lien de paiement : case des conditions non pré-cochée, liens visibles", () => {
  const page = pageRenonciation("abc123", 42000, "Sénas → Loguivy", { renonciation: false, conditions: CONDITIONS });
  assert.match(page, /type="checkbox" name="conditions" value="oui" required/);
  assert.doesNotMatch(page, /name="consent"/);
  assert.doesNotMatch(page, /checked/);
  assert.match(page, /name="version" value="2026-10-09-projet"/);
  assert.match(page, /href="https:\/\/app\.secoto-transport\.fr\/cgu\.html\?v=2026-10-09-projet"/);
  assert.match(liensConditions(CONDITIONS), /les conditions générales<\/a> et <a [^>]+>la politique de confidentialité/);
});

test("lien de paiement : particulier = conditions + renonciation ; interrupteur éteint = comme avant", () => {
  const deux = pageRenonciation("abc123", 42000, "", { renonciation: true, conditions: CONDITIONS });
  assert.match(deux, /name="conditions"/);
  assert.match(deux, /name="consent"/);
  const avant = pageRenonciation("abc123", 42000, "");
  assert.match(avant, /name="consent"/);
  assert.doesNotMatch(avant, /name="conditions"/);
});

test("les pages légales suivent la charte SECOTO, sans mention de brouillon", () => {
  for (const f of ["public/cgu.html", "public/conditions-transporteur.html", "public/politique-confidentialite.html"]) {
    const html = lire(f);
    assert.match(html, /\/legal\/legal\.css/, `${f}: feuille de style SECOTO absente`);
    assert.match(html, /SIREN 951 857 531/, `${f}: identification de l'éditeur absente`);
    assert.match(html, /APE 8299Z/, `${f}: code APE absent`);
    assert.doesNotMatch(html, /PROJET|à valider|\[À/i, `${f}: mention de brouillon visible`);
  }
  // Tant que l'avocat n'a pas validé, CGU et conditions transporteur restent hors des moteurs.
  for (const f of ["public/cgu.html", "public/conditions-transporteur.html"]) {
    assert.match(lire(f), /noindex/);
  }
  assert.match(lire("public/politique-confidentialite.html"), /id="suppression-compte"/);
});
