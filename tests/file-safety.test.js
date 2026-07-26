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
