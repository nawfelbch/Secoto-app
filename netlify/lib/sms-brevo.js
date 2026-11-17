// SECOTO 151 — envoi des SMS en file (table sms_outbox) par Brevo.
// Sans clé BREVO_API_KEY : rien n'est envoyé, les SMS restent en attente
// (abandonnés par la base au bout de 12 h). Jamais de clé dans le code.
export const BREVO_SMS_URL = "https://api.brevo.com/v3/transactionalSMS/send";

export function brevoSmsPayload(sms, sender = "SECOTO") {
  return {
    sender: String(sender || "SECOTO").slice(0, 11),
    recipient: String(sms.to_phone || "").replace(/^\+/, ""),
    content: String(sms.body || "").slice(0, 600),
    // 152 : « marketing » pour les invitations de prospects (mention STOP obligatoire).
    type: sms.sms_type === "marketing" ? "marketing" : "transactional",
    tag: sms.sms_type === "marketing" ? "secoto-prospection" : "secoto-automatisation",
  };
}

export async function envoyerSmsEnAttente({ admin, env = process.env, fetchImpl = fetch, limit = 20 } = {}) {
  const cle = env.BREVO_API_KEY;
  if (!cle) return { envoyes: 0, raison: "sans_cle" };
  const { data: lot, error } = await admin.rpc("secoto_sms_a_envoyer", { p_limit: limit });
  if (error) return { error: error.message };
  let envoyes = 0, echecs = 0;
  for (const sms of lot || []) {
    try {
      const r = await fetchImpl(BREVO_SMS_URL, {
        method: "POST",
        headers: { "api-key": cle, "Content-Type": "application/json", accept: "application/json" },
        body: JSON.stringify(brevoSmsPayload(sms, env.BREVO_SMS_SENDER)),
      });
      if (!r.ok) throw new Error(`Brevo ${r.status}: ${(await r.text()).slice(0, 200)}`);
      await admin.rpc("secoto_sms_resultat", { p_id: sms.id, p_ok: true, p_error: null });
      envoyes += 1;
    } catch (e) {
      await admin.rpc("secoto_sms_resultat", { p_id: sms.id, p_ok: false, p_error: String(e?.message || e).slice(0, 300) });
      echecs += 1;
    }
  }
  return { envoyes, echecs };
}
