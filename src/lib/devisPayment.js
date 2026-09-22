// ============================================================================
// SECOTO — lien de paiement d'un devis.
// ----------------------------------------------------------------------------
// Le client n'a pas forcement de compte SECOTO : ce lien est souvent le seul
// chemin qu'il a pour payer. Il est fabrique par la base (elle seule connait
// le Prix client et sait revoquer les anciens liens), jamais par le telephone.
// ============================================================================

import { supabase } from '../supabaseClient';

/**
 * Cree — ou retrouve — le lien de paiement d'une mission.
 * Renvoie { url, amountCents, expiresAt }.
 */
export async function createDevisPaymentLink(missionId, amountCents = null) {
  const { data, error } = await supabase.rpc('secoto_admin_devis_link', {
    p_mission: missionId,
    p_amount_cents: amountCents,
    p_validity_days: 30,
  });
  if (error) {
    const message = String(error.message || '');
    if (/Prix client/i.test(message)) {
      throw new Error("Renseignez le Prix client sur la fiche avant de créer le lien de paiement.");
    }
    if (/administrateur/i.test(message)) {
      throw new Error("Seul un compte administrateur SECOTO peut créer un lien de paiement.");
    }
    if (/annulee|annulée/i.test(message)) {
      throw new Error("Cette mission est annulée : aucun lien de paiement.");
    }
    if (/could not find the function|does not exist/i.test(message)) {
      throw new Error("La migration 038 n'est pas encore appliquée dans Supabase.");
    }
    throw new Error(message || "Lien de paiement indisponible.");
  }
  return {
    url: data?.url || '',
    amountCents: Number(data?.amount_cents || 0),
    expiresAt: data?.expires_at || null,
  };
}

/** Ligne ajoutee au SMS : le tarif, puis le lien, puis ce qu'il engage. */
export function paymentLine(url, amountCents) {
  const montant = (Number(amountCents || 0) / 100).toFixed(2).replace('.', ',');
  return `Réglez la course (${montant} €) ici : ${url}\nLe paiement vaut acceptation du devis.`;
}
