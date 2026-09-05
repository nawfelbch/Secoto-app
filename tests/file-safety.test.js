import test from "node:test";
import assert from "node:assert/strict";

import {
  buildPrivateFilePath,
  fileExtension,
  safeFileName,
  validateFiles,
} from "../src/lib/fileSafety.js";

function fakeFile(name, type, size = 1024) {
  return { name, type, size };
}

test("la validation exige cohérence MIME, extension, taille et nombre", () => {
  assert.equal(validateFiles([fakeFile("preuve.jpg", "image/jpeg")]).ok, true);
  assert.equal(validateFiles([fakeFile("preuve.pdf", "application/pdf")]).ok, true);
  assert.equal(validateFiles([fakeFile("preuve.exe", "image/jpeg")]).ok, false);
  assert.equal(validateFiles([fakeFile("preuve.jpg", "application/x-msdownload")]).ok, false);
  assert.equal(validateFiles([fakeFile("gros.jpg", "image/jpeg", 13 * 1024 * 1024)]).ok, false);
  assert.equal(validateFiles([], { minFiles: 1 }).ok, false);
});

// Regression 024 : ces trois cas etaient refuses a tort et faisaient croire au
// convoyeur que l'application « n'acceptait pas ses photos ».
test("les photos valides des telephones reels ne sont plus refusees", () => {
  // Galerie Android : nom sans extension.
  assert.equal(validateFiles([fakeFile("IMG_20260905_181200", "image/jpeg")]).ok, true);
  // iPhone : HEIC, transcode en JPEG avant l'envoi.
  assert.equal(validateFiles([fakeFile("IMG_4821.HEIC", "image/heic")]).ok, true);
  // Fichier livre sans type MIME mais avec une extension image.
  assert.equal(validateFiles([fakeFile("etat-des-lieux.jpeg", "")]).ok, true);
  // Un executable annonce en image reste refuse.
  assert.equal(validateFiles([fakeFile("preuve.exe", "image/jpeg")]).ok, false);
});

test("les noms et chemins de stockage restent privés, déterministes et sans traversée", async () => {
  assert.equal(safeFileName("../../Carte grise éà.pdf"), "Carte_grise_ea.pdf");
  assert.equal(fileExtension("PREUVE.JPEG"), "jpeg");
  const path = await buildPrivateFilePath({
    accountId: "account-1",
    missionId: "mission-1",
    operationId: "operation-1",
    index: 2,
    file: fakeFile("../../preuve privée.jpg", "image/jpeg"),
  });
  assert.equal(path, "account-1/mission-1/operation-1/02-preuve_privee.jpg");
  assert.equal(path.includes(".."), false);
});
