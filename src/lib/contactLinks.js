// SECOTO 084 — Liens d'appel, de SMS et de WhatsApp vers un numéro français.
// Fonctionne sur iPhone, Android et ordinateur (tel:/sms: ouvrent l'appli native).

/** « 06 12 34 56 78 » -> « +33612345678 » ; numéro déjà international conservé. */
export function phoneE164(raw) {
  const digits = String(raw || "").replace(/[^\d+]/g, "");
  if (!digits) return "";
  if (digits.startsWith("+")) return `+${digits.slice(1).replace(/\D/g, "")}`;
  if (digits.startsWith("00")) return `+${digits.slice(2)}`;
  if (digits.startsWith("0") && digits.length === 10) return `+33${digits.slice(1)}`;
  return digits;
}

/** Affichage lisible : « +33612345678 » -> « 06 12 34 56 78 ». */
export function phoneDisplay(raw) {
  const e164 = phoneE164(raw);
  if (/^\+33\d{9}$/.test(e164)) return `0${e164.slice(3)}`.replace(/(\d{2})(?=\d)/g, "$1 ");
  return String(raw || "").trim();
}

export function contactLinks(raw, message = "") {
  const e164 = phoneE164(raw);
  if (!e164 || e164.replace(/\D/g, "").length < 9) return null;
  const text = message ? encodeURIComponent(message) : "";
  return {
    tel: `tel:${e164}`,
    sms: `sms:${e164}${text ? `?&body=${text}` : ""}`,
    whatsapp: `https://wa.me/${e164.replace(/\D/g, "")}${text ? `?text=${text}` : ""}`,
  };
}
