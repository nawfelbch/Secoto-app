import { supabase, supabaseAnonKey, supabaseUrl } from "../supabaseClient";

// ============================================================================
// SECOTO — dépôt et lecture des fichiers privés (preuves terrain, documents).
// ----------------------------------------------------------------------------
// CE QUI A ÉTÉ CORRIGÉ LE 05/09/2026
//
// · L'envoi n'avait AUCUN délai maximum. En zone blanche, dans un parking
//   souterrain ou un ascenseur — le quotidien d'un convoyeur — la requête
//   restait pendante indéfiniment : le bouton restait grisé, aucune sortie
//   possible sauf tuer l'application. Chaque envoi a désormais un délai de
//   45 s, et l'écran peut l'annuler.
//
// · Les fichiers partaient un par un : jusqu'à dix envois en série. Ils
//   partent maintenant deux par deux, avec une progression par fichier
//   (« photo 3 / 6 ») au lieu d'un pourcentage global illisible.
//
// · Les vignettes cassaient au bout de 120 s sur un écran admin resté ouvert
//   (« les photos ne s'affichent pas »). Les URL signées durent 15 minutes et
//   sont re-signées à la demande.
// ============================================================================

export const UPLOAD_TIMEOUT_MS = 45_000;
const SIGNED_URL_DEFAULT_SECONDS = 900; // 15 minutes
const SIGN_CONCURRENCY = 6;
const UPLOAD_CONCURRENCY = 2;

export async function createShortSignedUrl(bucket, path, expiresIn = SIGNED_URL_DEFAULT_SECONDS) {
  if (!bucket || !path) throw new Error("Référence de fichier incomplète.");
  const safeExpiry = Math.max(30, Math.min(Number(expiresIn) || SIGNED_URL_DEFAULT_SECONDS, 3600));
  const { data, error } = await supabase.storage.from(bucket).createSignedUrl(path, safeExpiry);
  if (error) throw error;
  if (!data?.signedUrl) throw new Error("URL sécurisée indisponible.");
  return data.signedUrl;
}

/** Exécute des tâches par petits paquets pour ne pas saturer le réseau mobile. */
async function mapWithConcurrency(items, limit, worker) {
  const results = new Array(items.length);
  let cursor = 0;
  const runners = Array.from({ length: Math.min(limit, items.length) }, async () => {
    while (cursor < items.length) {
      const index = cursor;
      cursor += 1;
      results[index] = await worker(items[index], index);
    }
  });
  await Promise.all(runners);
  return results;
}

export async function hydrateSignedFileUrls(
  records,
  bucket,
  expiresIn = SIGNED_URL_DEFAULT_SECONDS,
) {
  const list = records || [];
  return mapWithConcurrency(list, SIGN_CONCURRENCY, async (record) => {
    if (!record?.filePath) return { ...record, fileUrl: null };
    try {
      return { ...record, fileUrl: await createShortSignedUrl(bucket, record.filePath, expiresIn) };
    } catch {
      return { ...record, fileUrl: null };
    }
  });
}

function encodeStoragePath(bucket, path) {
  const encodedBucket = encodeURIComponent(bucket);
  const encodedPath = String(path)
    .split("/")
    .map((segment) => encodeURIComponent(segment))
    .join("/");
  return `${supabaseUrl}/storage/v1/object/${encodedBucket}/${encodedPath}`;
}

async function verifyExistingObject(bucket, path) {
  const { data, error } = await supabase.storage.from(bucket).createSignedUrl(path, 30);
  return !error && Boolean(data?.signedUrl);
}

function uploadOnce({ bucket, path, file, accessToken, onProgress, signal, timeoutMs }) {
  return new Promise((resolve, reject) => {
    const xhr = new XMLHttpRequest();
    xhr.open("POST", encodeStoragePath(bucket, path), true);
    xhr.timeout = timeoutMs;
    xhr.setRequestHeader("Authorization", `Bearer ${accessToken}`);
    xhr.setRequestHeader("apikey", supabaseAnonKey);
    xhr.setRequestHeader("Content-Type", file.type || "application/octet-stream");
    xhr.setRequestHeader("x-upsert", "false");
    xhr.setRequestHeader("cache-control", "3600");

    xhr.upload.onprogress = (event) => {
      if (!event.lengthComputable) return;
      onProgress?.(Math.min(99, Math.round((event.loaded / event.total) * 100)));
    };
    xhr.onerror = () => reject(new Error("Envoi interrompu par le réseau."));
    xhr.ontimeout = () => {
      const error = new Error("Le réseau ne répond plus. L’envoi a été arrêté après 45 secondes.");
      error.timeout = true;
      reject(error);
    };
    xhr.onabort = () => reject(new DOMException("Envoi annulé.", "AbortError"));
    xhr.onload = () => {
      if (xhr.status >= 200 && xhr.status < 300) {
        onProgress?.(100);
        resolve({ duplicate: false });
        return;
      }
      const error = new Error(
        xhr.status === 403
          ? "Le serveur a refusé cette photo : la mission n’est plus ouverte de votre côté. Contactez SECOTO pour la rouvrir."
          : `Envoi refusé par le serveur (${xhr.status}).`,
      );
      error.status = xhr.status;
      error.responseText = xhr.responseText;
      reject(error);
    };
    if (signal) {
      if (signal.aborted) {
        xhr.abort();
        return;
      }
      signal.addEventListener("abort", () => xhr.abort(), { once: true });
    }
    xhr.send(file);
  });
}

export async function uploadPrivateFile({
  bucket,
  path,
  file,
  onProgress,
  signal,
  attempts = 3,
  timeoutMs = UPLOAD_TIMEOUT_MS,
  accessToken: providedToken = null,
}) {
  let accessToken = providedToken;
  if (!accessToken) {
    const { data, error } = await supabase.auth.getSession();
    if (error) throw error;
    accessToken = data?.session?.access_token;
  }
  if (!accessToken) throw new Error("Session expirée. Reconnectez-vous avant l’envoi.");

  let lastError;
  for (let attempt = 1; attempt <= attempts; attempt += 1) {
    try {
      return await uploadOnce({ bucket, path, file, accessToken, onProgress, signal, timeoutMs });
    } catch (error) {
      if (error?.name === "AbortError") throw error;
      if (error?.status === 409 && await verifyExistingObject(bucket, path)) {
        onProgress?.(100);
        return { duplicate: true };
      }
      // Un refus de droits ne se répare pas en réessayant.
      if (error?.status === 401 || error?.status === 403) throw error;
      lastError = error;
      if (attempt < attempts) {
        await new Promise((resolve) => setTimeout(resolve, attempt * 750));
      }
    }
  }
  throw lastError || new Error("Envoi impossible.");
}

/**
 * Envoie un lot de fichiers, deux à la fois, en rapportant l'avancement
 * fichier par fichier : `onFileProgress({ index, percent, done, total })`.
 */
export async function uploadPrivateFiles({
  bucket,
  files,
  buildPath,
  onFileProgress,
  signal,
  attempts = 3,
  timeoutMs = UPLOAD_TIMEOUT_MS,
}) {
  const list = files || [];
  const { data, error } = await supabase.auth.getSession();
  if (error) throw error;
  const accessToken = data?.session?.access_token;
  if (!accessToken) throw new Error("Session expirée. Reconnectez-vous avant l’envoi.");

  let done = 0;
  return mapWithConcurrency(list, UPLOAD_CONCURRENCY, async (file, index) => {
    const path = await buildPath(file, index);
    await uploadPrivateFile({
      bucket,
      path,
      file,
      accessToken,
      signal,
      attempts,
      timeoutMs,
      onProgress: (percent) => onFileProgress?.({ index, percent, done, total: list.length }),
    });
    done += 1;
    onFileProgress?.({ index, percent: 100, done, total: list.length });
    return { file, path, index };
  });
}
