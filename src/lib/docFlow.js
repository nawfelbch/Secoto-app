// ============================================================================
// SECOTO — Circuit des documents (emission, signature, telechargement).
// ----------------------------------------------------------------------------
// Enchainement automatique :
//   attribution   -> DEVIS au client (a signer) + BON DE MISSION prepare
//   devis signe   -> BON DE MISSION envoye au transporteur (a signer)
//   bon signe     -> SECOTO notifie
//   facture       -> envoyee manuellement par l'admin au client
//
// Le document est FIGE (html_snapshot) au moment de l'emission : ce que le
// destinataire voit, signe et telecharge ne peut plus changer ensuite.
// Le cloisonnement des montants est assure par les RLS cote base ET par le
// contenu meme du document (le bon de mission ne contient aucun prix client).
// ============================================================================

import { supabase } from '../supabaseClient';
import { renderDevisHtml, renderBonMissionHtml, renderFactureHtml } from './documents';

export const DOC_LABEL = {
  devis: 'Devis',
  bon_de_mission: 'Bon de mission',
  facture: 'Facture',
};

export function docFromDb(row) {
  return {
    id: row.id,
    missionId: row.mission_id,
    accountId: row.account_id,
    recipientId: row.recipient_id,
    docType: row.doc_type,
    numero: row.numero,
    statut: row.statut,
    html: row.html_snapshot,
    needsSignature: row.needs_signature,
    refDevis: row.ref_devis,
    signatureClient: row.signature_client,
    signatureTransporteur: row.signature_transporteur,
    emittedAt: row.emitted_at,
    signedAt: row.signed_at,
    createdAt: row.created_at,
  };
}

/** Documents generes (devis / bon / facture) visibles par l'utilisateur. */
export async function listMyDocuments() {
  const { data, error } = await supabase
    .from('documents')
    .select('*')
    .not('doc_type', 'is', null)
    .order('created_at', { ascending: false });
  if (error) throw error;
  return (data || []).map(docFromDb);
}

/** Appel generique de la fonction d'emission (reservee a l'admin cote base). */
async function emit({ missionId, type, html, recipientId, statut = 'envoye', needsSignature = true, refDevis = null }) {
  if (!recipientId) {
    throw new Error(
      type === 'devis' || type === 'facture'
        ? "Cette course n'est reliee a aucun compte client : le document ne peut pas etre envoye dans l'application."
        : "Aucun transporteur attribue : le bon de mission ne peut pas etre prepare."
    );
  }
  const { data, error } = await supabase.rpc('secoto_emit_document', {
    p_mission: missionId,
    p_type: type,
    p_html: html,
    p_recipient: recipientId,
    p_statut: statut,
    p_needs_signature: needsSignature,
    p_ref_devis: refDevis,
  });
  if (error) throw new Error(explain(error));
  if (!data) throw new Error("La base n'a rien renvoye : document non emis.");
  return docFromDb(Array.isArray(data) ? data[0] : data);
}

/** Traduit les erreurs techniques Supabase en message actionnable. */
function explain(error) {
  const msg = error?.message || String(error);
  if (/could not find the function|does not exist/i.test(msg) && /secoto_(emit|sign)_document/i.test(msg)) {
    return "Le patch SQL des documents n'a pas encore ete applique dans Supabase. "
      + "Lancez patch_documents_signature.sql dans le SQL Editor, puis reessayez.";
  }
  if (/schema cache/i.test(msg)) {
    return "Supabase n'a pas encore recharge son schema. Relancez « notify pgrst, 'reload schema'; » "
      + "dans le SQL Editor, puis reessayez.";
  }
  if (/reservee a l'administrateur|reservee a l''administrateur/i.test(msg)) {
    return "Seul un compte administrateur SECOTO peut emettre un document.";
  }
  return msg;
}

/**
 * Etape 1 — a l'attribution d'une mission :
 *   - le DEVIS part au client (a signer) ;
 *   - le BON DE MISSION est prepare en brouillon, invisible du transporteur
 *     tant que le client n'a pas signe.
 * Ne bloque jamais l'attribution : renvoie la liste des envois et des ecarts.
 */
export async function emitOnAssignment(mission, transporter = {}) {
  const done = [];
  const skipped = [];

  // --- Devis client ---
  if (mission.clientAccountId) {
    try {
      const html = renderDevisHtml(mission);
      const devis = await emit({
        missionId: mission.id, type: 'devis', html,
        recipientId: mission.clientAccountId, statut: 'envoye', needsSignature: true,
      });
      done.push(`Devis ${devis.numero} envoye au client`);
    } catch (e) {
      skipped.push(`Devis non envoye : ${e.message}`);
    }
  } else {
    skipped.push("Devis non envoye : la course n'est pas reliee a un compte client.");
  }

  // --- Bon de mission (brouillon) ---
  const transporterId = mission.assignedTransporterId || transporter.id;
  if (transporterId) {
    try {
      const html = renderBonMissionHtml(mission, {
        name: transporter.fullName || mission.assignedTransporterName || '',
        address: transporter.city || '',
        siret: transporter.siret || '',
        phone: transporter.phone || '',
      });
      await emit({
        missionId: mission.id, type: 'bon_de_mission', html,
        recipientId: transporterId,
        // Si la course n'a pas de compte client, personne ne signera le devis :
        // on envoie donc le bon de mission tout de suite.
        statut: mission.clientAccountId ? 'brouillon' : 'envoye',
        needsSignature: true,
      });
      done.push(
        mission.clientAccountId
          ? 'Bon de mission prepare (il partira des la signature du client)'
          : 'Bon de mission envoye au transporteur'
      );
    } catch (e) {
      skipped.push(`Bon de mission non prepare : ${e.message}`);
    }
  } else {
    skipped.push('Bon de mission non prepare : aucun transporteur attribue.');
  }

  return { done, skipped };
}

/** Etape 4 — envoi manuel de la facture au client (decide par l'admin). */
export async function emitFacture(mission, { refDevis = null } = {}) {
  const html = renderFactureHtml(mission, {}, refDevis ? { refDevis } : {});
  return emit({
    missionId: mission.id, type: 'facture', html,
    recipientId: mission.clientAccountId,
    statut: 'envoye',
    needsSignature: false,   // une facture se telecharge, elle ne se signe pas
    refDevis,
  });
}

/** Signature par le destinataire (client ou transporteur). */
export async function signDocument(docId, signature) {
  const { data, error } = await supabase.rpc('secoto_sign_document', {
    p_doc: docId,
    p_signature: signature,
  });
  if (error) throw new Error(explain(error));
  return docFromDb(Array.isArray(data) ? data[0] : data);
}

/**
 * Incruste la signature en bas du document fige, pour l'affichage et le
 * telechargement. Le HTML stocke en base, lui, n'est jamais modifie.
 */
export function withSignature(doc) {
  const sig = doc.docType === 'bon_de_mission' ? doc.signatureTransporteur : doc.signatureClient;
  if (!doc.html) return '';
  if (!sig?.data_url) return doc.html;

  const when = sig.signed_at
    ? new Date(sig.signed_at).toLocaleString('fr-FR', {
        day: '2-digit', month: '2-digit', year: 'numeric', hour: '2-digit', minute: '2-digit',
      })
    : '';

  const block = `
  <div style="margin:24px 18px;padding:14px 16px;border:1px solid #cbd5e1;border-radius:10px;font-family:Arial,Helvetica,sans-serif;">
    <div style="font-size:11px;letter-spacing:.08em;text-transform:uppercase;color:#64748b;margin-bottom:8px;">
      Signature electronique
    </div>
    <img src="${sig.data_url}" alt="Signature" style="max-height:90px;display:block;margin-bottom:8px;" />
    <div style="font-size:12px;color:#0f172a;">
      <strong>${escapeHtml(sig.signer_name || '')}</strong>${when ? ` — signe le ${when}` : ''}
    </div>
    <div style="font-size:11px;color:#64748b;margin-top:4px;">
      Document ${escapeHtml(doc.numero || '')} — signature apposee depuis l'application SECOTO.
    </div>
  </div>`;

  return doc.html.includes('</body>')
    ? doc.html.replace('</body>', `${block}</body>`)
    : doc.html + block;
}

function escapeHtml(s) {
  return String(s).replace(/[&<>"']/g, (c) => (
    { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]
  ));
}

/** Telechargement du document (fichier HTML autonome, imprimable en PDF). */
export function downloadDocument(doc) {
  const html = withSignature(doc);
  if (!html) throw new Error('Document indisponible.');
  const blob = new Blob([html], { type: 'text/html;charset=utf-8' });
  const url = URL.createObjectURL(blob);
  const a = document.createElement('a');
  a.href = url;
  a.download = `${doc.numero || DOC_LABEL[doc.docType] || 'document'}.html`;
  document.body.appendChild(a);
  a.click();
  document.body.removeChild(a);
  setTimeout(() => URL.revokeObjectURL(url), 4000);
}
