// ============================================================================
// SECOTO — Generation des documents (devis / bon de mission / facture).
// ----------------------------------------------------------------------------
// Utilise les maquettes HTML (templates/*.html) + le moteur de rendu strict
// (templateEngine) + le bareme (pricing). Respecte le cloisonnement :
//  - devis / facture : montants CLIENT uniquement.
//  - bon de mission  : remuneration TRANSPORTEUR uniquement (jamais le client).
// La numerotation est atomique cote base (RPC secoto_next_doc_number).
// ============================================================================

import devisTpl from '../../templates/devis.html?raw';
import bonMissionTpl from '../../templates/bon-de-mission.html?raw';
import factureTpl from '../../templates/facture.html?raw';
import { renderTemplate, assertNoValueLeak } from './templateEngine';
import { computeClientPrice, computeCarrierPay, formatAmount } from './pricing';
import { supabase } from '../supabaseClient';

const DESIGNATION = 'Prestation de mise en relation'; // obligatoire cote client
const MENTION_TVA = 'TVA non applicable, art. 293 B du CGI';

function frDate(value) {
  if (!value) return '';
  const d = new Date(value);
  if (Number.isNaN(d.getTime())) return String(value);
  return d.toLocaleDateString('fr-FR', { day: '2-digit', month: '2-digit', year: 'numeric' });
}

function distanceLabel(m) {
  return m.distanceKm ? `${Number(m.distanceKm)} km` : 'Non renseignee';
}

/** Numero atomique cote base : DEV-/BM-/FAC-AAAAMM-NNN. */
export async function nextDocNumber(docType) {
  const { data, error } = await supabase.rpc('secoto_next_doc_number', { p_type: docType });
  if (error) throw new Error(`Numerotation impossible (${docType}) : ${error.message}`);
  return data;
}

// ----------------------------------------------------------------------------
// DEVIS (client)
// ----------------------------------------------------------------------------
export function renderDevisHtml(mission, opts = {}) {
  const client = computeClientPrice(mission);
  const numero = opts.numero || 'DEV-AAAAMM-000';
  const data = {
    NUMERO_DOC: numero,
    DATE_DOC: opts.dateDoc || frDate(new Date()),
    CLIENT_NOM: mission.clientName || 'Client',
    CLIENT_TYPE: mission.clientType === 'particulier' ? 'Particulier' : 'Professionnel',
    CLIENT_CONTACT: mission.clientContact || mission.clientPhone || '',
    VEHICULE: mission.vehicle || 'Non renseigne',
    ADRESSE_DEPART: mission.pickupAddress || mission.fromCity || '',
    ADRESSE_ARRIVEE: mission.deliveryAddress || mission.toCity || '',
    DATE_ENLEVEMENT: frDate(mission.missionDate),
    DATE_LIVRAISON: opts.dateLivraison ? frDate(opts.dateLivraison) : frDate(mission.missionDate),
    DISTANCE: distanceLabel(mission),
    CONTACT_SUR_PLACE: opts.contactSurPlace || mission.clientContact || '',
    LIGNE_DETAIL: DESIGNATION,
    LIGNE_DISTANCE: distanceLabel(mission),
    LIGNE_MONTANT: formatAmount(client),
    TOTAL: formatAmount(client),
    CONDITION_DATES: opts.conditionDates || 'Dates indicatives, a confirmer selon disponibilite.',
  };
  return renderTemplate(devisTpl, data, { kind: 'devis' });
}

// ----------------------------------------------------------------------------
// BON DE MISSION (transporteur) — jamais de montant client
// ----------------------------------------------------------------------------
export function renderBonMissionHtml(mission, transporter = {}, opts = {}) {
  const carrier = computeCarrierPay(mission);
  const numero = opts.numero || 'BM-AAAAMM-000';
  const data = {
    NUMERO_DOC: numero,
    DATE_DOC: opts.dateDoc || frDate(new Date()),
    TRANSPORTEUR_NOM: transporter.name || mission.assignedTransporterName || 'Transporteur',
    TRANSPORTEUR_ADRESSE: transporter.address || '',
    TRANSPORTEUR_SIRET: transporter.siret || '',
    TRANSPORTEUR_TEL: transporter.phone || '',
    VEHICULE: mission.vehicle || 'Non renseigne',
    ADRESSE_DEPART: mission.pickupAddress || mission.fromCity || '',
    ADRESSE_ARRIVEE: mission.deliveryAddress || mission.toCity || '',
    CONTACT_DEPART: opts.contactDepart || '',
    CONTACT_ARRIVEE: opts.contactArrivee || '',
    DATE_ENLEVEMENT: frDate(mission.missionDate),
    DATE_LIVRAISON: opts.dateLivraison ? frDate(opts.dateLivraison) : frDate(mission.missionDate),
    DISTANCE: distanceLabel(mission),
    LIGNE_TRAJET: `${mission.fromCity || ''} > ${mission.toCity || ''}`,
    LIGNE_VEHICULE: mission.vehicle || 'Non renseigne',
    LIGNE_DISTANCE: distanceLabel(mission),
    LIGNE_MONTANT: formatAmount(carrier),
    TOTAL_TRANSPORTEUR: formatAmount(carrier),
  };
  const html = renderTemplate(bonMissionTpl, data, { kind: 'bon-de-mission' });
  // Garde-fou : le prix client ne doit jamais apparaitre dans ce document.
  assertNoValueLeak(html, [formatAmount(computeClientPrice(mission))]);
  return html;
}

// ----------------------------------------------------------------------------
// FACTURE (client)
// ----------------------------------------------------------------------------
export function renderFactureHtml(mission, settings = {}, opts = {}) {
  const client = computeClientPrice(mission);
  const numero = opts.numero || 'FAC-AAAAMM-000';
  const bank = settings.bank_details || settings || {};
  const data = {
    NUMERO_DOC: numero,
    DATE_DOC: opts.dateDoc || frDate(new Date()),
    DATE_ECHEANCE: opts.dateEcheance || frDate(new Date()),
    REF_DEVIS: opts.refDevis || '',
    CLIENT_NOM: mission.clientName || 'Client',
    CLIENT_TYPE: mission.clientType === 'particulier' ? 'Particulier' : 'Professionnel',
    CLIENT_CONTACT: mission.clientContact || mission.clientPhone || '',
    VEHICULE: mission.vehicle || 'Non renseigne',
    ADRESSE_DEPART: mission.pickupAddress || mission.fromCity || '',
    ADRESSE_ARRIVEE: mission.deliveryAddress || mission.toCity || '',
    DATE_LIVRAISON: opts.dateLivraison ? frDate(opts.dateLivraison) : frDate(mission.missionDate),
    DISTANCE: distanceLabel(mission),
    LIGNE_DETAIL: DESIGNATION,
    LIGNE_DISTANCE: distanceLabel(mission),
    LIGNE_MONTANT: formatAmount(client),
    TOTAL: formatAmount(client),
    TITULAIRE_COMPTE: bank.titulaire || 'SECOTO',
    IBAN: bank.iban || '',
    BIC: bank.bic || '',
  };
  return renderTemplate(factureTpl, data, { kind: 'facture' });
}

/** Ouvre un document HTML dans un nouvel onglet pret a imprimer en PDF (A4). */
export function openDocumentForPrint(html) {
  const w = window.open('', '_blank');
  if (!w) throw new Error('Fenetre bloquee par le navigateur. Autorisez les pop-ups.');
  w.document.open();
  w.document.write(html);
  w.document.close();
  return w;
}

export const DOC_MENTION_TVA = MENTION_TVA;
