// ============================================================================
// SECOTO — Moteur de rendu des documents (devis / bon de mission / facture).
// ----------------------------------------------------------------------------
//  - Remplace les jetons {{VARIABLE}} d'une maquette HTML.
//  - STRICT : toute variable non resolue leve une erreur explicite ; aucun
//    {{...}} ne peut subsister dans le PDF final.
//  - Cloisonnement : chaque type de document declare la liste EXHAUSTIVE de
//    ses jetons autorises. Un jeton interdit (ex. un montant client dans le
//    bon de mission) fait echouer la generation.
// ============================================================================

/** Jetons autorises par type de document (reflet des maquettes). */
export const ALLOWED_TOKENS = {
  devis: [
    'NUMERO_DOC', 'DATE_DOC', 'CLIENT_NOM', 'CLIENT_TYPE', 'CLIENT_CONTACT',
    'VEHICULE', 'ADRESSE_DEPART', 'ADRESSE_ARRIVEE', 'DATE_ENLEVEMENT',
    'DATE_LIVRAISON', 'DISTANCE', 'CONTACT_SUR_PLACE', 'LIGNE_DETAIL',
    'LIGNE_DISTANCE', 'LIGNE_MONTANT', 'TOTAL', 'CONDITION_DATES',
  ],
  'bon-de-mission': [
    'NUMERO_DOC', 'DATE_DOC', 'TRANSPORTEUR_NOM', 'TRANSPORTEUR_ADRESSE',
    'TRANSPORTEUR_SIRET', 'TRANSPORTEUR_TEL', 'VEHICULE', 'ADRESSE_DEPART',
    'ADRESSE_ARRIVEE', 'CONTACT_DEPART', 'CONTACT_ARRIVEE', 'DATE_ENLEVEMENT',
    'DATE_LIVRAISON', 'DISTANCE', 'LIGNE_TRAJET', 'LIGNE_VEHICULE',
    'LIGNE_DISTANCE', 'LIGNE_MONTANT', 'TOTAL_TRANSPORTEUR',
  ],
  facture: [
    'NUMERO_DOC', 'DATE_DOC', 'DATE_ECHEANCE', 'REF_DEVIS', 'CLIENT_NOM',
    'CLIENT_TYPE', 'CLIENT_CONTACT', 'VEHICULE', 'ADRESSE_DEPART',
    'ADRESSE_ARRIVEE', 'DATE_LIVRAISON', 'DISTANCE', 'LIGNE_DETAIL',
    'LIGNE_DISTANCE', 'LIGNE_MONTANT', 'TOTAL', 'TITULAIRE_COMPTE',
    'IBAN', 'BIC',
  ],
};

/** Jetons strictement interdits sur le bon de mission (montant client). */
export const CLIENT_ONLY_TOKENS = [
  'TOTAL', 'PRIX_CLIENT', 'MARGE', 'MARGIN', 'CLIENT_MONTANT', 'COUT_CLIENT',
];

const TOKEN_RE = /\{\{\s*([A-Z0-9_]+)\s*\}\}/g;

/** Liste des jetons presents dans une maquette. */
export function extractTokens(html) {
  const found = new Set();
  let m;
  const re = new RegExp(TOKEN_RE);
  while ((m = re.exec(html)) !== null) found.add(m[1]);
  return [...found];
}

/**
 * Rend une maquette en remplacant ses {{JETONS}} par les valeurs de `data`.
 * Leve une erreur si une variable manque, est nulle, hors allowlist, interdite
 * (bon de mission), ou si un {{...}} subsiste apres substitution.
 * @param {string} html
 * @param {Record<string, string|number>} data
 * @param {{kind?: 'devis'|'bon-de-mission'|'facture'}} [opts]
 */
export function renderTemplate(html, data, opts = {}) {
  const tokens = extractTokens(html);

  if (opts.kind) {
    const allowed = new Set(ALLOWED_TOKENS[opts.kind] || []);
    const illegal = tokens.filter((t) => !allowed.has(t));
    if (illegal.length) {
      throw new Error(`templateEngine: jeton(s) hors perimetre dans « ${opts.kind} » : ${illegal.join(', ')}.`);
    }
    if (opts.kind === 'bon-de-mission') {
      const leaked = tokens.filter((t) => CLIENT_ONLY_TOKENS.includes(t));
      if (leaked.length) {
        throw new Error(`templateEngine: FUITE de montant client dans le bon de mission : ${leaked.join(', ')}.`);
      }
    }
  }

  const missing = [];
  const out = html.replace(TOKEN_RE, (_full, name) => {
    const v = data ? data[name] : undefined;
    if (v === undefined || v === null) {
      missing.push(name);
      return `{{${name}}}`;
    }
    return String(v);
  });

  if (missing.length) {
    throw new Error(`templateEngine: variable(s) non resolue(s) : ${[...new Set(missing)].join(', ')}.`);
  }
  const leftover = out.match(TOKEN_RE);
  if (leftover) {
    throw new Error(`templateEngine: jeton(s) residuel(s) apres rendu : ${leftover.join(', ')}.`);
  }
  return out;
}

/**
 * Garde-fou runtime : verifie qu'aucune valeur interdite (prix client, marge)
 * n'apparait dans un HTML rendu destine au transporteur.
 */
export function assertNoValueLeak(renderedHtml, forbiddenValues) {
  for (const raw of forbiddenValues || []) {
    const needle = String(raw);
    if (needle && renderedHtml.includes(needle)) {
      throw new Error(`templateEngine: valeur interdite detectee dans le rendu : « ${needle} ».`);
    }
  }
}
