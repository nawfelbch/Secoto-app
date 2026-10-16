// SECOTO — Réserver sans créer de compte (prix déjà affiché).
// ----------------------------------------------------------------------------
// Constat du 16/10/2026 : 19 visiteurs Google ont vu leur prix, aucun n'a créé
// de compte. Le formulaire d'inscription (rôle, type de client, mot de passe…)
// les arrêtait juste avant de payer.
//
// Ici, le client donne seulement son nom et son e-mail. L'app crée son compte
// client toute seule, avec un mot de passe aléatoire qu'il n'a pas à retenir
// (il reste connecté sur l'appareil ; « Mot de passe oublié » s'il revient
// d'ailleurs). La suite ne change pas : le devis est rattaché au compte et le
// paiement s'ouvre aussitôt (même chemin que l'inscription classique, 093).
import { normalizePublicSignupMetadata } from "./domainPolicy.js";
import { emailPropre } from "./contactDevis.js";

const ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789";

/** Mot de passe fort, jamais affiché ni stocké par l'app. */
export function motDePasseAleatoire(source = globalThis.crypto) {
  const octets = new Uint8Array(32);
  source.getRandomValues(octets);
  // 24 caractères + un chiffre et un symbole : passe toutes les règles de mot de passe usuelles.
  return `${Array.from(octets.slice(0, 24), (o) => ALPHABET[o % ALPHABET.length]).join("")}9!`;
}

/** L'adresse a déjà un compte : il faut se connecter, pas en recréer un. */
export function estCompteExistant(error, data) {
  const texte = `${error?.code || ""} ${error?.message || ""}`;
  if (/user_already_exists|already registered|already exists|email_exists/i.test(texte)) return true;
  // Confirmation d'e-mail activée : Supabase renvoie un faux compte sans identité.
  return !error && Array.isArray(data?.user?.identities) && data.user.identities.length === 0;
}

export function verifierSaisie({ nom, email }) {
  if (String(nom || "").trim().length < 2) return "Indiquez votre nom.";
  if (!emailPropre(email)) return "Vérifiez votre adresse e-mail (exemple : prenom@gmail.com).";
  return "";
}

/**
 * Crée le compte client en une action.
 * Renvoie { ok } (session ouverte), { existant } ou { confirmation } ; lève une
 * erreur lisible sinon.
 */
export async function creerCompteExpress({
  supabase, nom, email, telephone = "", termsVersion = null, platform = "web",
  redirection = undefined, attribution = undefined, consentement = undefined,
  aleatoire = globalThis.crypto,
}) {
  const probleme = verifierSaisie({ nom, email });
  if (probleme) throw new Error(probleme);
  const metadata = normalizePublicSignupMetadata({
    role: "client",
    client_type: "particulier",
    full_name: String(nom).trim(),
    phone: telephone || "",
    terms_version: termsVersion || undefined,
    terms_platform: platform,
  });
  const { data, error } = await supabase.auth.signUp({
    email: emailPropre(email),
    password: motDePasseAleatoire(aleatoire),
    options: {
      data: { ...metadata, attribution, consentement_pub: consentement, compte_express: true },
      emailRedirectTo: redirection,
    },
  });
  if (estCompteExistant(error, data)) return { existant: true };
  if (error) throw error;
  if (!data?.session) return { confirmation: true };
  return { ok: true, userId: data.user?.id || null };
}
