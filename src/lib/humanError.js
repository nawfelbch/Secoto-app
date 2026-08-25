// ============================================================================
// SECOTO — traduction des erreurs techniques en messages compréhensibles.
// ----------------------------------------------------------------------------
// Règle : l'utilisateur ne doit JAMAIS voir un message brut de PostgREST,
// de PostgreSQL, de Supabase Auth ou du réseau (« schema cache », « candidate
// function », « JWT expired », « Failed to fetch »…). Ces messages exposent le
// fonctionnement interne de l'application et sont incompréhensibles.
//
// En revanche, les messages métier écrits EN FRANÇAIS par nos fonctions SQL
// (« Vous avez déjà candidaté à cette mission. », « Le devis doit être signé
// avant le paiement. »…) sont destinés à l'utilisateur : ils passent tels
// quels. Le détail technique original est journalisé en console pour le
// diagnostic, jamais affiché.
// ============================================================================

// Motifs qui trahissent une erreur technique, jamais destinée à l'écran.
const TECHNICAL_PATTERNS = [
  /schema cache/i,
  /could not find the function/i,
  /could not choose the best candidate/i,
  /candidate function/i,
  /does not exist/i,
  /permission denied/i,
  /row-level security/i,
  /violates .* constraint/i,
  /invalid input syntax/i,
  /syntax error/i,
  /duplicate key value/i,
  /deadlock detected/i,
  /stack depth/i,
  /null value in column/i,
  /operator does not exist/i,
  /^(pgrst|22|23|25|28|2d|3d|3f|40|42|53|54|55|57|58|xx|08)/i,
  /jwt/i,
  /token is expired/i,
  /refresh_token/i,
  /internal server error/i,
  /unexpected token/i,
  /json/i,
  /upstream/i,
  /service unavailable/i,
];

const NETWORK_PATTERNS = [
  /failed to fetch/i,
  /networkerror/i,
  /network request failed/i,
  /load failed/i,
  /fetch/i,
  /timeout/i,
  /timed? out/i,
  /aborted/i,
  /socket/i,
  /connection/i,
];

// Erreurs Supabase Auth (toujours en anglais) → message français équivalent.
const AUTH_TRANSLATIONS = [
  [/invalid login credentials/i, "E-mail ou mot de passe incorrect."],
  [/email not confirmed/i, "Confirmez votre adresse e-mail avant de vous connecter."],
  [/user already registered/i, "Un compte existe déjà avec cette adresse e-mail."],
  [/password should be at least/i, "Le mot de passe est trop court."],
  [/rate limit|too many requests/i, "Trop de tentatives. Patientez quelques minutes puis réessayez."],
  [/signup.*disabled/i, "Les inscriptions sont momentanément désactivées."],
  [/email.*invalid|invalid.*email/i, "Adresse e-mail invalide."],
];

// Un message métier écrit par nous : français (accents ou tournures usuelles).
const FRENCH_HINT = /[àâäçéèêëîïôöùûüÀÂÄÇÉÈÊËÎÏÔÖÙÛÜœŒ’]|^(Le |La |Les |L['’]|Un |Une |Votre |Vos |Vous |Cette |Ce |Ces |Aucun|Impossible|Renseignez|Cochez|Toutes?|Tarif|Mission|Compte|Paiement|Demande|Session|Connexion|Envoi|Nouvelle|Choisissez|Ajoutez|Seul)/;

const GENERIC_FALLBACK =
  "Une erreur est survenue. Réessayez dans un instant ou contactez SECOTO.";

/**
 * Retourne un message affichable à l'utilisateur.
 * @param {unknown} err     Erreur levée (Supabase, fetch, Error locale…)
 * @param {string} fallback Message d'action proposé par l'écran appelant.
 */
export function humanizeError(err, fallback = GENERIC_FALLBACK) {
  const message = String(
    (err && typeof err === "object" && "message" in err && err.message) || err || "",
  ).trim();
  const code = String((err && typeof err === "object" && err.code) || "");

  // Journal technique pour le diagnostic — jamais montré à l'utilisateur.
  if (typeof console !== "undefined" && message) {
    console.error("[SECOTO]", code || "-", message, err);
  }

  if (!message) return fallback;

  // 1. Nos fonctions SQL lèvent leurs messages métier avec le code P0001
  //    (`raise exception`) : ils sont écrits pour l'utilisateur.
  if (code === "P0001") return message;

  // 2. Traductions Auth connues.
  for (const [pattern, translation] of AUTH_TRANSLATIONS) {
    if (pattern.test(message)) return translation;
  }

  // 3. Cas techniques ciblés avec un message plus utile que le repli générique.
  if (/schema cache|candidate function|could not find the function/i.test(message)) {
    return "Le service est en cours de mise à jour. Réessayez dans une minute — si le problème persiste, contactez SECOTO.";
  }
  if (code.startsWith("PGRST") || TECHNICAL_PATTERNS.some((p) => p.test(message))) {
    // 23505 = doublon : l'action a déjà été prise en compte.
    if (code === "23505" || /duplicate key value/i.test(message)) {
      return "Cette action a déjà été enregistrée.";
    }
    if (code === "42501" || /permission denied|row-level security/i.test(message)) {
      return "Vous n'avez pas les droits nécessaires pour cette action.";
    }
    return fallback;
  }
  if (NETWORK_PATTERNS.some((p) => p.test(message))) {
    return "Connexion impossible. Vérifiez votre réseau puis réessayez.";
  }

  // 4. Message métier français (levé par notre code ou notre SQL) : affiché.
  if (FRENCH_HINT.test(message)) return message;

  // 5. Tout le reste (anglais, inconnu) : repli propre.
  return fallback;
}

export { GENERIC_FALLBACK };
