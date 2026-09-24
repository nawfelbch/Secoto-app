// Signature des fichiers privés à la demande (correctif 042).
// L'espace admin signait chaque document et chaque photo au chargement :
// jusqu'à 400 requêtes en rafale, refusées par Supabase (429), ce qui faisait
// échouer les actions lancées ensuite par l'administrateur.
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const APP = readFileSync(new URL("../src/App.jsx", import.meta.url), "utf8");
const LIB = readFileSync(new URL("../src/lib/privateFiles.js", import.meta.url), "utf8");
const VIGNETTE = readFileSync(new URL("../src/PhotoPrivee.jsx", import.meta.url), "utf8");

test("plus aucune signature en masse au chargement", () => {
  assert.doesNotMatch(APP, /hydrateSignedFileUrls/);
  const fonction = APP.slice(APP.indexOf("function signDocuments"), APP.indexOf("function fetchTrackingEvents"));
  assert.doesNotMatch(fonction, /createShortSignedUrl/);
});

test("les vignettes signent elles-mêmes, une fois affichées", () => {
  assert.match(VIGNETTE, /signedUrlCached\(bucket, photo\.filePath\)/);
  assert.match(VIGNETTE, /useEffect/);
  // Le composant démonté ne met plus à jour son état.
  assert.match(VIGNETTE, /vivant = false/);
});

test("au plus quatre signatures simultanées", () => {
  assert.match(LIB, /MAX_PARALLELE = 4/);
  assert.match(LIB, /if \(enCours >= MAX_PARALLELE\) return/);
});

test("une URL signée est réutilisée jusqu'à son expiration", () => {
  assert.match(LIB, /connue\.expireA > Date\.now\(\) \+ MARGE_EXPIRATION_MS/);
  // Un fichier absent n'est pas redemandé en boucle.
  assert.match(LIB, /expireA: Date\.now\(\) \+ 10 \* 60 \* 1000/);
});

test("un document s'ouvre toujours par une URL signée à la demande", () => {
  assert.match(APP, /async function openPrivateDocument/);
  assert.match(APP, /createShortSignedUrl\(bucket, doc\.filePath, 120\)/);
});
