const IMAGE_MIME_TYPES = new Set(["image/jpeg", "image/png", "image/webp"]);
const PDF_MIME_TYPES = new Set(["application/pdf"]);
const IMAGE_EXTENSIONS = new Set(["jpg", "jpeg", "png", "webp"]);
const PDF_EXTENSIONS = new Set(["pdf"]);

export const DEFAULT_FILE_LIMITS = Object.freeze({
  maxFiles: 10,
  maxSizeBytes: 12 * 1024 * 1024,
});

export function safeFileName(name) {
  const cleaned = String(name || "fichier")
    .normalize("NFKD")
    .replace(/[\u0300-\u036f]/g, "")
    .replace(/[^a-zA-Z0-9._-]/g, "_")
    .replace(/_+/g, "_")
    .replace(/\.{2,}/g, ".")
    .replace(/^[._-]+/, "")
    .slice(0, 120);
  return cleaned || "fichier";
}

export function fileExtension(name) {
  const clean = String(name || "").toLowerCase();
  const index = clean.lastIndexOf(".");
  return index === -1 ? "" : clean.slice(index + 1);
}

export function isAllowedFile(file, { allowPdf = true } = {}) {
  const extension = fileExtension(file?.name);
  const mime = String(file?.type || "").toLowerCase();
  const isImage = IMAGE_MIME_TYPES.has(mime) && IMAGE_EXTENSIONS.has(extension);
  const isPdf = allowPdf && PDF_MIME_TYPES.has(mime) && PDF_EXTENSIONS.has(extension);
  return isImage || isPdf;
}

export function validateFiles(files, options = {}) {
  const {
    allowPdf = true,
    maxFiles = DEFAULT_FILE_LIMITS.maxFiles,
    maxSizeBytes = DEFAULT_FILE_LIMITS.maxSizeBytes,
    requireImage = false,
    minFiles = 0,
  } = options;
  const list = Array.from(files || []);
  const errors = [];

  if (list.length < minFiles) errors.push(`Ajoutez au moins ${minFiles} fichier${minFiles > 1 ? "s" : ""}.`);
  if (list.length > maxFiles) errors.push(`Maximum ${maxFiles} fichiers par envoi.`);

  for (const file of list) {
    if (!isAllowedFile(file, { allowPdf })) {
      errors.push(`${file?.name || "Fichier"} : format refusé (JPG, PNG, WebP${allowPdf ? " ou PDF" : ""}).`);
    }
    if (!Number.isFinite(file?.size) || file.size <= 0) {
      errors.push(`${file?.name || "Fichier"} : fichier vide ou illisible.`);
    } else if (file.size > maxSizeBytes) {
      errors.push(`${file.name} : taille maximale ${Math.round(maxSizeBytes / 1024 / 1024)} Mo.`);
    }
  }

  if (requireImage && list.length > 0) {
    const hasImage = list.some((file) => IMAGE_MIME_TYPES.has(String(file.type || "").toLowerCase()));
    if (!hasImage) errors.push("Au moins une photo est obligatoire.");
  }

  return { ok: errors.length === 0, errors };
}

export async function compressEvidenceImage(file, {
  maxDimension = 2400,
  quality = 0.88,
  compressionThreshold = 2 * 1024 * 1024,
} = {}) {
  if (!file || !IMAGE_MIME_TYPES.has(file.type) || file.size <= compressionThreshold) return file;
  if (typeof document === "undefined" || typeof createImageBitmap !== "function") return file;

  let bitmap;
  try {
    bitmap = await createImageBitmap(file);
    const scale = Math.min(1, maxDimension / Math.max(bitmap.width, bitmap.height));
    const width = Math.max(1, Math.round(bitmap.width * scale));
    const height = Math.max(1, Math.round(bitmap.height * scale));
    const canvas = document.createElement("canvas");
    canvas.width = width;
    canvas.height = height;
    const context = canvas.getContext("2d", { alpha: file.type === "image/png" });
    context.drawImage(bitmap, 0, 0, width, height);
    const outputType = file.type === "image/png" ? "image/png" : "image/jpeg";
    const blob = await new Promise((resolve) => canvas.toBlob(resolve, outputType, quality));
    if (!blob || blob.size >= file.size) return file;
    const extension = outputType === "image/png" ? "png" : "jpg";
    const baseName = safeFileName(file.name).replace(/\.[^.]+$/, "");
    return new File([blob], `${baseName}.${extension}`, {
      type: outputType,
      lastModified: file.lastModified || Date.now(),
    });
  } catch {
    return file;
  } finally {
    bitmap?.close?.();
  }
}

export function randomIdempotencyKey() {
  if (globalThis.crypto?.randomUUID) return globalThis.crypto.randomUUID();
  const random = globalThis.crypto?.getRandomValues
    ? globalThis.crypto.getRandomValues(new Uint8Array(16))
    : Uint8Array.from({ length: 16 }, () => Math.floor(Math.random() * 256));
  random[6] = (random[6] & 0x0f) | 0x40;
  random[8] = (random[8] & 0x3f) | 0x80;
  const hex = [...random].map((value) => value.toString(16).padStart(2, "0")).join("");
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
}

export async function buildPrivateFilePath({
  accountId,
  missionId = "account",
  operationId,
  index,
  file,
}) {
  const safeAccount = String(accountId || "unknown").replace(/[^a-zA-Z0-9_-]/g, "");
  const safeMission = String(missionId || "account").replace(/[^a-zA-Z0-9_-]/g, "");
  const safeOperation = String(operationId || randomIdempotencyKey()).replace(/[^a-zA-Z0-9_-]/g, "");
  const safeName = safeFileName(file?.name || `preuve-${index}`);
  return `${safeAccount}/${safeMission}/${safeOperation}/${String(index).padStart(2, "0")}-${safeName}`;
}
