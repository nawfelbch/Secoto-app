import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const sw = readFileSync(new URL("../public/sw.js", import.meta.url), "utf8");

test("le corps de la réponse est cloné AVANT toute attente asynchrone", () => {
  // Régression : `cache.put(request, response.clone())` était évalué dans le
  // `.then()` de `caches.open()`. Le clone arrivait donc après que le
  // navigateur eut commencé à lire la réponse → TypeError à chaque chargement.
  assert.doesNotMatch(sw, /caches\.open\([^)]*\)\s*\.then\(\([^)]*\)\s*=>\s*cache\.put\([^)]*\.clone\(\)/);
  assert.doesNotMatch(sw, /cache\.put\([^)]*,\s*response\.clone\(\)\)/);
  // Deux stratégies de cache, deux clones synchrones.
  assert.equal((sw.match(/const copy = response\.clone\(\);/g) || []).length, 2);
});

test("aucune écriture de cache ne peut produire de rejet non capturé", () => {
  const opens = sw.match(/caches\.open\(CACHE\)[\s\S]*?;/g) || [];
  const putters = opens.filter((block) => block.includes("cache.put"));
  assert.equal(putters.length, 2);
  for (const block of putters) assert.match(block, /\.catch\(\(\) => \{\}\)/);
});

test("le cache de shell est versionné pour purger l'ancien service worker", () => {
  assert.match(sw, /const CACHE = "secoto-shell-v4";/);
  assert.match(sw, /keys\.filter\(\(key\) => key\.startsWith\("secoto-shell-"\) && key !== CACHE\)/);
});

test("les appels aux fonctions serveur ne sont jamais mis en cache", () => {
  assert.match(sw, /url\.pathname\.startsWith\("\/\.netlify\/functions\/"\)\) return;/);
  assert.match(sw, /if \(request\.method !== "GET"\) return;/);
});
