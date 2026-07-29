import { withLambda } from "@netlify/aws-lambda-compat";
// Finalise les suppressions Auth restées en auth_pending après une coupure.
// Aucun identifiant n'est accepté de l'appelant : seules les lignes déjà
// autorisées et anonymisées par la transaction SQL sont traitées.
import { createClient } from "@supabase/supabase-js";

const {
  SUPABASE_SERVICE_ROLE_KEY,
  SUPABASE_URL,
} = process.env;

function response(statusCode, body) {
  return {
    statusCode,
    headers: {
      "Cache-Control": "no-store",
      "Content-Type": "application/json; charset=utf-8",
    },
    body: JSON.stringify(body),
  };
}

export const handler = async (event = {}) => {
  const scheduledPayload = (() => {
    try {
      return JSON.parse(event.body || "{}");
    } catch {
      return {};
    }
  })();

  if (
    event.httpMethod &&
    !event.next_run &&
    !scheduledPayload.next_run
  ) {
    return response(404, { error: "not_found" });
  }
  if (!SUPABASE_URL || !SUPABASE_SERVICE_ROLE_KEY) {
    return response(503, { error: "server_not_configured" });
  }

  const admin = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const { data: requests, error } = await admin
    .from("account_deletion_requests")
    .select("id,user_id")
    .eq("status", "auth_pending")
    .order("updated_at", { ascending: true })
    .limit(25);
  if (error) return response(500, { error: "deletion_scan_failed" });

  let completed = 0;
  let pending = 0;
  for (const request of requests || []) {
    const { data: currentUser, error: lookupError } =
      await admin.auth.admin.getUserById(request.user_id);
    if (lookupError && currentUser?.user) {
      pending += 1;
      continue;
    }
    if (currentUser?.user) {
      const { error: deleteError } =
        await admin.auth.admin.deleteUser(request.user_id, true);
      if (deleteError) {
        pending += 1;
        continue;
      }
    }
    const { error: completeError } = await admin.rpc(
      "secoto_complete_account_deletion",
      { p_request_id: request.id },
    );
    if (completeError) pending += 1;
    else completed += 1;
  }

  return response(200, {
    scanned: (requests || []).length,
    completed,
    pending,
  });
};

export default withLambda(handler);
