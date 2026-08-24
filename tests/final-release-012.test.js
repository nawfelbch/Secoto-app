import assert from "node:assert/strict";
import test from "node:test";
import {
  LEGAL_COPY,
  currentLegalCopy,
  containsMojibake,
} from "../src/lib/legalCopy.js";

test("les marqueurs classiques d’un UTF-8 mal décodé sont détectés", () => {
  assert.equal(containsMojibake("Ce montant règle la mise en relation."), false);
  assert.equal(containsMojibake("Ce montant rÃ¨gle la mise en relation."), true);
  assert.equal(containsMojibake("nâ€™est pas déduit"), true);
});

test("un texte distant corrompu est remplacé par la copie UTF-8 embarquée", () => {
  const copy = currentLegalCopy({
    version: "2026-08-25",
    commission_notice: "Ce montant rÃ¨gle la mise en relation.",
    transport_notice: "Texte distant valide.",
  });

  assert.equal(copy.commission_notice, LEGAL_COPY.commission_notice);
  assert.equal(copy.transport_notice, "Texte distant valide.");
});
