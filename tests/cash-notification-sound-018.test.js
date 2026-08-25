import test from "node:test";
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFileSync, statSync } from "node:fs";
import {
  isCashEvent,
  nativeNotificationPresentation,
  CASH_CHANNEL_ID,
  CASH_SOUND_FILE,
  DEFAULT_CHANNEL_ID,
} from "../netlify/functions/send-mission-notifications.js";

const push = readFileSync(new URL("../src/push.js", import.meta.url), "utf8");
const panel = readFileSync(
  new URL("../src/NotificationPreferencesPanel.jsx", import.meta.url),
  "utf8",
);
const migration = readFileSync(
  new URL("../supabase/migrations/202608260018_cash_notification_sound.sql", import.meta.url),
  "utf8",
);
const ci = readFileSync(new URL("../codemagic.yaml", import.meta.url), "utf8");
const provenance = readFileSync(
  new URL("../assets/notification-sound/PROVENANCE.md", import.meta.url),
  "utf8",
);

// Empreinte de l'enregistrement livré. Elle est répétée dans PROVENANCE.md et
// dans codemagic.yaml : remplacer le son sans mettre à jour les trois endroits
// — et sans incrémenter le canal Android — fait échouer ces tests.
const SOUND_SHA256 = "766a7f3c4d14f9d3c1fa9aff3ffde9864dd7ea3d14f364650c9957e5d8816042";
const pbxproj = readFileSync(
  new URL("../ios/App/App.xcodeproj/project.pbxproj", import.meta.url),
  "utf8",
);

const IOS_SOUND = new URL("../ios/App/App/secoto_cash_register.wav", import.meta.url);
const ANDROID_SOUND = new URL(
  "../android/app/src/main/res/raw/secoto_cash_register.wav",
  import.meta.url,
);

function readWavHeader(url) {
  const buffer = readFileSync(url);
  return {
    riff: buffer.toString("ascii", 0, 4),
    wave: buffer.toString("ascii", 8, 12),
    format: buffer.readUInt16LE(20),
    channels: buffer.readUInt16LE(22),
    sampleRate: buffer.readUInt32LE(24),
    bitsPerSample: buffer.readUInt16LE(34),
    dataBytes: buffer.readUInt32LE(40),
    buffer,
  };
}

/* -------------------------------------------------------------------------- */
/* Choix du son côté serveur                                                   */
/* -------------------------------------------------------------------------- */

test("le transporteur entend la caisse sur les événements qui rapportent", () => {
  for (const type of ["new_course", "course_assigned", "payment"]) {
    const presentation = nativeNotificationPresentation({ type, audience: "transporter" });
    assert.equal(presentation.iosSound, CASH_SOUND_FILE);
    assert.equal(presentation.androidSound, "secoto_cash_register");
    assert.equal(presentation.androidChannelId, CASH_CHANNEL_ID);
  }
});

test("l'admin entend la caisse sur les paiements et les nouvelles demandes", () => {
  for (const type of ["payment", "new_request"]) {
    const presentation = nativeNotificationPresentation({ type, audience: "admin" });
    assert.equal(presentation.iosSound, CASH_SOUND_FILE);
    assert.equal(presentation.androidChannelId, CASH_CHANNEL_ID);
  }
});

test("tout le reste garde le son standard", () => {
  const ordinary = [
    { type: "document", audience: "transporter" },
    { type: "tracking", audience: "transporter" },
    { type: "frais", audience: "transporter" },
    { type: "new_account", audience: "admin" },
    { type: "new_application", audience: "admin" },
    // Un client n'encaisse rien : même un paiement garde le son standard.
    { type: "payment", audience: "client" },
    { type: "new_course", audience: "client" },
  ];
  for (const notification of ordinary) {
    const presentation = nativeNotificationPresentation(notification);
    assert.equal(presentation.iosSound, "default", JSON.stringify(notification));
    assert.equal(presentation.androidChannelId, DEFAULT_CHANNEL_ID);
  }
});

test("la préférence du destinataire coupe le son de caisse", () => {
  const notification = { type: "new_course", audience: "transporter" };
  const off = nativeNotificationPresentation(notification, { cash_sound_enabled: false });
  assert.equal(off.iosSound, "default");
  assert.equal(off.androidChannelId, DEFAULT_CHANNEL_ID);

  // Préférence absente (compte n'ayant jamais ouvert l'écran) ou lecture en
  // échec : on retombe sur le défaut, qui est actif.
  for (const prefs of [null, undefined, {}]) {
    assert.equal(nativeNotificationPresentation(notification, prefs).iosSound, CASH_SOUND_FILE);
  }
});

test("isCashEvent ne se laisse pas piéger par une notification incomplète", () => {
  for (const notification of [{}, { type: "payment" }, { audience: "admin" }, { type: null, audience: null }]) {
    assert.equal(isCashEvent(notification), false);
  }
});

/* -------------------------------------------------------------------------- */
/* Fichiers audio                                                              */
/* -------------------------------------------------------------------------- */

test("le WAV respecte les contraintes APNs et Android", () => {
  for (const url of [IOS_SOUND, ANDROID_SOUND]) {
    const header = readWavHeader(url);
    assert.equal(header.riff, "RIFF");
    assert.equal(header.wave, "WAVE");
    assert.equal(header.format, 1, "APNs exige du PCM linéaire non compressé");
    assert.equal(header.channels, 1);
    assert.equal(header.sampleRate, 44_100);
    assert.equal(header.bitsPerSample, 16);
    const seconds = header.dataBytes / (header.sampleRate * 2);
    assert.ok(seconds > 0.5 && seconds <= 30, `durée hors limites APNs : ${seconds}s`);
  }
});

test("les deux plateformes reçoivent exactement le même fichier", () => {
  assert.deepEqual(readFileSync(IOS_SOUND), readFileSync(ANDROID_SOUND));
  assert.equal(statSync(IOS_SOUND).size, statSync(ANDROID_SOUND).size);
});

test("le son n'est ni silencieux ni écrêté", () => {
  const { buffer, dataBytes } = readWavHeader(IOS_SOUND);
  let peak = 0;
  let sumSquares = 0;
  const count = dataBytes / 2;
  for (let index = 0; index < count; index += 1) {
    const value = buffer.readInt16LE(44 + index * 2) / 32_768;
    peak = Math.max(peak, Math.abs(value));
    sumSquares += value * value;
  }
  const rms = Math.sqrt(sumSquares / count);
  assert.ok(peak > 0.5, `son trop faible (pic ${peak.toFixed(3)})`);
  assert.ok(peak < 0.99, `son écrêté (pic ${peak.toFixed(3)})`);
  assert.ok(rms > 0.02, `son quasi silencieux (RMS ${rms.toFixed(4)})`);
});

test("l'enregistrement livré est exactement celui décrit par la provenance", () => {
  for (const url of [IOS_SOUND, ANDROID_SOUND]) {
    const digest = createHash("sha256").update(readFileSync(url)).digest("hex");
    assert.equal(digest, SOUND_SHA256);
  }
  assert.ok(
    provenance.includes(SOUND_SHA256),
    "PROVENANCE.md ne décrit plus le fichier réellement livré",
  );
});

test("la source et sa licence restent traçables", () => {
  // L'application est distribuée sur l'App Store et Google Play : la licence
  // du son doit autoriser l'usage commercial, et rester vérifiable.
  const source = readFileSync(
    new URL("../assets/notification-sound/source-cash-register-kaching.mp3", import.meta.url),
  );
  assert.ok(source.length > 1000, "le fichier source doit rester versionné");
  assert.match(provenance, /Licence/);
  assert.match(provenance, /commercial/i);
});

test("la marche à suivre pour changer de son rappelle le canal Android", () => {
  // Piège coûteux : remplacer le WAV sans changer d'identifiant de canal
  // n'a aucun effet sur les téléphones déjà installés.
  const howto = provenance.slice(provenance.indexOf("Remplacer le son"));
  assert.match(howto, /secoto-cash-register-v2/);
  assert.match(howto, /immuable/);
});

/* -------------------------------------------------------------------------- */
/* Intégration native                                                          */
/* -------------------------------------------------------------------------- */

test("le canal Android du son de caisse est distinct et versionné", () => {
  // Un canal Android est immuable : le son NE PEUT PAS être ajouté au canal
  // historique, il lui faut un identifiant neuf.
  assert.match(push, /CASH_CHANNEL_ID = "secoto-cash-register-v1"/);
  assert.notEqual(CASH_CHANNEL_ID, DEFAULT_CHANNEL_ID);
  // Android référence le fichier de res/raw sans extension.
  assert.match(push, /sound: CASH_SOUND_FILE\.replace\(\/\\\.wav\$\/, ""\)/);
});

test("les canaux sont recréés au démarrage pour les inscrits d'avant la mise à jour", () => {
  const listeners = push.slice(push.indexOf("export async function initializePushListeners"));
  assert.match(listeners, /ensureNativeNotificationChannels\(PushNotifications\)/);
});

test("le WAV est déclaré dans le bundle iOS", () => {
  assert.match(pbxproj, /secoto_cash_register\.wav in Resources/);
  assert.match(pbxproj, /lastKnownFileType = audio\.wav; path = secoto_cash_register\.wav/);
});

/* -------------------------------------------------------------------------- */
/* Réglage utilisateur et base                                                 */
/* -------------------------------------------------------------------------- */

test("l'option n'est proposée qu'aux rôles qui encaissent", () => {
  assert.match(panel, /CASH_SOUND_ROLES = new Set\(\["transporter", "admin"\]\)/);
  assert.match(panel, /CASH_SOUND_ROLES\.has\(account\.role\)/);
  assert.match(panel, /p_cash_sound_enabled: next\.cash_sound_enabled/);
  assert.match(panel, /cash_sound_enabled: true/);
});

test("la migration ajoute le paramètre EN DERNIER et supprime l'ancienne signature", () => {
  // C'est exactement le piège qui a bloqué les candidatures le 25/08 : deux
  // signatures d'une même fonction, que PostgREST ne sait pas départager.
  assert.match(migration, /drop function if exists public\.secoto_update_notification_preferences\(\s*boolean, boolean, boolean, boolean, boolean\s*\)/);
  const signature = migration.slice(
    migration.indexOf("create or replace function public.secoto_update_notification_preferences"),
    migration.indexOf("returns public.notification_preferences"),
  );
  const params = [...signature.matchAll(/p_[a-z_]+/g)].map((match) => match[0]);
  assert.equal(params.at(-1), "p_cash_sound_enabled");
  assert.match(signature, /p_cash_sound_enabled boolean default true/);
  assert.match(migration, /add column if not exists cash_sound_enabled boolean not null default true/);
  assert.match(migration, /notify pgrst, 'reload schema'/);
});

test("le CI vérifie l'empreinte du son sur les deux plateformes", () => {
  assert.ok(
    (ci.match(new RegExp(SOUND_SHA256, "g")) || []).length >= 2,
    "l'empreinte doit être contrôlée dans les deux workflows",
  );
  assert.match(ci, /grep -q "secoto_cash_register\.wav in Resources"/);
  // Les deux plateformes doivent recevoir le même octet.
  assert.match(ci, /cmp ios\/App\/App\/secoto_cash_register\.wav/);
});

test("les commandes du CI existent sur les machines de build", () => {
  // Les DEUX workflows tournent sur mac_mini_m2. macOS ne fournit pas
  // sha256sum : l'appeler directement ferait échouer le build Android.
  for (const step of ci.matchAll(/check_sha\(\) \{[\s\S]*?\}/g)) {
    assert.match(step[0], /command -v shasum/);
    assert.match(step[0], /shasum -a 256 -c -/);
    assert.match(step[0], /sha256sum -c -/);
  }
  assert.equal([...ci.matchAll(/check_sha\(\) \{/g)].length, 2);
  // Aucune commande sha256sum nue, hors du repli portable.
  assert.doesNotMatch(ci, /\| sha256sum/);
  // python3 n'est pas garanti sur l'image de build : le format du WAV est
  // déjà validé par « npm test », exécuté à l'étape précédente. On interdit
  // l'INVOCATION, pas la mention en commentaire.
  assert.doesNotMatch(ci, /^\s*python3\b/m);
});
