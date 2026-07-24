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
import devisTpl from '../../templates/devis.html?raw';
import bonMissionTpl from '../../templates/bon-de-mission.html?raw';
import factureTpl from '../../templates/facture.html?raw';

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

/**
 * Synchronise les maquettes HTML vers la base (admin uniquement).
 * C'est ce qui permet a la BASE de fabriquer elle-meme les documents, donc
 * d'envoyer le devis automatiquement a l'attribution, sans dependre de
 * l'application. A appeler une fois a l'ouverture de l'espace admin.
 */
export async function syncDocTemplates() {
  const kinds = [
    ['devis', devisTpl],
    ['bon_de_mission', bonMissionTpl],
    ['facture', factureTpl],
  ];
  const failed = [];
  for (const [kind, html] of kinds) {
    const { error } = await supabase.rpc('secoto_save_doc_template', { p_kind: kind, p_html: html });
    if (error) failed.push(`${kind} (${error.message})`);
  }
  if (failed.length) throw new Error(`Maquettes non synchronisees : ${failed.join(', ')}`);
  return true;
}

/** Traduit les erreurs techniques Supabase en message actionnable. */
function explain(error) {
  const msg = error?.message || String(error);
  if (/could not find the function|does not exist/i.test(msg) && /secoto_/i.test(msg)) {
    return "Un patch SQL n'a pas encore ete applique dans Supabase. "
      + "Lancez patch_documents_signature.sql puis patch_devis_automatique.sql, puis reessayez.";
  }
  if (/maquette/i.test(msg)) {
    return msg + " (les maquettes se synchronisent a l'ouverture de l'espace administrateur)";
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
 * Renvoi manuel du devis + du bon de mission (bouton admin).
 * L'envoi normal est declenche AUTOMATIQUEMENT par la base des que la mission
 * passe en « attribuee » : cette fonction sert de rattrapage.
 */
export async function emitMissionDocuments(missionId) {
  const { data, error } = await supabase.rpc('secoto_emit_mission_documents', { p_mission: missionId });
  if (error) throw new Error(explain(error));
  return data || 'Documents emis.';
}

/** Etape finale — envoi de la facture au client (decide par l'admin). */
export async function emitFacture(missionId) {
  const { data, error } = await supabase.rpc('secoto_emit_facture', { p_mission: missionId });
  if (error) throw new Error(explain(error));
  return data || 'Facture envoyee.';
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
