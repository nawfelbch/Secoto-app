// SECOTO — SMS envoyé au client avec son lien de paiement.
// ----------------------------------------------------------------------------
// Il doit donner envie de payer tout de suite, sans jargon : le prix tout
// compris, la date, le lien court en action unique, et ce qui rassure
// (remboursement intégral si personne n'accepte). Pas de téléphone, pas d'emoji.

// Lien court : /payer est réécrit vers la fonction devis-pay (netlify.toml).
export function lienCourt(url) {
  return String(url || "").replace("/.netlify/functions/devis-pay?", "/payer?");
}

// Prénom seulement s'il ressemble à un vrai nom (pas « Demande sans compte »,
// pas une adresse e-mail, pas un nom de société en majuscules).
export function prenomClient(nom) {
  const v = String(nom || "").trim();
  if (!v || /demande sans compte|@|\d/i.test(v)) return "";
  const premier = v.split(/\s+/)[0];
  if (premier.length < 2 || premier.length > 20 || premier === premier.toUpperCase()) return "";
  return premier.charAt(0).toUpperCase() + premier.slice(1);
}

export function montantLisible(cents) {
  const euros = Number(cents || 0) / 100;
  return Number.isInteger(euros)
    ? `${euros.toLocaleString("fr-FR")} €`
    : `${euros.toLocaleString("fr-FR", { minimumFractionDigits: 2, maximumFractionDigits: 2 })} €`;
}

export function dateLisible(iso) {
  if (!iso) return "";
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return "";
  return d.toLocaleDateString("fr-FR", { weekday: "long", day: "numeric", month: "long", timeZone: "Europe/Paris" });
}

export function messageDevisSms({ client, trajet, amountCents, url, pickupAt, mode, vehicules = 1 }) {
  const prenom = prenomClient(client);
  const prestation = mode === "convoyage" ? "convoyage" : "transport sur plateau";
  const quand = dateLisible(pickupAt);
  // Une seule action : le lien, seul sur sa ligne, juste après le prix.
  return [
    `Bonjour${prenom ? ` ${prenom}` : ""},`,
    `Votre ${prestation} ${trajet}${vehicules > 1 ? ` (${vehicules} véhicules)` : ""} est prêt : ${montantLisible(amountCents)} tout compris (carburant, péages, assurance)${quand ? `, prise en charge le ${quand}` : ""}.`,
    "",
    "Réservez maintenant en 1 minute, paiement sécurisé :",
    lienCourt(url),
    "",
    "Remboursé intégralement si aucun transporteur n'est disponible. Suivi de votre véhicule en direct dans l'app SECOTO. Le paiement vaut acceptation du devis.",
    "SECOTO",
  ].join("\n");
}
