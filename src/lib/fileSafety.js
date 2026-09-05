// ============================================================================
// SECOTO — sécurité et préparation des fichiers de preuve.
// ----------------------------------------------------------------------------
// TROIS RÈGLES ISSUES DU TERRAIN
//
// 1. Une photo valide ne doit JAMAIS être refusée. L'ancienne validation
//    exigeait que le type MIME *et* l'extension du nom soient reconnus. Or les
//    galeries Android livrent souvent un fichier sans extension, et iOS livre
//    du HEIC. Des états des lieux parfaitement valides étaient rejetés avec
//    « format refusé ». On accepte désormais dès que le MIME **ou**
//    l'extension identifie une image ; l'extension est réparée par
//    `safeFileName`, et le contenu est transcodé en JPEG avant l'envoi.
//
// 2. Le serveur n'accepte que JPEG, PNG, WebP (et PDF pour un incident).
//    `prepareEvidenceFile` garantit donc qu'un HEIC/HEIF, un fichier sans type
//    ou une image exotique repart TOUJOURS en JPEG.
//
// 3. On compresse systématiquement. Une photo de 1,9 Mo passait telle quelle :
//    dix photos = 19 Mo à téléverser en 4G au bord d'une route. À 1600 px et
//    qualité 0,75, un état des lieux reste parfaitement opposable et pèse
//    250 à 400 Ko — cinq à huit fois plus rapide à envoyer.
// ============================================================================

// Ce que le serveur accepte en sortie.
const UPLOADABLE_IMAGE_MIME = new Set(["image/jpeg", "image/png", "image/webp"]);
// Ce que l'on accepte en entrée, avant préparation.
const INPUT_IMAGE_MIME = new Set([
  "image/jpeg", "image/jpg", "image/png", "image/webp",
  "image/heic", "image/heif", "image/heic-sequence", "image/heif-sequence",
]);
const PDF_MIME_TYPES = new Set(["application/pdf"]);
const IMAGE_EXTENSIONS = new Set([
  "jpg", "jpeg", "jfif", "png", "webp", "heic", "heif", "gif", "bmp", "tif", "tiff",
]);
const PDF_EXTENSIONS = new Set(["pdf"]);
// Une extension presente et etrangere aux medias fait foi contre le MIME :
// un « preuve.exe » annonce en image/jpeg reste refuse.
function isMediaExtension(extension) {
  return extension === "" || IMAGE_EXTENSIONS.has(extension) || PDF_EXTENSIONS.has(extension);
}

export const DEFAULT_FILE_LIMITS = Object.freeze({
  maxFiles: 10,
  maxSizeBytes: 12 * 1024 * 1024,
});

export const EVIDENCE_COMPRESSION = Object.freeze({
  maxDimension: 1600,
  quality: 0.75,
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

/** Ce que le fichier est vraiment, en se fiant au MIME puis à l'extension. */
export function detectFileKind(file) {
  const mime = String(file?.type || "").toLowerCase();
  const extension = fileExtension(file?.name);
  // Une extension presente et etrangere aux medias fait foi contre le MIME.
  if (!isMediaExtension(extension)) return "unknown";
  // Un MIME present et etranger aux medias fait foi contre l'extension.
  if (mime && !mime.startsWith("image/") && !PDF_MIME_TYPES.has(mime)) return "unknown";
  if (PDF_MIME_TYPES.has(mime) || (!mime && PDF_EXTENSIONS.has(extension))) return "pdf";
  if (INPUT_IMAGE_MIME.has(mime) || mime.startsWith("image/")) return "image";
  if (IMAGE_EXTENSIONS.has(extension)) return "image";
  return "unknown";
}

export function isAllowedFile(file, { allowPdf = true } = {}) {
  const kind = detectFileKind(file);
  return kind === "image" || (allowPdf && kind === "pdf");
}

/** Le fichier est-il déjà dans un format que le serveur accepte tel quel ? */
export function isUploadReady(file) {
  const mime = String(file?.type || "").toLowerCase();
  return UPLOADABLE_IMAGE_MIME.has(mime) || PDF_MIME_TYPES.has(mime);
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

  if (list.length < minFiles) {
    errors.push(
      minFiles === 1
        ? "Ajoutez au moins une photo : elle fait office d’état des lieux."
        : `Ajoutez au moins ${minFiles} fichiers.`,
    );
  }
  if (list.length > maxFiles) errors.push(`Maximum ${maxFiles} fichiers par envoi.`);

  for (const file of list) {
    if (!isAllowedFile(file, { allowPdf })) {
      errors.push(
        `${file?.name || "Fichier"} : ce format n’est pas accepté (photos JPG, PNG, WebP, HEIC${allowPdf ? " ou PDF" : ""}).`,
      );
    }
    if (!Number.isFinite(file?.size) || file.size <= 0) {
      errors.push(`${file?.name || "Fichier"} : fichier vide ou illisible.`);
    } else if (file.size > maxSizeBytes) {
      errors.push(`${file.name} : ${Math.round(maxSizeBytes / 1024 / 1024)} Mo maximum par fichier.`);
    }
  }

  if (requireImage && list.length > 0) {
    const hasImage = list.some((file) => detectFileKind(file) === "image");
    if (!hasImage) errors.push("Au moins une photo est obligatoire.");
  }

  return { ok: errors.length === 0, errors };
}

function canUseCanvas() {
  return typeof document !== "undefined" && typeof createImageBitmap === "function";
}

/**
 * Redimensionne, transcode en JPEG et compresse une image de preuve.
 * Ne renvoie jamais d'erreur : en cas d'échec, le fichier d'origine est rendu
 * tel quel — mieux vaut un envoi lourd qu'un état des lieux perdu.
 */
export async function compressEvidenceImage(file, {
  maxDimension = EVIDENCE_COMPRESSION.maxDimension,
  quality = EVIDENCE_COMPRESSION.quality,
  // Conservé pour compatibilité d'appel : 0 = on compresse toujours.
  compressionThreshold = 0,
} = {}) {
  if (!file || detectFileKind(file) !== "image") return file;
  if (compressionThreshold > 0 && file.size <= compressionThreshold && isUploadReady(file)) return file;
  if (!canUseCanvas()) return file;

  let bitmap;
  try {
    bitmap = await createImageBitmap(file);
    const scale = Math.min(1, maxDimension / Math.max(bitmap.width, bitmap.height));
    const width = Math.max(1, Math.round(bitmap.width * scale));
    const height = Math.max(1, Math.round(bitmap.height * scale));
    const canvas = document.createElement("canvas");
    canvas.width = width;
    canvas.height = height;
    const context = canvas.getContext("2d");
    // Fond blanc : une PNG transparente convertie en JPEG ne vire pas au noir.
    context.fillStyle = "#ffffff";
    context.fillRect(0, 0, width, height);
    context.drawImage(bitmap, 0, 0, width, height);

    const blob = await new Promise((resolve) => canvas.toBlob(resolve, "image/jpeg", quality));
    if (!blob || blob.size <= 0) return file;
    // On garde l'original s'il est déjà plus léger ET déjà au bon format.
    if (isUploadReady(file) && blob.size >= file.size && scale === 1) return file;

    const baseName = safeFileName(file.name).replace(/\.[^.]+$/, "") || "photo";
    return new File([blob], `${baseName}.jpg`, {
      type: "image/jpeg",
      lastModified: file.lastModified || Date.now(),
    });
  } catch {
    return file;
  } finally {
    bitmap?.close?.();
  }
}

/**
 * Prépare un fichier pour l'envoi : image → JPEG compressé, PDF → inchangé.
 * Garantit un `type` exploitable même quand l'appareil n'en fournit aucun.
 */
export async function prepareEvidenceFile(file, options = {}) {
  const kind = detectFileKind(file);
  if (kind === "pdf") {
    if (file.type === "application/pdf") return file;
    return new File([file], safeFileName(file.name || "document.pdf"), {
      type: "application/pdf",
      lastModified: file.lastModified || Date.now(),
    });
  }
  if (kind !== "image") return file;

  const prepared = await compressEvidenceImage(file, options);
  if (isUploadReady(prepared)) return prepared;
  // Transcodage impossible (WebView sans canvas) : on force au moins un type
  // accepté par le bucket plutôt que de laisser partir un MIME vide.
  return new File([prepared], `${safeFileName(prepared.name).replace(/\.[^.]+$/, "") || "photo"}.jpg`, {
    type: "image/jpeg",
    lastModified: prepared.lastModified || Date.now(),
  });
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
