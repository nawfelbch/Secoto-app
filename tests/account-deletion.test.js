import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";

import { bearerToken } from "../netlify/functions/request-account-deletion.js";

test("la suppression exige un Bearer strict et refuse les variantes ambiguës", () => {
  assert.equal(bearerToken({ authorization: "Bearer header.payload.signature" }), "header.payload.signature");
  assert.equal(bearerToken({ authorization: "Basic abc" }), null);
  assert.equal(bearerToken({ authorization: "Bearer " }), null);
  assert.equal(bearerToken({}), null);
});

test("la fonction supprime les objets uniquement via l'API Storage", async () => {
  const source = await readFile(
    new URL("../netlify/functions/request-account-deletion.js", import.meta.url),
    "utf8",
  );
  assert.equal(source.includes(".storage.from(bucket).remove("), true);
  assert.equal(source.includes('from("storage.objects")'), false);
  assert.equal(source.includes("DELETE FROM storage.objects"), false);
});

test("l'identité Auth est soft-delete après anonymisation de la base", async () => {
  const source = await readFile(
    new URL("../netlify/functions/request-account-deletion.js", import.meta.url),
    "utf8",
  );
  const anonymize = source.indexOf('"secoto_finalize_account_deletion"');
  const authDelete = source.indexOf("deleteUser(user.id, true)");
  assert.ok(anonymize > 0);
  assert.ok(authDelete > anonymize);
});
