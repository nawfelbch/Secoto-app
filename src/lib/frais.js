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
    justificatifUrl: row.justificatif_url,
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
    .select('*')
    .eq('transporter_id', transporterId)
    .order('created_at', { ascending: false });
  if (error) throw error;
  return (data || []).map(fraisFromDb);
}

/** Liste tous les frais (admin ; RLS autorise l'admin). */
export async function listAllFrais() {
  const { data, error } = await supabase
    .from('frais')
    .select('*')
    .order('created_at', { ascending: false });
  if (error) throw error;
  return (data || []).map(fraisFromDb);
}

/**
 * Cree un frais + uploade le justificatif.
 * @param {{transporterId:string, missionId:string, type:string, montant:number, file:File}} p
 */
export async function createFrais({ transporterId, missionId, type, montant, file }) {
  if (!missionId) throw new Error('Selectionnez la mission concernee.');
  if (!(Number(montant) > 0)) throw new Error('Montant invalide.');
  if (!file) throw new Error('Ajoutez le justificatif (photo ou PDF).');

  const safeName = file.name.replace(/[^a-zA-Z0-9._-]/g, '_');
  const path = `${transporterId}/${missionId}/${Date.now()}_${safeName}`;

  const { error: upErr } = await supabase.storage
    .from('justificatifs')
    .upload(path, file, { upsert: false });
  if (upErr) throw new Error(`Upload du justificatif impossible : ${upErr.message}`);

  const { data, error } = await supabase
    .from('frais')
    .insert({
      transporter_id: transporterId,
      mission_id: missionId,
      type,
      montant: Number(montant),
      justificatif_url: path,
      statut: 'en_attente',
    })
    .select()
    .single();
  if (error) throw error;
  return fraisFromDb(data);
}

/** Valide un frais (admin). Declenche l'eligibilite au remboursement. */
export async function validateFrais(id) {
  const { error } = await supabase
    .from('frais')
    .update({ statut: 'valide', validated_at: new Date().toISOString(), motif_refus: null })
    .eq('id', id);
  if (error) throw error;
}

/** Refuse un frais (admin) avec motif obligatoire. */
export async function refuseFrais(id, motif) {
  if (!motif || !motif.trim()) throw new Error('Motif de refus obligatoire.');
  const { error } = await supabase
    .from('frais')
    .update({ statut: 'refuse', motif_refus: motif.trim(), validated_at: new Date().toISOString() })
    .eq('id', id);
  if (error) throw error;
}

/** URL signee (120 s) pour consulter un justificatif. */
export async function justificatifUrl(path) {
  const { data, error } = await supabase.storage.from('justificatifs').createSignedUrl(path, 120);
  if (error) throw error;
  return data.signedUrl;
}

/** Total remboursable = somme des frais valides. */
export function totalRemboursable(fraisList) {
  return (fraisList || [])
    .filter((f) => f.statut === 'valide')
    .reduce((sum, f) => sum + Number(f.montant || 0), 0);
}
