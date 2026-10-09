// SECOTO 088 — Provenance d'un devis (utm, gclid, fbclid) et choix de cookies.
// Les valeurs viennent du navigateur : elles sont filtrées ici, puis nettoyées
// par la base. Une erreur ne bloque jamais le devis.

const CLES = ["utm_source", "utm_medium", "utm_campaign", "utm_content", "gclid", "fbclid", "at"];

export function attributionPropre(brut) {
  if (!brut || typeof brut !== "object" || Array.isArray(brut)) return {};
  const out = {};
  for (const k of CLES) {
    const v = brut[k];
    if (typeof v === "string" && v.trim()) out[k] = v.trim().slice(0, 200);
  }
  return out;
}

export async function enregistrerAttribution(admin, quoteId, body) {
  try {
    if (!admin || !quoteId) return;
    const attr = attributionPropre(body?.attribution);
    const consentement = typeof body?.consentement === "boolean" ? body.consentement : null;
    if (Object.keys(attr).length === 0 && consentement === null) return;
    await admin.rpc("secoto_attribution_devis", { p_quote_id: quoteId, p_attr: attr, p_consentement: consentement });
  } catch {
    // La mesure ne doit jamais empêcher un client d'obtenir son prix.
  }
}
