import { createHash } from "node:crypto";
import { withLambda } from "@netlify/aws-lambda-compat";
import { createClient } from "@supabase/supabase-js";

const { SUPABASE_SERVICE_ROLE_KEY, SUPABASE_URL } = process.env;
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
      "Access-Control-Allow-Headers": "Content-Type",
      "Access-Control-Allow-Methods": "POST, OPTIONS",
      "Access-Control-Allow-Origin": corsOrigin,
      "Cache-Control": "no-store",
      "Content-Type": "application/json; charset=utf-8",
      Vary: "Origin",
    },
    body: JSON.stringify(body),
  };
}

function digest(value) {
  return createHash("sha256").update(String(value || "")).digest("hex");
}

function errorKind(error) {
  const message = String(error?.message || "");
  if (message.includes("ACCESS_RATE_LIMITED")) return "rate_limited";
  if (message.includes("ACCESS_EXPIRED")) return "access_expired";
  if (message.includes("ACCESS_USED")) return "access_used";
  return "invalid_access";
}

const handler = async (event) => {
  const origin = event.headers?.origin || event.headers?.Origin || "";
  const respond = (status, body) => json(status, body, origin);
  if (origin && !ALLOWED_ORIGINS.has(origin)) return respond(403, { error: "origin_not_allowed" });
  if (event.httpMethod === "OPTIONS") return respond(204, {});
  if (event.httpMethod !== "POST") return respond(405, { error: "method_not_allowed" });
  if (!SUPABASE_URL || !SUPABASE_SERVICE_ROLE_KEY) {
    return respond(503, { error: "server_not_configured" });
  }

  let body;
  try {
    body = JSON.parse(event.body || "{}");
  } catch {
    return respond(400, { error: "invalid_access" });
  }
  const phone = String(body.phone || "").trim().slice(0, 40);
  const code = String(body.code || "").toUpperCase().replace(/[^A-Z0-9]/g, "").slice(0, 10);
  if (phone.replace(/\D/g, "").length < 8 || code.length !== 10) {
    return respond(400, { error: "invalid_access" });
  }

  const forwarded = event.headers?.["x-nf-client-connection-ip"]
    || event.headers?.["x-forwarded-for"]
    || "unknown";
  const ipHash = digest(String(forwarded).split(",")[0].trim());
  const phoneHash = digest(phone.replace(/\D/g, ""));
  const admin = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  const recordAttempt = async (succeeded) => {
    await admin.from("client_access_attempts").insert({
      ip_hash: ipHash,
      phone_hash: phoneHash,
      succeeded,
    });
  };

  const { data: preparedData, error: preparedError } = await admin.rpc(
    "secoto_prepare_client_phone_access",
    {
      p_phone: phone,
      p_code: code,
      p_ip_hash: ipHash,
      p_phone_hash: phoneHash,
    },
  );
  if (preparedError) {
    await recordAttempt(false);
    const kind = errorKind(preparedError);
    return respond(kind === "rate_limited" ? 429 : 401, { error: kind });
  }

  const prepared = Array.isArray(preparedData) ? preparedData[0] : preparedData;
  if (!prepared?.mission_id) {
    await recordAttempt(false);
    return respond(401, { error: "invalid_access" });
  }

  let accountId = prepared.account_id || null;
  let authUser;
  let createdUser = false;
  let finalized = false;
  try {
    if (accountId) {
      const { data, error } = await admin.auth.admin.getUserById(accountId);
      if (error || !data?.user) throw error || new Error("account_missing");
      authUser = data.user;
    } else {
      const internalEmail = `client+${digest(prepared.normalized_phone).slice(0, 32)}@client.secoto.invalid`;
      const { data, error } = await admin.auth.admin.createUser({
        email: internalEmail,
        email_confirm: true,
        user_metadata: {
          role: "client",
          client_type: "particulier",
          full_name: prepared.client_name || "Client SECOTO",
          phone,
        },
      });
      if (error || !data?.user) throw error || new Error("account_creation_failed");
      authUser = data.user;
      accountId = authUser.id;
      createdUser = true;
      await admin.from("accounts").update({ email: null }).eq("id", accountId);
    }

    const email = authUser.email;
    if (!email) throw new Error("account_email_missing");
    const { data: linkData, error: linkError } = await admin.auth.admin.generateLink({
      type: "magiclink",
      email,
    });
    const tokenHash = linkData?.properties?.hashed_token;
    if (linkError || !tokenHash) {
      throw linkError || new Error("session_link_failed");
    }

    const { data: claimedData, error: claimedError } = await admin.rpc(
      "secoto_complete_client_phone_access",
      { p_phone: phone, p_code: code, p_account_id: accountId },
    );
    if (claimedError) throw claimedError;
    const claimed = Array.isArray(claimedData) ? claimedData[0] : claimedData;
    finalized = true;

    await recordAttempt(true);
    return respond(200, {
      tokenHash,
      missionId: claimed?.mission_id || prepared.mission_id,
      publicRef: claimed?.public_ref || prepared.public_ref,
    });
  } catch (error) {
    if (createdUser && !finalized && accountId) await admin.auth.admin.deleteUser(accountId, true);
    await recordAttempt(false);
    return respond(409, { error: errorKind(error) });
  }
};

export default withLambda(handler);
