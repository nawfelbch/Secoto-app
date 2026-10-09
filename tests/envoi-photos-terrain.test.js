import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import { EVIDENCE_COMPRESSION, compressEvidenceImage, dimensionsReduites } from "../src/lib/fileSafety.js";

const lire = (f) => readFileSync(new URL(`../${f}`, import.meta.url), "utf8");

test("photos de preuve : une photo d'iPhone est ramenée à 1600 px de côté", () => {
  assert.deepEqual(dimensionsReduites(4032, 3024), { scale: 1600 / 4032, width: 1600, height: 1200 });
  assert.deepEqual(dimensionsReduites(3024, 4032), { scale: 1600 / 4032, width: 1200, height: 1600 });
  assert.deepEqual(dimensionsReduites(800, 600), { scale: 1, width: 800, height: 600 });
  assert.equal(EVIDENCE_COMPRESSION.maxDimension, 1600);
});

test("photos de preuve : si createImageBitmap échoue (iPhone), on passe par <img> et toDataURL", () => {
  const src = lire("src/lib/fileSafety.js");
  assert.match(src, /new Image\(\)/);
  assert.match(src, /URL\.createObjectURL\(file\)/);
  assert.match(src, /canvas\.toDataURL\("image\/jpeg", quality\)/);
  // La compression ne dépend plus de createImageBitmap pour démarrer.
  assert.doesNotMatch(src, /typeof createImageBitmap === "function";\s*\}/);
});

test("photos de preuve : sans navigateur, la photo d'origine est rendue, jamais perdue", async () => {
  const f = new File([new Uint8Array([1, 2, 3])], "image.jpg", { type: "image/jpeg" });
  assert.equal(await compressEvidenceImage(f), f);
  const pdf = new File([new Uint8Array([1])], "pv.pdf", { type: "application/pdf" });
  assert.equal(await compressEvidenceImage(pdf), pdf);
});

// Exécute la vraie fonction uploadOnce (extraite du fichier) avec un faux réseau.
function chargerUploadOnce() {
  const src = lire("src/lib/privateFiles.js").replace(/\r\n/g, "\n");
  const corps = src.slice(src.indexOf("function uploadOnce("), src.indexOf("export async function uploadPrivateFile("));
  return (XMLHttpRequest) => new Function(
    "XMLHttpRequest", "encodeStoragePath", "supabaseAnonKey", "UPLOAD_MAX_MS", "DOMException",
    `${corps}; return uploadOnce;`,
  )(XMLHttpRequest, () => "https://x/storage", "anon", 6 * 60_000, globalThis.DOMException);
}
function fauxReseau(scenario) {
  return class {
    constructor() { this.upload = {}; this.status = 0; }
    open() {}
    setRequestHeader() {}
    abort() { this.onabort?.(); }
    send() { scenario(this); }
  };
}

test("envoi lent mais qui avance : il n'est plus coupé", async () => {
  const uploadOnce = chargerUploadOnce()(fauxReseau((xhr) => {
    let n = 0;
    const tic = setInterval(() => {
      n += 1;
      xhr.upload.onprogress({ lengthComputable: true, loaded: n, total: 6 });
      if (n === 6) { clearInterval(tic); xhr.status = 200; xhr.onload(); }
    }, 20);
  }));
  // Délai d'inactivité 50 ms, envoi total 120 ms : l'ancien délai global l'aurait coupé.
  const r = await uploadOnce({ bucket: "b", path: "p", file: { type: "image/jpeg" }, accessToken: "t", timeoutMs: 50 });
  assert.deepEqual(r, { duplicate: false });
});

test("réseau perdu (plus aucun progrès) : arrêt propre avec un message clair", async () => {
  const uploadOnce = chargerUploadOnce()(fauxReseau(() => {}));
  await assert.rejects(
    uploadOnce({ bucket: "b", path: "p", file: { type: "image/jpeg" }, accessToken: "t", timeoutMs: 30 }),
    (e) => e.timeout === true && /vos photos sont gardées/.test(e.message),
  );
});

test("annulation par le transporteur : reconnue comme annulation, pas comme panne", async () => {
  const ctrl = new AbortController();
  const uploadOnce = chargerUploadOnce()(fauxReseau(() => setTimeout(() => ctrl.abort(), 10)));
  await assert.rejects(
    uploadOnce({ bucket: "b", path: "p", file: { type: "image/jpeg" }, accessToken: "t", timeoutMs: 1000, signal: ctrl.signal }),
    (e) => e.name === "AbortError",
  );
});
