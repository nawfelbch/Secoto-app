// SECOTO — SMS envoyé au client avec son lien de paiement.
// ----------------------------------------------------------------------------
// Il doit donner envie de payer tout de suite, sans jargon : le prix tout
// compris, la date, le lien court en action unique, et ce qui rassure
// (100 : 0 € aujourd'hui, règlement à l'arrivée ; avant : remboursement
// intégral si personne n'accepte). Pas de téléphone, pas d'emoji.

// Lien court : /payer est réécrit vers la fonction devis-pay (netlify.toml).
export function lienCourt(url) {
  return String(url || "").replace("/.netlify/functions/devis-pay?", "/payer?");
}

// 116 : le message prédéfini part du téléphone de l'admin (SMS ou WhatsApp).
// WhatsApp veut le numéro international sans « + » : 06… → 336…
export function numeroWhatsApp(tel) {
  const d = String(tel || "").replace(/\D/g, "");
  if (d.startsWith("00")) return d.slice(2);
  if (d.length === 10 && d.startsWith("0")) return `33${d.slice(1)}`;
  return d;
}

export function lienSms(tel, texte) {
  return `sms:${String(tel || "").replace(/[^\d+]/g, "")}?&body=${encodeURIComponent(texte || "")}`;
}

export function lienWhatsApp(tel, texte) {
  return `https://wa.me/${numeroWhatsApp(tel)}?text=${encodeURIComponent(texte || "")}`;
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

// Espèces : interdites au-delà de 1 000 € (article L112-6 du code monétaire).
const PLAFOND_ESPECES_CENTS = 100000;

// FOMO honnête : la durée de validité réellement fixée sur le devis, et la date
// demandée (un camion ne prend que quelques véhicules par tournée).
export function urgence(validiteHeures, quand) {
  const h = Math.round(Number(validiteHeures) || 0);
  const garantie = h <= 0 ? "" : h <= 72 ? ` Ce prix est garanti ${h} h seulement.` : ` Ce prix est garanti ${Math.floor(h / 24)} jours.`;
  const date = quand ? `Les places du ${quand} sont limitées : nos transporteurs organisent leurs tournées à l'avance.` : "Nos transporteurs organisent leurs tournées à l'avance : les premières réservations sont servies en premier.";
  return `${date}${garantie}`;
}

export function messageDevisSms({ client, trajet, amountCents, url, pickupAt, mode, vehicules = 1, arrivee = true, validiteHeures = 0 }) {
  const prenom = prenomClient(client);
  const prestation = mode === "convoyage" ? "convoyage" : "transport sur plateau";
  const quand = dateLisible(pickupAt);
  const prix = `${montantLisible(amountCents)} tout compris (carburant et péages)${quand ? `, prise en charge le ${quand}` : ""}.`;
  const objet = `${prestation} ${trajet}${vehicules > 1 ? ` (${vehicules} véhicules)` : ""}`;
  if (!arrivee) {
    // Une seule action : le lien, seul sur sa ligne, juste après le prix.
    return [
      `Bonjour${prenom ? ` ${prenom}` : ""},`,
      `Votre ${objet} est prêt : ${prix}`,
      "",
      "Réservez maintenant en 1 minute, paiement sécurisé :",
      lienCourt(url),
      "",
      "Remboursé intégralement si aucun transporteur n'est disponible. Suivi de votre véhicule en direct dans l'app SECOTO. Le paiement vaut acceptation du devis.",
      "SECOTO",
    ].join("\n");
  }
  // 100 : rien à payer à la réservation. Le lien reste l'action unique.
  const moyens = Number(amountCents || 0) <= PLAFOND_ESPECES_CENTS
    ? "par carte, en plusieurs fois avec Klarna, par virement ou en espèces"
    : "par carte, en plusieurs fois avec Klarna ou par virement";
  return [
    `Bonjour${prenom ? ` ${prenom}` : ""},`,
    `Bonne nouvelle : votre ${objet} est prêt. ${prix}`,
    "",
    `0 € à payer aujourd'hui. Vous ne réglez qu'à l'arrivée de votre véhicule, ${moyens}.`,
    "",
    urgence(validiteHeures, quand),
    "",
    "Bloquez votre date maintenant, en 1 minute :",
    lienCourt(url),
    "",
    "Transporteur validé par SECOTO, état des lieux en photos au départ et à l'arrivée, suivi en direct dans l'app SECOTO. La réservation vaut acceptation du devis.",
    "SECOTO",
  ].join("\n");
}
