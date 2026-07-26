// SECOTO — suppression de compte authentifiée, idempotente et reprenable.
// Les objets sont supprimés via l'API Storage, jamais via storage.objects.
import { createClient } from "@supabase/supabase-js";

const {
  SUPABASE_SERVICE_ROLE_KEY,
  SUPABASE_URL,
} = process.env;

const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const ALLOWED_BUCKETS = new Set(["documents", "mission-photos", "justificatifs"]);
const ALLOWED_ORIGINS = new Set([
  "https://app.secoto-transport.fr",
  "https://www.app.secoto-transport.fr",
  "capacitor://localhost",
  "http://localhost",
  "https://localhost",
]);

function json(statusCode, body, origin = "") {
  const corsOrigin = ALLOWED_ORIGINS.has(origin) ? origin : "https://app.secoto-transport.fr";
  return {
    statusCode,
    headers: {
      "Access-Control-Allow-Headers": "Authorization, Content-Type",
      "Access-Control-Allow-Methods": "POST, OPTIONS",
      "Access-Control-Allow-Origin": corsOrigin,
      Vary: "Origin",
      "Cache-Control": "no-store",
      "Content-Type": "application/json; charset=utf-8",
    },
    body: JSON.stringify(body),
  };
}

export function bearerToken(headers = {}) {
  const authorization = headers.authorization || headers.Authorization || "";
  const match = authorization.match(/^Bearer\s+([A-Za-z0-9._~-]+)$/);
  return match?.[1] || null;
}

function safeStorageObjects(rawObjects) {
  if (!Array.isArray(rawObjects)) return [];
  return rawObjects.filter((object) => (
    object &&
    ALLOWED_BUCKETS.has(object.bucket) &&
    typeof object.path === "string" &&
    object.path.length > 0 &&
    object.path.length <= 1024 &&
    !object.path.includes("..") &&
    !object.path.startsWith("/")
  ));
}

async function markFailure(admin, requestId, reason) {
  if (!requestId) return;
  await admin.rpc("secoto_fail_account_deletion", {
    p_request_id: requestId,
    p_error: String(reason || "deletion_failed").slice(0, 500),
  });
}

export const handler = async (event) => {
  const origin = event.headers?.origin || event.headers?.Origin || "";
  const respond = (status, body) => json(status, body, origin);
  if (origin && !ALLOWED_ORIGINS.has(origin)) return respond(403, { error: "origin_not_allowed" });
  if (event.httpMethod === "OPTIONS") return respond(204, {});
  if (event.httpMethod !== "POST") return respond(405, { error: "method_not_allowed" });
  if (!SUPABASE_URL || !SUPABASE_SERVICE_ROLE_KEY) {
    return respond(503, { error: "server_not_configured" });
  }

  const token = bearerToken(event.headers);
  if (!token) return respond(401, { error: "authentication_required" });

  let body;
  try {
    body = JSON.parse(event.body || "{}");
  } catch {
    return respond(400, { error: "invalid_json" });
  }
  if (!UUID_PATTERN.test(body.idempotencyKey || "")) {
    return respond(400, { error: "invalid_idempotency_key" });
  }

  const admin = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const { data: userData, error: userError } = await admin.auth.getUser(token);
  const user = userData?.user;
  if (userError || !user) return respond(401, { error: "invalid_or_expired_session" });

  const { data: preparedData, error: prepareError } = await admin.rpc(
    "secoto_prepare_account_deletion",
    {
      p_user_id: user.id,
      p_idempotency_key: body.idempotencyKey,
    },
  );
  if (prepareError) return respond(409, { error: "deletion_not_allowed" });
  const prepared = Array.isArray(preparedData) ? preparedData[0] : preparedData;
  if (prepared?.status === "completed") return respond(200, { status: "completed" });
  const requestId = prepared?.request_id;
  if (!requestId) return respond(500, { error: "deletion_request_missing" });

  try {
    if (prepared?.status !== "auth_pending") {
      const grouped = new Map();
      for (const object of safeStorageObjects(prepared.storage_objects)) {
        if (!grouped.has(object.bucket)) grouped.set(object.bucket, []);
        grouped.get(object.bucket).push(object.path);
      }
      for (const [bucket, paths] of grouped) {
        for (let offset = 0; offset < paths.length; offset += 100) {
          const { error } = await admin.storage.from(bucket).remove(paths.slice(offset, offset + 100));
          if (error) throw new Error(`storage_${bucket}_failed`);
        }
      }

      const { error: finalizeError } = await admin.rpc("secoto_finalize_account_deletion", {
        p_user_id: user.id,
        p_request_id: requestId,
      });
      if (finalizeError) throw new Error("database_anonymization_failed");
    }

    // La base reste en auth_pending jusqu'à preuve de suppression Auth. Un
    // balayage serveur reprend cette étape si la fonction est interrompue.
    const { error: authError } = await admin.auth.admin.deleteUser(user.id, true);
    if (authError) {
      return respond(502, {
        error: "auth_deletion_pending",
        requestId,
      });
    }

    const { error: completeError } = await admin.rpc("secoto_complete_account_deletion", {
      p_request_id: requestId,
    });
    if (completeError) {
      return respond(502, {
        error: "deletion_receipt_pending",
        requestId,
      });
    }
    return respond(200, { status: "completed" });
  } catch (error) {
    await markFailure(admin, requestId, error?.message);
    return respond(502, {
      error: "deletion_incomplete_retry_required",
      requestId,
    });
  }
};
