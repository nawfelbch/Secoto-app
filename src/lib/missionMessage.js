// ============================================================================
// SECOTO — message client pret a envoyer par SMS.
// ----------------------------------------------------------------------------
// Quand SECOTO retient un transporteur pour une mission, le client doit etre
// prevenu immediatement. L'application prepare le texte a partir de la carte
// de la mission (trajet, vehicule, telephone, tarif) : il ne reste qu'a
// appuyer sur « Envoyer par SMS », qui ouvre l'application Messages sur le
// numero renseigne, message deja ecrit.
//
// Aucune donnee n'est envoyee par SECOTO : c'est bien le telephone de
// l'administrateur qui envoie, depuis son propre numero.
// ============================================================================

import {
  computeCarrierPay,
  computeClientPrice,
  computeClientTotalDue,
  computeTransportAmount,
  formatAmount,
} from "./pricing.js";

/** Numero au format compose : +33... si possible, sinon les chiffres saisis. */
export function normalizePhone(raw) {
  const value = String(raw || "").trim();
  if (!value) return "";
  const plus = value.startsWith("+");
  const digits = value.replace(/\D/g, "");
  if (!digits) return "";
  if (plus) return `+${digits}`;
  if (digits.length === 10 && digits.startsWith("0")) return `+33${digits.slice(1)}`;
  if (digits.startsWith("33") && digits.length === 11) return `+${digits}`;
  return digits;
}

/** Affichage lisible : 06 25 35 32 35. */
export function displayPhone(raw) {
  const digits = String(raw || "").replace(/\D/g, "");
  if (digits.length === 10) return digits.replace(/(\d{2})(?=\d)/g, "$1 ").trim();
  return String(raw || "").trim();
}

function frDateTime(value) {
  if (!value) return "";
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return "";
  return date.toLocaleString("fr-FR", {
    weekday: "short",
    day: "2-digit",
    month: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
  });
}

function cityLine(mission) {
  const from = String(mission?.fromCity || "").trim() || "Départ";
  const to = String(mission?.toCity || "").trim() || "Arrivée";
  return `${from} → ${to}`;
}

function vehicleLine(mission) {
  const vehicle = String(mission?.vehicle || "").trim();
  const plate = String(mission?.plate || "").trim();
  if (vehicle && plate) return `${vehicle} (${plate})`;
  return vehicle || plate || "Véhicule à confirmer";
}

/**
 * Texte du SMS. `transporter` est facultatif : sans lui, les lignes
 * correspondantes sont simplement omises (jamais de « undefined »).
 */
export function buildClientAssignmentMessage(mission, transporter = null, options = {}) {
  if (!mission) return "";
  const lines = [];

  lines.push(`SECOTO — ${mission.publicRef || "votre transport"}`);
  lines.push(cityLine(mission));
  lines.push(vehicleLine(mission));

  const when = frDateTime(mission.missionDate);
  if (when) lines.push(`Enlèvement : ${when}`);

  const carrierName = String(
    transporter?.fullName || transporter?.companyName || mission.assignedTransporterName || "",
  ).trim();
  if (carrierName) lines.push(`Transporteur : ${carrierName}`);

  if (mission.type === "plateau") {
    const transport = computeTransportAmount(mission);
    const commission = computeClientPrice(mission);
    const total = computeClientTotalDue(mission);
    if (total > 0) {
      lines.push(
        `Montant : ${formatAmount(total)} `
        + `(transport ${formatAmount(transport)} + frais SECOTO ${formatAmount(commission)})`,
      );
    }
  } else {
    const total = computeClientPrice(mission);
    if (total > 0) lines.push(`Montant : ${formatAmount(total)}`);
  }

  const contact = displayPhone(mission.clientPhone);
  if (contact) lines.push(`Contact sur place : ${contact}`);

  if (options.trackingUrl) lines.push(`Suivi : ${options.trackingUrl}`);

  lines.push("Répondez OK pour confirmer.");
  return lines.join("\n");
}

/** Message court, calqué sur la fiche : « Paris → Lille Citroën C5 06 25 … ». */
export function buildShortAssignmentMessage(mission) {
  if (!mission) return "";
  return [cityLine(mission), vehicleLine(mission), displayPhone(mission.clientPhone)]
    .filter(Boolean)
    .join(" · ");
}

/** Rappel interne du prix : jamais envoyé au transporteur. */
export function buildCarrierBriefMessage(mission) {
  if (!mission) return "";
  const lines = [
    `SECOTO — ${mission.publicRef || "mission"}`,
    cityLine(mission),
    vehicleLine(mission),
  ];
  const when = frDateTime(mission.missionDate);
  if (when) lines.push(`Enlèvement : ${when}`);
  const pay = computeCarrierPay(mission);
  if (pay > 0) lines.push(`Votre rémunération : ${formatAmount(pay)}`);
  lines.push("Bon de mission à signer dans l’application SECOTO.");
  return lines.join("\n");
}

/**
 * Appareil Apple ? Detecte sans dependance native, pour que ce module reste
 * testable hors navigateur. La WebView Capacitor iOS annonce bien « iPhone ».
 */
export function isAppleDevice() {
  if (typeof navigator === "undefined") return false;
  const ua = `${navigator.userAgent || ""} ${navigator.platform || ""}`;
  return /iPad|iPhone|iPod|Macintosh/i.test(ua);
}

/**
 * Lien « sms: ». iOS attend `&body=`, Android et le Web `?body=`.
 * Sans numero, on ouvre quand meme le composeur avec le texte pret.
 */
export function buildSmsUrl(phone, body, { apple = isAppleDevice() } = {}) {
  const number = normalizePhone(phone);
  const text = encodeURIComponent(String(body || ""));
  const separator = apple ? "&" : "?";
  if (!number) return `sms:${separator}body=${text}`;
  return `sms:${number}${separator}body=${text}`;
}

/** Copie dans le presse-papiers, avec repli sur les navigateurs anciens. */
export async function copyToClipboard(text) {
  const value = String(text || "");
  if (!value) return false;
  try {
    if (typeof navigator !== "undefined" && navigator.clipboard?.writeText) {
      await navigator.clipboard.writeText(value);
      return true;
    }
  } catch {
    // On tente le repli ci-dessous.
  }
  if (typeof document === "undefined") return false;
  try {
    const area = document.createElement("textarea");
    area.value = value;
    area.setAttribute("readonly", "");
    area.style.position = "fixed";
    area.style.opacity = "0";
    document.body.appendChild(area);
    area.select();
    const ok = document.execCommand("copy");
    document.body.removeChild(area);
    return ok;
  } catch {
    return false;
  }
}
