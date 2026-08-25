import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { humanizeError } from "../src/lib/humanError.js";

const app = readFileSync(new URL("../src/App.jsx", import.meta.url), "utf8");
const payments = readFileSync(new URL("../src/lib/payments.js", import.meta.url), "utf8");
const migration = readFileSync(
  new URL("../supabase/migrations/202608250015_reliability_guards.sql", import.meta.url),
  "utf8",
);

test("les erreurs PostgREST de cache de schéma ne sont jamais affichées brutes", () => {
  const raw = {
    code: "PGRST202",
    message:
      "Could not find the function public.secoto_apply_to_mission(p_idempotency_key, p_message, p_mission_id, p_proposed_price) in the schema cache",
  };
  const shown = humanizeError(raw, "Erreur lors de la candidature.");
  assert.doesNotMatch(shown, /schema cache|secoto_apply_to_mission/i);
  assert.match(shown, /mise à jour|Réessayez/);
});

test("l'ambiguïté de surcharge est masquée elle aussi", () => {
  const raw = {
    code: "PGRST203",
    message:
      "Could not choose the best candidate function between: public.secoto_apply_to_mission(...), public.secoto_apply_to_mission(...)",
  };
  const shown = humanizeError(raw, "Erreur lors de la candidature.");
  assert.doesNotMatch(shown, /candidate function|public\./i);
});

test("les messages métier français (raise exception P0001) passent tels quels", () => {
  assert.equal(
    humanizeError({ code: "P0001", message: "Le devis doit être signé avant le paiement." }),
    "Le devis doit être signé avant le paiement.",
  );
  assert.equal(
    humanizeError({ code: "23505", message: "Vous avez déjà candidaté à cette mission." }),
    "Vous avez déjà candidaté à cette mission.",
  );
});

test("les erreurs locales de saisie restent affichées", () => {
  assert.equal(
    humanizeError(new Error("Renseignez la disponibilité d’enlèvement au plus tôt.")),
    "Renseignez la disponibilité d’enlèvement au plus tôt.",
  );
});

test("le réseau coupé donne un message réseau, pas un « Failed to fetch »", () => {
  const shown = humanizeError(new TypeError("Failed to fetch"), "Erreur lors de la candidature.");
  assert.match(shown, /réseau/i);
  assert.doesNotMatch(shown, /fetch/i);
});

test("les erreurs Supabase Auth sont traduites", () => {
  assert.equal(
    humanizeError({ message: "Invalid login credentials" }),
    "E-mail ou mot de passe incorrect.",
  );
});

test("un doublon SQL devient un message d'action déjà enregistrée", () => {
  const shown = humanizeError({
    code: "23505",
    message: 'duplicate key value violates unique constraint "mission_applications_unique"',
  });
  assert.equal(shown, "Cette action a déjà été enregistrée.");
});

test("erreur inconnue ou anglaise : repli sur le message de l'écran", () => {
  assert.equal(
    humanizeError({ message: "some obscure internal thing" }, "Erreur lors de la candidature."),
    "Erreur lors de la candidature.",
  );
});

test("l'application ne montre plus aucun message brut : tous les setError passent par humanizeError", () => {
  assert.doesNotMatch(app, /setError\((?:err|e|error|accessError|resetError|updateError|exchangeError|platformError|claimError)\.message/);
  assert.doesNotMatch(app, /setClaimError\(\s*claimFailure\.message/);
  assert.match(app, /import \{ humanizeError \} from "\.\/lib\/humanError"/);
  assert.match(payments, /humanizeError\(/);
});

test("la migration 015 supprime toutes les surcharges puis n'en recrée qu'une", () => {
  assert.match(migration, /drop function %s/);
  assert.match(migration, /create or replace function public\.secoto_apply_to_mission\(/);
  assert.match(migration, /having count\(\*\) > 1/);
  assert.match(migration, /notify pgrst, 'reload schema'/);
});

test("la migration 015 rend l'encaissement définitif face aux webhooks en désordre", () => {
  assert.match(migration, /paid_is_final/);
  assert.match(migration, /p_status <> 'refunded'/);
});
