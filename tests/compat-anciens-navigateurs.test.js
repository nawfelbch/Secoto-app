import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";

async function source(path) {
  return readFile(new URL(path, import.meta.url), "utf8");
}

// 24/11/2026 : des clients recevaient le lien par SMS et voyaient une page blanche
// (vieux iPhone / vieil Android : syntaxe `??=` du bundle Vite 8 non comprise).
test("le build produit aussi une version pour les anciens navigateurs (iOS 12, Chrome 64)", async () => {
  const config = await source("../vite.config.js");
  assert.match(config, /import legacy from '@vitejs\/plugin-legacy'/);
  assert.match(config, /legacy\(\{ targets: NAVIGATEURS_ANCIENS/);
  assert.match(config, /'iOS >= 12'/);
  assert.match(config, /'Chrome >= 64'/);
  const pkg = JSON.parse(await source("../package.json"));
  assert.ok(pkg.devDependencies["@vitejs/plugin-legacy"], "plugin-legacy installé");
  assert.ok(pkg.devDependencies.terser, "terser (requis par plugin-legacy) installé");
});

test("l'aperçu du lien (Open Graph) n'annonce plus « Remboursé si personne n'accepte »", async () => {
  const html = await source("../index.html");
  assert.match(html, /og:image" content="https:\/\/app\.secoto-transport\.fr\/og-secoto\.jpg\?v=2"/);
  assert.match(html, /0 € à la réservation/);
  assert.doesNotMatch(html, /Rembours[ée] si personne/);
});
