// Reprise planifiée de l'outbox. Le webhook reste le chemin rapide ; ce
// balayage récupère les indisponibilités fournisseur, fonctions ou réseau.
import { createClient } from "@supabase/supabase-js";
import { handler as dispatchPush } from "./send-mission-notifications.js";

const {
  SECOTO_PUSH_WEBHOOK_SECRET,
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

export const handler = async () => {
  if (!SUPABASE_URL || !SUPABASE_SERVICE_ROLE_KEY || !SECOTO_PUSH_WEBHOOK_SECRET) {
    return response(503, { error: "server_not_configured" });
  }

  const admin = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const now = new Date().toISOString();
  const staleLock = new Date(Date.now() - 10 * 60 * 1000).toISOString();
  const [waiting, stale] = await Promise.all([
    admin
      .from("push_outbox")
      .select("id")
      .in("status", ["pending", "failed"])
      .lte("available_at", now)
      .order("created_at", { ascending: true })
      .limit(25),
    admin
      .from("push_outbox")
      .select("id")
      .eq("status", "processing")
      .lt("locked_at", staleLock)
      .order("created_at", { ascending: true })
      .limit(25),
  ]);
  if (waiting.error || stale.error) {
    return response(500, { error: "outbox_scan_failed" });
  }

  const ids = [...new Set([
    ...(waiting.data || []).map((row) => row.id),
    ...(stale.data || []).map((row) => row.id),
  ])].slice(0, 25);
  const results = [];
  for (const outboxId of ids) {
    const result = await dispatchPush({
      httpMethod: "POST",
      headers: { "x-secoto-push-secret": SECOTO_PUSH_WEBHOOK_SECRET },
      body: JSON.stringify({ outboxId }),
    });
    results.push({ outboxId, statusCode: result.statusCode });
  }

  return response(200, {
    scanned: ids.length,
    dispatched: results.filter((item) => item.statusCode < 500).length,
    results,
  });
};
