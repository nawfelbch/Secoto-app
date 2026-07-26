import { supabase, supabaseAnonKey, supabaseUrl } from "../supabaseClient";

export async function createShortSignedUrl(bucket, path, expiresIn = 120) {
  if (!bucket || !path) throw new Error("Référence de fichier incomplète.");
  const safeExpiry = Math.max(30, Math.min(Number(expiresIn) || 120, 600));
  const { data, error } = await supabase.storage.from(bucket).createSignedUrl(path, safeExpiry);
  if (error) throw error;
  if (!data?.signedUrl) throw new Error("URL sécurisée indisponible.");
  return data.signedUrl;
}

export async function hydrateSignedFileUrls(records, bucket, expiresIn = 120) {
  return Promise.all(
    (records || []).map(async (record) => {
      if (!record?.filePath) return { ...record, fileUrl: null };
      try {
        return {
          ...record,
          fileUrl: await createShortSignedUrl(bucket, record.filePath, expiresIn),
        };
      } catch {
        return { ...record, fileUrl: null };
      }
    }),
  );
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

function uploadOnce({ bucket, path, file, accessToken, onProgress, signal }) {
  return new Promise((resolve, reject) => {
    const xhr = new XMLHttpRequest();
    xhr.open("POST", encodeStoragePath(bucket, path), true);
    xhr.setRequestHeader("Authorization", `Bearer ${accessToken}`);
    xhr.setRequestHeader("apikey", supabaseAnonKey);
    xhr.setRequestHeader("Content-Type", file.type || "application/octet-stream");
    xhr.setRequestHeader("x-upsert", "false");
    xhr.setRequestHeader("cache-control", "3600");

    xhr.upload.onprogress = (event) => {
      if (!event.lengthComputable) return;
      onProgress?.(Math.min(99, Math.round((event.loaded / event.total) * 100)));
    };
    xhr.onerror = () => reject(new Error("Upload interrompu par le réseau."));
    xhr.onabort = () => reject(new DOMException("Upload annulé.", "AbortError"));
    xhr.onload = () => {
      if (xhr.status >= 200 && xhr.status < 300) {
        onProgress?.(100);
        resolve({ duplicate: false });
        return;
      }
      const error = new Error(`Upload refusé (${xhr.status}).`);
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
}) {
  const { data, error } = await supabase.auth.getSession();
  if (error) throw error;
  const accessToken = data?.session?.access_token;
  if (!accessToken) throw new Error("Session expirée. Reconnectez-vous avant l'envoi.");

  let lastError;
  for (let attempt = 1; attempt <= attempts; attempt += 1) {
    try {
      return await uploadOnce({ bucket, path, file, accessToken, onProgress, signal });
    } catch (error) {
      if (error?.name === "AbortError") throw error;
      if (error?.status === 409 && await verifyExistingObject(bucket, path)) {
        onProgress?.(100);
        return { duplicate: true };
      }
      lastError = error;
      if (attempt < attempts) {
        await new Promise((resolve) => setTimeout(resolve, attempt * 750));
      }
    }
  }
  throw lastError || new Error("Upload impossible.");
}
