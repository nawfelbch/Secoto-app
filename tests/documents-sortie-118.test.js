// SECOTO — fenêtre Documents : impression permise, aucun script, partage dans l'app native.
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const ecran = readFileSync(new URL("../src/DocumentModal.jsx", import.meta.url), "utf8");

test("l'aperçu autorise l'impression mais jamais les scripts", () => {
  assert.match(ecran, /sandbox="allow-modals allow-same-origin"/);
  assert.doesNotMatch(ecran, /sandbox="[^"]*allow-scripts/);
});

test("dans l'app native, imprimer et télécharger passent par la feuille de partage", () => {
  assert.match(ecran, /if \(isNativePlatform\(\)\) \{ partagerFichier\(\); return; \}/g);
  assert.equal((ecran.match(/if \(isNativePlatform\(\)\) \{ partagerFichier\(\); return; \}/g) || []).length, 2);
  assert.match(ecran, /navigator\.canShare\?\.\(\{ files: \[file\] \}\)/);
});
