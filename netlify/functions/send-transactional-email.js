import { withLambda } from "@netlify/aws-lambda-compat";
// SECOTO — consommateur de la file e-mail (public.email_outbox).
// ----------------------------------------------------------------------------
// Doublon e-mail des événements critiques (paiement, annulation). L'e-mail
// constitue le support durable exigé pour la confirmation de commande et la
// renonciation au droit de rétractation : la notification push ne suffit pas.
// Balayage planifié, aucune entrée publique.
import { createClient } from "@supabase/supabase-js";

const {
  RESEND_API_KEY,
  RESEND_FROM = "SECOTO <contact.secoto@gmail.com>",
  SUPABASE_SERVICE_ROLE_KEY,
  SUPABASE_URL,
} = process.env;

const BATCH = 20;

function response(statusCode, body) {
  return {
    statusCode,
    headers: { "Cache-Control": "no-store", "Content-Type": "application/json; charset=utf-8" },
    body: JSON.stringify(body),
  };
}

export function backoffSeconds(attempts) {
  return Math.min(3600, 2 ** Math.max(attempts, 1) * 30);
}

async function sendOne(row) {
  const result = await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: {
      Authorization: `Bearer ${RESEND_API_KEY}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      from: RESEND_FROM,
      to: [row.to_email],
      subject: row.subject,
      text: row.body_text,
    }),
  });
  if (!result.ok) {
    const detail = await result.text();
    throw new Error(`RESEND_${result.status}:${detail.slice(0, 200)}`);
  }
}

const handler = async () => {
  if (!SUPABASE_URL || !SUPABASE_SERVICE_ROLE_KEY) {
    return response(503, { error: "server_not_configured" });
  }
  if (!RESEND_API_KEY) {
    // Les messages restent en file : rien n'est perdu tant que la clé manque.
    return response(503, { error: "email_provider_not_configured" });
  }

  const admin = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  const { data: rows, error } = await admin
    .from("email_outbox")
    .select("id,to_email,subject,body_text,attempts,max_attempts")
    .eq("status", "pending")
    .lte("available_at", new Date().toISOString())
    .order("created_at", { ascending: true })
    .limit(BATCH);
  if (error) return response(500, { error: "outbox_scan_failed" });

  let sent = 0;
  let failed = 0;

  for (const row of rows || []) {
    const attempts = row.attempts + 1;
    const { error: claimError } = await admin
      .from("email_outbox")
      .update({ status: "processing", attempts })
      .eq("id", row.id)
      .eq("status", "pending");
    if (claimError) continue;

    try {
      await sendOne(row);
      await admin
        .from("email_outbox")
        .update({ status: "sent", sent_at: new Date().toISOString(), last_error: null })
        .eq("id", row.id);
      sent += 1;
    } catch (sendError) {
      failed += 1;
      await admin
        .from("email_outbox")
        .update({
          status: attempts >= row.max_attempts ? "failed" : "pending",
          available_at: new Date(Date.now() + backoffSeconds(attempts) * 1000).toISOString(),
          last_error: String(sendError?.message || "send_failed").slice(0, 500),
        })
        .eq("id", row.id);
    }
  }

  return response(200, { scanned: (rows || []).length, sent, failed });
};

export default withLambda(handler);
