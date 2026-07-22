// SECOTO — Envoi de notifications Web Push (fonction Netlify).
// Reçoit { audience, transporterType, accountId, title, body, url, missionId }
// et pousse la notification aux abonnements concernés dans push_subscriptions.
//
// Variables d'environnement Netlify requises pour activer l'envoi :
//   VAPID_PUBLIC_KEY, VAPID_PRIVATE_KEY, VAPID_SUBJECT (ex: mailto:contact.secoto@gmail.com)
//   SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY
// Sans ces variables, la fonction répond 200 { skipped: true } (la brique realtime prend le relais).

import webpush from "web-push";
import { createClient } from "@supabase/supabase-js";

const {
  VAPID_PUBLIC_KEY,
  VAPID_PRIVATE_KEY,
  VAPID_SUBJECT,
  SUPABASE_URL,
  SUPABASE_SERVICE_ROLE_KEY,
} = process.env;

const configured =
  VAPID_PUBLIC_KEY && VAPID_PRIVATE_KEY && SUPABASE_URL && SUPABASE_SERVICE_ROLE_KEY;

export const handler = async (event) => {
  if (event.httpMethod !== "POST") {
    return { statusCode: 405, body: "Method Not Allowed" };
  }

  if (!configured) {
    return { statusCode: 200, body: JSON.stringify({ skipped: true, reason: "not_configured" }) };
  }

  let payload;
  try {
    payload = JSON.parse(event.body || "{}");
  } catch {
    return { statusCode: 400, body: "Invalid JSON" };
  }

  const { audience, transporterType, accountId, title, body, url, missionId } = payload;

  webpush.setVapidDetails(
    VAPID_SUBJECT || "mailto:contact.secoto@gmail.com",
    VAPID_PUBLIC_KEY,
    VAPID_PRIVATE_KEY
  );

  const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);

  // Cible : soit un compte précis (client), soit un rôle (transporteurs), éventuellement filtré par sous-type.
  let query = supabase.from("push_subscriptions").select("*");
  if (accountId) {
    query = query.eq("account_id", accountId);
  } else if (audience) {
    query = query.eq("role", audience === "transporter" ? "transporter" : audience);
  }

  const { data: subs, error } = await query;
  if (error) {
    return { statusCode: 500, body: JSON.stringify({ error: error.message }) };
  }

  let targets = subs || [];

  // Filtre optionnel par sous-type transporteur (jointure légère sur accounts).
  if (transporterType && targets.length) {
    const ids = [...new Set(targets.map((s) => s.account_id))];
    const { data: accs } = await supabase
      .from("accounts")
      .select("id, transporter_type")
      .in("id", ids);
    const keep = new Set(
      (accs || []).filter((a) => a.transporter_type === transporterType).map((a) => a.id)
    );
    targets = targets.filter((s) => keep.has(s.account_id));
  }

  const notification = JSON.stringify({
    title: title || "SECOTO",
    body: body || "",
    url: url || "/",
    missionId: missionId || null,
    tag: missionId ? `mission-${missionId}` : "secoto",
  });

  const results = await Promise.allSettled(
    targets.map((s) =>
      webpush.sendNotification(
        { endpoint: s.endpoint, keys: { p256dh: s.p256dh, auth: s.auth } },
        notification
      )
    )
  );

  // Nettoyage des abonnements expirés (410 / 404).
  const stale = [];
  results.forEach((r, i) => {
    if (r.status === "rejected" && [404, 410].includes(r.reason?.statusCode)) {
      stale.push(targets[i].endpoint);
    }
  });
  if (stale.length) {
    await supabase.from("push_subscriptions").delete().in("endpoint", stale);
  }

  const sent = results.filter((r) => r.status === "fulfilled").length;
  return { statusCode: 200, body: JSON.stringify({ sent, total: targets.length }) };
};
