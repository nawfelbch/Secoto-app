const DB_NAME = "secoto-field-v1";
const DB_VERSION = 1;
const RECORD_STORE = "records";
const KEY_STORE = "crypto";

function ensureStorageAvailable() {
  if (typeof indexedDB === "undefined" || !globalThis.crypto?.subtle) {
    throw new Error("Stockage terrain chiffré indisponible sur cet appareil.");
  }
}

function requestResult(request) {
  return new Promise((resolve, reject) => {
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error || new Error("Erreur de stockage local."));
  });
}

async function openDatabase() {
  ensureStorageAvailable();
  const request = indexedDB.open(DB_NAME, DB_VERSION);
  request.onupgradeneeded = () => {
    const db = request.result;
    if (!db.objectStoreNames.contains(RECORD_STORE)) {
      const records = db.createObjectStore(RECORD_STORE, { keyPath: "key" });
      records.createIndex("owner", "owner", { unique: false });
      records.createIndex("kind", "kind", { unique: false });
    }
    if (!db.objectStoreNames.contains(KEY_STORE)) {
      db.createObjectStore(KEY_STORE, { keyPath: "id" });
    }
  };
  return requestResult(request);
}

async function transaction(storeName, mode, operation) {
  const db = await openDatabase();
  try {
    const tx = db.transaction(storeName, mode);
    const result = await operation(tx.objectStore(storeName));
    await new Promise((resolve, reject) => {
      tx.oncomplete = resolve;
      tx.onerror = () => reject(tx.error || new Error("Transaction locale impossible."));
      tx.onabort = () => reject(tx.error || new Error("Transaction locale annulée."));
    });
    return result;
  } finally {
    db.close();
  }
}

async function getEncryptionKey() {
  const existing = await transaction(KEY_STORE, "readonly", (store) => requestResult(store.get("field-data")));
  if (existing?.key) return existing.key;
  const key = await crypto.subtle.generateKey({ name: "AES-GCM", length: 256 }, false, ["encrypt", "decrypt"]);
  await transaction(KEY_STORE, "readwrite", (store) => requestResult(store.put({ id: "field-data", key })));
  return key;
}

function bytesToBase64(bytes) {
  let binary = "";
  const chunk = 0x8000;
  for (let offset = 0; offset < bytes.length; offset += chunk) {
    binary += String.fromCharCode(...bytes.subarray(offset, offset + chunk));
  }
  return btoa(binary);
}

function base64ToBytes(value) {
  const binary = atob(value);
  const bytes = new Uint8Array(binary.length);
  for (let index = 0; index < binary.length; index += 1) bytes[index] = binary.charCodeAt(index);
  return bytes;
}

async function encodeValue(value) {
  if (typeof File !== "undefined" && value instanceof File) {
    const bytes = new Uint8Array(await value.arrayBuffer());
    return {
      __secotoFile: true,
      name: value.name,
      type: value.type,
      lastModified: value.lastModified,
      data: bytesToBase64(bytes),
    };
  }
  if (Array.isArray(value)) return Promise.all(value.map(encodeValue));
  if (value && typeof value === "object") {
    const output = {};
    for (const [key, child] of Object.entries(value)) output[key] = await encodeValue(child);
    return output;
  }
  return value;
}

async function decodeValue(value) {
  if (value?.__secotoFile) {
    return new File([base64ToBytes(value.data)], value.name, {
      type: value.type,
      lastModified: value.lastModified,
    });
  }
  if (Array.isArray(value)) return Promise.all(value.map(decodeValue));
  if (value && typeof value === "object") {
    const output = {};
    for (const [key, child] of Object.entries(value)) output[key] = await decodeValue(child);
    return output;
  }
  return value;
}

async function encrypt(value) {
  const key = await getEncryptionKey();
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const encoded = new TextEncoder().encode(JSON.stringify(await encodeValue(value)));
  const encrypted = await crypto.subtle.encrypt({ name: "AES-GCM", iv }, key, encoded);
  return {
    iv: bytesToBase64(iv),
    payload: bytesToBase64(new Uint8Array(encrypted)),
  };
}

async function decrypt(record) {
  if (!record?.payload || !record?.iv) return null;
  const key = await getEncryptionKey();
  const clear = await crypto.subtle.decrypt(
    { name: "AES-GCM", iv: base64ToBytes(record.iv) },
    key,
    base64ToBytes(record.payload),
  );
  return decodeValue(JSON.parse(new TextDecoder().decode(clear)));
}

export async function saveEncryptedRecord({ key, owner, kind, value }) {
  const encrypted = await encrypt(value);
  await transaction(RECORD_STORE, "readwrite", (store) => requestResult(store.put({
    key,
    owner,
    kind,
    updatedAt: new Date().toISOString(),
    ...encrypted,
  })));
}

export async function loadEncryptedRecord(key) {
  const record = await transaction(RECORD_STORE, "readonly", (store) => requestResult(store.get(key)));
  return decrypt(record);
}

export async function listEncryptedRecords(owner, kind = null) {
  const records = await transaction(RECORD_STORE, "readonly", (store) => {
    const index = store.index("owner");
    return requestResult(index.getAll(owner));
  });
  const selected = kind ? records.filter((record) => record.kind === kind) : records;
  return Promise.all(selected.map(async (record) => ({
    key: record.key,
    kind: record.kind,
    updatedAt: record.updatedAt,
    value: await decrypt(record),
  })));
}

export async function removeEncryptedRecord(key) {
  await transaction(RECORD_STORE, "readwrite", (store) => requestResult(store.delete(key)));
}

export async function clearEncryptedAccountData(owner) {
  const records = await transaction(RECORD_STORE, "readonly", (store) => {
    const index = store.index("owner");
    return requestResult(index.getAll(owner));
  });
  await transaction(RECORD_STORE, "readwrite", async (store) => {
    for (const record of records) await requestResult(store.delete(record.key));
  });
}

export function trackingDraftKey(owner, missionId, eventType) {
  return `tracking:${owner}:${missionId}:${eventType}`;
}

export async function saveTrackingDraft(owner, missionId, eventType, form) {
  return saveEncryptedRecord({
    key: trackingDraftKey(owner, missionId, eventType),
    owner,
    kind: "tracking-draft",
    value: { missionId, eventType, form },
  });
}

export async function removeTrackingDraft(owner, missionId, eventType) {
  return removeEncryptedRecord(trackingDraftKey(owner, missionId, eventType));
}

export async function queueTrackingAction(owner, missionId, eventType, operationId) {
  const key = `queue:${owner}:${operationId}`;
  await saveEncryptedRecord({
    key,
    owner,
    kind: "pending-action",
    value: { type: "tracking", missionId, eventType, operationId, attempts: 0 },
  });
  return key;
}

export async function listTrackingDrafts(owner) {
  return listEncryptedRecords(owner, "tracking-draft");
}

export async function listPendingActions(owner) {
  return listEncryptedRecords(owner, "pending-action");
}
