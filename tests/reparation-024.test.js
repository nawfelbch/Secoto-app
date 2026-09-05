// ============================================================================
// SECOTO — non-régression de la migration 024.
//
// Incident du 05/09/2026 : « Could not find the function
// public.secoto_apply_to_mission(p_idempotency_key, p_message, p_mission_id,
// p_proposed_price) in schema cache ». Toute application déjà installée était
// incapable de candidater. Ces tests verrouillent les trois causes.
// ============================================================================

import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";

import {
  buildApplicationRpcPayload,
  countAvailability,
  applyAvailabilityPreset,
  clearAvailability,
  EMPTY_APPLICATION_OFFER,
} from "../src/lib/applicationOffer.js";

const MIGRATIONS_DIR = "supabase/migrations";
const migrationFiles = fs.readdirSync(MIGRATIONS_DIR).filter((f) => f.endsWith(".sql")).sort();
const migration024 = fs.readFileSync(
  path.join(MIGRATIONS_DIR, "202609050024_reparation_candidatures_terrain.sql"),
  "utf8",
);
const appSource = fs.readFileSync("src/App.jsx", "utf8");
const resilienceSource = fs.readFileSync("src/lib/resilienceStore.js", "utf8");
const privateFilesSource = fs.readFileSync("src/lib/privateFiles.js", "utf8");

/* --------------------------------------------------------------------------
   1. La charge utile RPC ne doit JAMAIS être partielle
   -------------------------------------------------------------------------- */

const RPC_KEYS = [
  "p_mission_id",
  "p_proposed_price",
  "p_message",
  "p_idempotency_key",
  "p_pickup_earliest_at",
  "p_pickup_latest_at",
  "p_delivery_earliest_at",
  "p_delivery_latest_at",
  "p_proposed_price_grouped",
];

test("la candidature envoie toujours les neuf arguments, même sans disponibilités", () => {
  const payload = buildApplicationRpcPayload({
    missionId: "11111111-1111-1111-1111-111111111111",
    idempotencyKey: "22222222-2222-2222-2222-222222222222",
    proposedPrice: "850",
    ...clearAvailability(),
    message: "",
  });
  assert.deepEqual(Object.keys(payload).sort(), [...RPC_KEYS].sort());
  assert.equal(payload.p_proposed_price, 850);
  assert.equal(payload.p_pickup_earliest_at, null);
  assert.equal(payload.p_delivery_latest_at, null);
  assert.equal(payload.p_message, null);
});

test("un tarif écrit avec une virgule est accepté", () => {
  const payload = buildApplicationRpcPayload({
    missionId: "m", idempotencyKey: "k", proposedPrice: "850,50",
  });
  assert.equal(payload.p_proposed_price, 850.5);
});

test("des disponibilités incomplètes sont refusées côté application, en français", () => {
  assert.throws(
    () => buildApplicationRpcPayload({
      missionId: "m",
      idempotencyKey: "k",
      proposedPrice: "500",
      pickupEarliestAt: "2026-09-10T08:00",
    }),
    /quatre créneaux/i,
  );
});

test("un tarif manquant est refusé avant l'appel réseau", () => {
  assert.throws(
    () => buildApplicationRpcPayload({ missionId: "m", idempotencyKey: "k", proposedPrice: "" }),
    /tarif/i,
  );
});

test("les créneaux prêts à l'emploi produisent quatre dates cohérentes", () => {
  for (const key of ["asap", "tomorrow", "week"]) {
    const preset = applyAvailabilityPreset(key);
    assert.equal(countAvailability({ ...EMPTY_APPLICATION_OFFER, ...preset }), 4);
    const payload = buildApplicationRpcPayload({
      missionId: "m", idempotencyKey: "k", proposedPrice: "700", ...preset,
    });
    assert.ok(new Date(payload.p_pickup_earliest_at) <= new Date(payload.p_pickup_latest_at));
    assert.ok(new Date(payload.p_delivery_earliest_at) <= new Date(payload.p_delivery_latest_at));
  }
});

/* --------------------------------------------------------------------------
   2. Règle permanente : compatibilité des versions déjà installées
   -------------------------------------------------------------------------- */

function definitionsByFunction() {
  const byName = new Map();
  for (const file of migrationFiles) {
    const sql = fs.readFileSync(path.join(MIGRATIONS_DIR, file), "utf8");
    const pattern = /create\s+or\s+replace\s+function\s+(public\.secoto_[a-z0-9_]+)\s*\(([^)]*)\)/gi;
    let match = pattern.exec(sql);
    while (match) {
      const name = match[1];
      const params = match[2]
        .split(",")
        .map((p) => p.trim())
        .filter(Boolean);
      if (!byName.has(name)) byName.set(name, []);
      byName.get(name).push({ file, params });
      match = pattern.exec(sql);
    }
  }
  return byName;
}

test("tout paramètre ajouté après la première mise en production porte un DEFAULT", () => {
  // C'est LA règle violée le 25/08 puis le 05/09 : une application installée
  // continue d'envoyer l'ancien jeu d'arguments. Sans DEFAULT, PostgREST ne
  // trouve plus la fonction et l'écran devient inutilisable, sans recours.
  for (const [name, definitions] of definitionsByFunction()) {
    const original = definitions[0].params.length;
    const latest = definitions[definitions.length - 1];
    for (let index = original; index < latest.params.length; index += 1) {
      assert.match(
        latest.params[index].toLowerCase(),
        /\bdefault\b/,
        `${name} : le paramètre « ${latest.params[index]} » (ajouté après la mise en production, `
        + `défini dans ${latest.file}) doit porter un DEFAULT.`,
      );
    }
  }
});

test("la migration 024 supprime les surcharges avant de recréer les fonctions exposées", () => {
  for (const name of ["secoto_apply_to_mission", "secoto_update_notification_preferences"]) {
    const dropIndex = migration024.indexOf(`p.proname = '${name}'`);
    const createIndex = migration024.indexOf(`create or replace function public.${name}(`);
    assert.ok(dropIndex > -1, `${name} : la boucle de suppression des surcharges est absente.`);
    assert.ok(createIndex > dropIndex, `${name} : la recréation doit suivre la suppression.`);
  }
  assert.match(migration024, /having count\(\*\) > 1/);
});

test("la migration 024 rend les disponibilités facultatives sans casser leur cohérence", () => {
  assert.match(migration024, /p_pickup_earliest_at timestamptz default null/);
  assert.match(migration024, /p_proposed_price_grouped numeric default null/);
  assert.match(migration024, /v_windows not in \(0, 4\)/);
});

/* --------------------------------------------------------------------------
   3. Le pilotage admin ne doit plus enfermer le terrain
   -------------------------------------------------------------------------- */

test("le pilotage manuel crée une étape cohérente au lieu de bloquer le transporteur", () => {
  const stage = migration024.slice(
    migration024.indexOf("function public.secoto_admin_set_mission_stage"),
    migration024.indexOf("function public.secoto_admin_reopen_field_step"),
  );
  assert.match(stage, /v_needs_pickup/);
  assert.match(stage, /insert into public\.mission_tracking_events/);
  assert.match(stage, /'admin'/);
});

test("SECOTO peut rouvrir une étape sans jamais supprimer une preuve", () => {
  const reopen = migration024.slice(
    migration024.indexOf("function public.secoto_admin_reopen_field_step"),
  );
  assert.match(reopen, /superseded_at\s*=\s*now\(\)/);
  assert.doesNotMatch(reopen, /delete from public\.mission_tracking_events/i);
  assert.doesNotMatch(reopen, /delete from public\.mission_tracking_photos/i);
});

test("la séquence terrain accepte une étape avancée par la direction", () => {
  const finalize = migration024.slice(
    migration024.indexOf("function public.secoto_finalize_tracking_event"),
    migration024.indexOf("function public.secoto_admin_set_mission_stage"),
  );
  assert.match(finalize, /v_pickup_done/);
  assert.match(finalize, /superseded_at is null/);
  // La livraison clôture toujours la mission : comportement métier inchangé.
  assert.match(finalize, /then 'completed' else status end/);
});

test("le dépôt Storage ne dépend plus du seul statut « assigned »", () => {
  assert.match(migration024, /m\.status::text in \('assigned', 'completed'\)/);
});

test("les messages d'erreur terrain sont écrits en français lisible", () => {
  const finalize = migration024.slice(
    migration024.indexOf("function public.secoto_finalize_tracking_event"),
    migration024.indexOf("function public.secoto_admin_set_mission_stage"),
  );
  // Plus aucun message interne sans accents du type « Mission terrain non autorisee ».
  for (const banned of [
    "Mission terrain non autorisee",
    "Prise en charge deja finalisee ou hors sequence",
    "La prise en charge doit etre finalisee en premier",
    "Type d''evenement terrain invalide",
    "Transition terrain incoherente",
  ]) {
    assert.ok(!finalize.includes(banned), `Message technique encore présent : ${banned}`);
  }
});

/* --------------------------------------------------------------------------
   4. Parcours terrain côté application
   -------------------------------------------------------------------------- */

test("les trois formulaires terrain ne sont plus affichés en même temps", () => {
  assert.match(appSource, /function renderFieldActions\(mission\)/);
  const simultaneous = /renderTrackingForm\(mission, "pickup_inspection"\)\s*\}\s*\n\s*\{renderTrackingForm\(mission, "road_incident"\)/;
  assert.doesNotMatch(appSource, simultaneous);
});

test("une étape rouverte par SECOTO redevient disponible pour le transporteur", () => {
  assert.match(appSource, /function hasLiveEvent\(missionId, eventType\)/);
  assert.match(appSource, /!event\.supersededAt/);
});

test("le brouillon chiffré ne réencode plus les photos à chaque frappe", () => {
  // `saveTrackingDraft` ne doit plus voir passer les fichiers.
  const draft = resilienceSource.slice(
    resilienceSource.indexOf("export async function saveTrackingDraft("),
    resilienceSource.indexOf("export async function saveTrackingDraftFiles("),
  );
  assert.match(draft, /delete textOnly\.files/);
  assert.match(resilienceSource, /export async function purgeStaleRecords\(/);
});

test("un envoi ne peut plus rester pendant indéfiniment", () => {
  assert.match(privateFilesSource, /xhr\.timeout = timeoutMs/);
  assert.match(privateFilesSource, /xhr\.ontimeout/);
  assert.match(privateFilesSource, /UPLOAD_TIMEOUT_MS = 45_000/);
  assert.match(appSource, /function cancelTrackingUpload\(/);
});

test("la file d'attente hors ligne abandonne explicitement au lieu de tourner à vide", () => {
  assert.match(appSource, /MAX_QUEUE_ATTEMPTS/);
  assert.match(appSource, /attempts: attempts \+ 1/);
});

test("les vignettes admin ne cassent plus au bout de deux minutes", () => {
  assert.match(privateFilesSource, /SIGNED_URL_DEFAULT_SECONDS = 900/);
});

/* --------------------------------------------------------------------------
   5. Organisation de l'espace administrateur
   -------------------------------------------------------------------------- */

test("l'espace admin s'ouvre sur ce qui est bloqué", () => {
  assert.match(appSource, /useState\("alertes"\)/);
  assert.match(appSource, /secoto_admin_alertes_v1/);
  assert.match(appSource, /label: "À traiter"/);
});

test("la vue des alertes est réservée à l'administrateur", () => {
  const view = migration024.slice(migration024.indexOf("create or replace view public.secoto_admin_alertes_v1"));
  assert.match(view, /where public\.secoto_is_admin\(\)/);
  assert.match(view, /revoke all on table public\.secoto_admin_alertes_v1 from anon/);
});
