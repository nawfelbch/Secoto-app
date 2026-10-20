// SECOTO 107 — Rattrapage des cartes enregistrées.
// ----------------------------------------------------------------------------
// Le client enregistre sa carte chez Stripe (0 €, SetupIntent) ; c'est le
// webhook « setup_intent.succeeded » qui la rattache à sa commande et envoie
// la demande aux transporteurs. Si ce webhook n'arrive pas (événement non
// abonné, panne), la commande restait bloquée sur « paiement à valider » alors
// que le client avait tout fait (CMD-2026-E9F40DC9, 20/10/2026).
//
// Chaque minute, pour les paiements « carte en cours d'enregistrement » des
// 3 derniers jours, on demande à Stripe les SetupIntent RÉUSSIS du client qui
// portent ce paiement en métadonnée, et on les rattache par la même fonction
// que le webhook (secoto_direct_card_saved, idempotente).
// LECTURE SEULE chez Stripe : aucun débit, aucune autorisation, rien de créé.

const FENETRE_MS = 3 * 24 * 3600 * 1000;
const LOT = 10;

export function setupIntentReussi(liste, paymentId) {
  return (liste || [])
    .filter((si) => si?.status === "succeeded" && si?.metadata?.secoto_payment_id === paymentId
      && ["direct", "differe"].includes(si?.metadata?.secoto_circuit) && si.payment_method)
    .sort((a, b) => (b.created || 0) - (a.created || 0))[0] || null;
}

export async function rattraperCartes({ admin, stripe, now = Date.now() }) {
  const depuis = new Date(now - FENETRE_MS).toISOString();
  const { data: paiements, error } = await admin
    .from("payments")
    .select("id,account_id,payment_circuit,debit_a_confirmation,status,saved_payment_method_id,updated_at")
    .eq("status", "processing")
    .is("saved_payment_method_id", null)
    .gte("updated_at", depuis)
    .order("updated_at", { ascending: false })
    .limit(LOT * 3);
  if (error) return { error: error.message };

  const aVerifier = (paiements || [])
    .filter((p) => p.payment_circuit === "direct" || p.debit_a_confirmation === true)
    .slice(0, LOT);
  const rapport = [];
  for (const p of aVerifier) {
    try {
      const { data: compte } = await admin.from("accounts").select("stripe_customer_id").eq("id", p.account_id).maybeSingle();
      if (!compte?.stripe_customer_id) continue;
      const liste = await stripe.setupIntents.list({ customer: compte.stripe_customer_id, limit: 20 });
      const si = setupIntentReussi(liste?.data, p.id);
      if (!si) continue;
      const pm = typeof si.payment_method === "string" ? si.payment_method : si.payment_method?.id;
      const { data, error: e } = await admin.rpc("secoto_direct_card_saved", {
        p_payment_id: p.id,
        p_event_id: `rattrapage:${si.id}`,
        p_setup_intent_id: si.id,
        p_payment_method_id: pm,
      });
      rapport.push({ payment: p.id, setup_intent: si.id, result: e ? { error: e.message } : data });
    } catch (erreur) {
      rapport.push({ payment: p.id, erreur: String(erreur?.message || erreur).slice(0, 160) });
    }
  }
  return { verifies: aVerifier.length, rattaches: rapport };
}
