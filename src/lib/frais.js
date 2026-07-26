// ============================================================================
// SECOTO — Frais reels (essence / peage) : couche donnees Supabase.
// ----------------------------------------------------------------------------
//  - Le transporteur remonte un frais (montant + justificatif) en 'en_attente'.
//  - L'admin valide ('valide') ou refuse ('refuse' + motif).
//  - Le remboursement n'est declenche qu'apres passage en 'valide'.
//  - Justificatifs stockes dans le bucket prive 'justificatifs' :
//    chemin  {transporter_id}/{mission_id}/{fichier}
// ============================================================================

import { supabase } from '../supabaseClient';
import {
  buildPrivateFilePath,
  randomIdempotencyKey,
  validateFiles,
} from './fileSafety';
import { createShortSignedUrl, uploadPrivateFile } from './privateFiles';

export const FRAIS_TYPES = [
  { value: 'essence', label: 'Essence' },
  { value: 'peage', label: 'Peage' },
];

export function fraisFromDb(row) {
  return {
    id: row.id,
    missionId: row.mission_id,
    transporterId: row.transporter_id,
    type: row.type,
    montant: row.montant,
    // Cette colonne contient désormais un chemin privé, jamais une URL publique.
    justificatifUrl: row.justificatif_path || row.justificatif_url,
    statut: row.statut,
    motifRefus: row.motif_refus,
    date: row.date,
    createdAt: row.created_at,
    validatedAt: row.validated_at,
  };
}

/** Liste les frais du transporteur courant (RLS filtre deja). */
export async function listMyFrais(transporterId) {
  const { data, error } = await supabase
    .from('frais')
    .select('id,mission_id,transporter_id,type,montant,justificatif_path,justificatif_url,statut,motif_refus,date,created_at,validated_at')
    .eq('transporter_id', transporterId)
    .order('created_at', { ascending: false })
    .limit(200);
  if (error) throw error;
  return (data || []).map(fraisFromDb);
}

/** Liste tous les frais (admin ; RLS autorise l'admin). */
export async function listAllFrais() {
  const { data, error } = await supabase
    .from('frais')
    .select('id,mission_id,transporter_id,type,montant,justificatif_path,justificatif_url,statut,motif_refus,date,created_at,validated_at')
    .order('created_at', { ascending: false })
    .limit(200);
  if (error) throw error;
  return (data || []).map(fraisFromDb);
}

/**
 * Cree un frais + uploade le justificatif.
 * @param {{transporterId:string, missionId:string, type:string, montant:number, file:File}} p
 */
export async function createFrais({
  transporterId,
  missionId,
  type,
  montant,
  file,
  operationId = randomIdempotencyKey(),
  onProgress,
}) {
  if (!missionId) throw new Error('Selectionnez la mission concernee.');
  if (!(Number(montant) > 0)) throw new Error('Montant invalide.');
  if (!file) throw new Error('Ajoutez le justificatif (photo ou PDF).');
  if (!FRAIS_TYPES.some((candidate) => candidate.value === type)) throw new Error('Type de frais invalide.');
  const validation = validateFiles([file], {
    allowPdf: true,
    maxFiles: 1,
    maxSizeBytes: 12 * 1024 * 1024,
    minFiles: 1,
  });
  if (!validation.ok) throw new Error(validation.errors.join(' '));

  const path = await buildPrivateFilePath({
    accountId: transporterId,
    missionId,
    operationId,
    index: 0,
    file,
  });

  await uploadPrivateFile({
    bucket: 'justificatifs',
    path,
    file,
    onProgress,
  });

  const { data, error } = await supabase
    .rpc('secoto_create_expense', {
      p_mission_id: missionId,
      p_type: type,
      p_amount: Number(montant),
      p_file_name: file.name,
      p_file_path: path,
      p_mime_type: file.type,
      p_size_bytes: file.size,
      p_idempotency_key: operationId,
    });
  if (error) throw error;
  return fraisFromDb(Array.isArray(data) ? data[0] : data);
}

/** Valide un frais (admin). Declenche l'eligibilite au remboursement. */
export async function validateFrais(id) {
  const { error } = await supabase.rpc('secoto_admin_review_expense', {
    p_expense_id: id,
    p_decision: 'valide',
    p_reason: null,
    p_idempotency_key: randomIdempotencyKey(),
  });
  if (error) throw error;
}

/** Refuse un frais (admin) avec motif obligatoire. */
export async function refuseFrais(id, motif) {
  if (!motif || !motif.trim()) throw new Error('Motif de refus obligatoire.');
  const { error } = await supabase.rpc('secoto_admin_review_expense', {
    p_expense_id: id,
    p_decision: 'refuse',
    p_reason: motif.trim(),
    p_idempotency_key: randomIdempotencyKey(),
  });
  if (error) throw error;
}

/** URL signee (120 s) pour consulter un justificatif. */
export async function justificatifUrl(path) {
  return createShortSignedUrl('justificatifs', path, 120);
}

/** Total remboursable = somme des frais valides. */
export function totalRemboursable(fraisList) {
  return (fraisList || [])
    .filter((f) => f.statut === 'valide')
    .reduce((sum, f) => sum + Number(f.montant || 0), 0);
}
