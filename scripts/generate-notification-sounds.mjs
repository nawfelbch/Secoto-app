// ============================================================================
// SECOTO — génération du son de notification « caisse enregistreuse ».
// ----------------------------------------------------------------------------
// Le fichier est SYNTHÉTISÉ ici plutôt que téléchargé : aucune licence tierce
// à tracer, aucun binaire opaque dans le dépôt, et le résultat est strictement
// reproductible (générateur de bruit à graine fixe, aucune source d'aléa).
//
// Contraintes des deux plateformes, respectées par construction :
//   • iOS / APNs : WAV PCM linéaire, 30 secondes maximum, présent dans le
//     bundle de l'application (référencé dans project.pbxproj).
//   • Android / FCM : fichier dans res/raw, nom en minuscules, chiffres et
//     underscores uniquement, référencé SANS extension par le canal.
//
// Régénérer :  npm run sounds
// ============================================================================

import { mkdirSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const SAMPLE_RATE = 44_100;

/** Bruit déterministe : même graine, même fichier, à jamais. */
function seededNoise(seed = 0x5ec070) {
  let state = seed >>> 0;
  return () => {
    state = (Math.imul(state, 1_664_525) + 1_013_904_223) >>> 0;
    return (state / 0xffffffff) * 2 - 1;
  };
}

/**
 * Timbre de cloche de tiroir-caisse : partiels INHARMONIQUES (2.76, 5.40…),
 * ce qui distingue une cloche métallique d'une simple note de synthétiseur.
 */
function addBell(samples, startSeconds, frequency, gain, decaySeconds) {
  const start = Math.floor(startSeconds * SAMPLE_RATE);
  const partials = [
    [1.0, 1.0],
    [2.76, 0.52],
    [5.4, 0.28],
    [8.93, 0.12],
  ];
  const length = Math.min(
    Math.floor(decaySeconds * 7 * SAMPLE_RATE),
    samples.length - start,
  );
  for (let index = 0; index < length; index += 1) {
    const time = index / SAMPLE_RATE;
    // Attaque quasi instantanée (frappe du marteau) puis décroissance longue.
    const envelope = (1 - Math.exp(-time * 420)) * Math.exp(-time / decaySeconds);
    let value = 0;
    for (const [ratio, weight] of partials) {
      // Les partiels aigus s'éteignent plus vite : c'est ce qui donne
      // le « ting » qui s'adoucit plutôt qu'un bourdon métallique.
      value += weight * Math.exp(-time * ratio * 1.6) * Math.sin(2 * Math.PI * frequency * ratio * time);
    }
    samples[start + index] += gain * envelope * value;
  }
}

/** Déclic mécanique de la touche enfoncée. */
function addClick(samples, startSeconds, gain, durationSeconds, noise) {
  const start = Math.floor(startSeconds * SAMPLE_RATE);
  const length = Math.min(Math.floor(durationSeconds * SAMPLE_RATE), samples.length - start);
  for (let index = 0; index < length; index += 1) {
    const time = index / SAMPLE_RATE;
    const envelope = Math.exp(-time * 60);
    const body = 0.6 * noise() + 0.4 * Math.sin(2 * Math.PI * 190 * time);
    samples[start + index] += gain * envelope * body;
  }
}

/** Glissement du tiroir qui s'ouvre : bruit filtré, montée puis descente. */
function addDrawerSlide(samples, startSeconds, gain, durationSeconds, noise) {
  const start = Math.floor(startSeconds * SAMPLE_RATE);
  const length = Math.min(Math.floor(durationSeconds * SAMPLE_RATE), samples.length - start);
  let lowpass = 0;
  for (let index = 0; index < length; index += 1) {
    const progress = index / length;
    // Passe-bas à un pôle : le frottement est sourd, jamais sifflant.
    lowpass += 0.06 * (noise() - lowpass);
    const envelope = Math.sin(Math.PI * progress) ** 1.5;
    samples[start + index] += gain * envelope * lowpass * 6;
  }
}

/** Butée du tiroir en fin de course. */
function addThud(samples, startSeconds, gain, decaySeconds) {
  const start = Math.floor(startSeconds * SAMPLE_RATE);
  const length = Math.min(Math.floor(decaySeconds * 6 * SAMPLE_RATE), samples.length - start);
  for (let index = 0; index < length; index += 1) {
    const time = index / SAMPLE_RATE;
    const envelope = Math.exp(-time / decaySeconds);
    // Petite descente de hauteur : la masse qui vient buter.
    const frequency = 96 * Math.exp(-time * 9) + 58;
    samples[start + index] += gain * envelope * Math.sin(2 * Math.PI * frequency * time);
  }
}

function renderSound({ duration, build }) {
  const samples = new Float64Array(Math.ceil(duration * SAMPLE_RATE));
  const noise = seededNoise();
  build({
    bell: (start, frequency, gain, decay) => addBell(samples, start, frequency, gain, decay),
    click: (start, gain, length) => addClick(samples, start, gain, length, noise),
    slide: (start, gain, length) => addDrawerSlide(samples, start, gain, length, noise),
    thud: (start, gain, decay) => addThud(samples, start, gain, decay),
  });

  // Normalisation à -1,7 dBFS : audible sans jamais écrêter, y compris sur les
  // haut-parleurs de téléphone qui saturent bien avant 0 dBFS.
  let peak = 0;
  for (const sample of samples) peak = Math.max(peak, Math.abs(sample));
  const scale = peak > 0 ? 0.82 / peak : 1;

  const fadeSamples = Math.floor(SAMPLE_RATE * 0.06);
  const pcm = new Int16Array(samples.length);
  for (let index = 0; index < samples.length; index += 1) {
    // Fondu final : sans lui, la coupure nette produit un « clac » parasite.
    const remaining = samples.length - index;
    const fade = remaining < fadeSamples ? remaining / fadeSamples : 1;
    const value = Math.max(-1, Math.min(1, samples[index] * scale * fade));
    pcm[index] = Math.round(value * 32_767);
  }
  return pcm;
}

function wavBuffer(samples) {
  const dataBytes = samples.length * 2;
  const buffer = Buffer.alloc(44 + dataBytes);
  buffer.write("RIFF", 0);
  buffer.writeUInt32LE(36 + dataBytes, 4);
  buffer.write("WAVE", 8);
  buffer.write("fmt ", 12);
  buffer.writeUInt32LE(16, 16);
  buffer.writeUInt16LE(1, 20);           // PCM linéaire — exigé par APNs
  buffer.writeUInt16LE(1, 22);           // mono
  buffer.writeUInt32LE(SAMPLE_RATE, 24);
  buffer.writeUInt32LE(SAMPLE_RATE * 2, 28);
  buffer.writeUInt16LE(2, 32);
  buffer.writeUInt16LE(16, 34);          // 16 bits
  buffer.write("data", 36);
  buffer.writeUInt32LE(dataBytes, 40);
  for (let index = 0; index < samples.length; index += 1) {
    buffer.writeInt16LE(samples[index], 44 + index * 2);
  }
  return buffer;
}

// « Cha-ching » : touche enfoncée, double coup de cloche, tiroir qui sort et bute.
const CASH_REGISTER = renderSound({
  duration: 1.2,
  build: ({ bell, click, slide, thud }) => {
    click(0.0, 0.55, 0.09);
    bell(0.035, 1_046, 0.95, 0.26);   // « cha »
    bell(0.165, 1_318, 0.88, 0.34);   // « ching »
    slide(0.3, 0.42, 0.34);
    thud(0.63, 0.5, 0.1);
    bell(0.66, 1_318, 0.2, 0.3);      // résonance résiduelle de la cloche
  },
});

export const SOUNDS = { "secoto_cash_register.wav": CASH_REGISTER };

const DESTINATIONS = [
  resolve(ROOT, "ios/App/App"),
  resolve(ROOT, "android/app/src/main/res/raw"),
];

for (const directory of DESTINATIONS) {
  mkdirSync(directory, { recursive: true });
  for (const [name, samples] of Object.entries(SOUNDS)) {
    writeFileSync(resolve(directory, name), wavBuffer(samples));
  }
}

const seconds = (CASH_REGISTER.length / SAMPLE_RATE).toFixed(2);
console.log(`SECOTO — son de caisse généré (${seconds} s, PCM 16 bits mono ${SAMPLE_RATE} Hz) pour iOS et Android.`);
