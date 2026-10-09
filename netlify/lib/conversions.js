// SECOTO 088 — Commandes payées déclarées aux régies publicitaires.
// ----------------------------------------------------------------------------
// La base crée une ligne « conversion » au moment où un paiement de commande
// passe à « payé » (déclencheur sur payments). Ce module l'envoie à l'API
// Conversions de Meta. Google Ads, lui, vient chercher les conversions par
// gclid dans un fichier protégé (fonction conversions-google).
//
// Règles :
//  • rien n'est envoyé sans le consentement publicitaire du client (la base ne
//    renvoie que ces lignes-là) ;
//  • valeur = commission SECOTO, en euros ; jamais le prix du transport ;
//  • event_id « cmd-<paiement> » : le même que celui du navigateur, pour que
//    Meta ne compte jamais deux fois la même commande ;
//  • données personnelles uniquement hachées (SHA-256) ;
//  • une erreur ici ne bloque JAMAIS un paiement : tout est rattrapé et la
//    ligne est retentée à la maintenance suivante (6 essais au plus).

const DELAI_MS = 4000;
const SOURCE_URL = "https://app.secoto-transport.fr/";

export function metaConfiguree(env = process.env) {
  return Boolean(env.META_PIXEL_ID && env.META_CAPI_TOKEN);
}

/** Paramètre fbc attendu par Meta à partir du fbclid. */
export function fbcDepuisFbclid(fbclid, horodatageMs) {
  if (!fbclid) return undefined;
  const ms = Number(horodatageMs) || Date.now();
  return `fb.1.${ms}.${fbclid}`;
}

/** Événement Meta « Purchase » construit depuis une ligne de la base. */
export function evenementMeta(ligne) {
  const user = {};
  if (ligne.email_sha256) user.em = [ligne.email_sha256];
  if (ligne.phone_sha256) user.ph = [ligne.phone_sha256];
  if (ligne.external_id_sha256) user.external_id = [ligne.external_id_sha256];
  const fbc = fbcDepuisFbclid(ligne.fbclid, ligne.fbclid_at_ms);
  if (fbc) user.fbc = fbc;
  return {
    event_name: "Purchase",
    event_time: Number(ligne.event_time) || Math.floor(Date.now() / 1000),
    event_id: String(ligne.event_id),
    action_source: "website",
    event_source_url: SOURCE_URL,
    user_data: user,
    custom_data: {
      value: Number(ligne.value) || 0,
      currency: ligne.currency || "EUR",
      order_id: ligne.order_ref || undefined,
      content_name: "commande_payee",
    },
  };
}

export async function envoyerConversionsMeta(admin, { limite = 20, fetchImpl = fetch, env = process.env } = {}) {
  try {
    if (!admin || !metaConfiguree(env)) return { envoyees: 0, raison: "non_configure" };
    const { data: lignes, error } = await admin.rpc("secoto_conversions_meta_a_envoyer", { p_limit: limite });
    if (error || !Array.isArray(lignes) || lignes.length === 0) return { envoyees: 0 };
    const version = env.META_GRAPH_VERSION || "v21.0";
    const url = `https://graph.facebook.com/${version}/${encodeURIComponent(env.META_PIXEL_ID)}/events`;
    let envoyees = 0;
    for (const ligne of lignes) {
      let ok = false;
      let erreur = null;
      try {
        const corps = { data: [evenementMeta(ligne)], access_token: env.META_CAPI_TOKEN };
        // Mode test : les événements n'apparaissent que dans « Tester les événements ».
        if (env.META_TEST_EVENT_CODE) corps.test_event_code = env.META_TEST_EVENT_CODE;
        const reponse = await fetchImpl(url, {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify(corps),
          signal: typeof AbortSignal?.timeout === "function" ? AbortSignal.timeout(DELAI_MS) : undefined,
        });
        ok = reponse.ok;
        if (!ok) erreur = `http_${reponse.status}: ${(await reponse.text().catch(() => "")).slice(0, 300)}`;
      } catch (e) {
        erreur = String(e?.message || e).slice(0, 300);
      }
      await admin.rpc("secoto_conversion_meta_resultat", { p_id: ligne.id, p_ok: ok, p_error: erreur });
      if (ok) envoyees += 1;
      else console.log("[conversions] meta", JSON.stringify({ event_id: ligne.event_id, erreur }));
    }
    return { envoyees, total: lignes.length };
  } catch (e) {
    console.log("[conversions] erreur", String(e?.message || e));
    return { envoyees: 0, erreur: true };
  }
}

// --------------------------------------------------------------- Google Ads --
const pad = (n) => String(n).padStart(2, "0");

/** « 2026-10-12 14:05:00 » en heure de Paris (format de l'import Google Ads). */
export function heureParis(iso) {
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return null;
  const parts = new Intl.DateTimeFormat("fr-FR", {
    timeZone: "Europe/Paris", year: "numeric", month: "2-digit", day: "2-digit",
    hour: "2-digit", minute: "2-digit", second: "2-digit", hour12: false,
  }).formatToParts(d).reduce((acc, p) => ({ ...acc, [p.type]: p.value }), {});
  return `${parts.year}-${parts.month}-${parts.day} ${pad(Number(parts.hour) % 24)}:${parts.minute}:${parts.second}`;
}

const csvCell = (v) => {
  const s = String(v ?? "");
  return /[",\n]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s;
};

/** Fichier d'import « conversions issues de clics » de Google Ads. */
export function csvGoogle(lignes, nomConversion = "commande_payee") {
  const out = [
    "Parameters:TimeZone=Europe/Paris",
    "Google Click ID,Conversion Name,Conversion Time,Conversion Value,Conversion Currency",
  ];
  for (const l of lignes || []) {
    const heure = heureParis(l.event_time);
    if (!l.gclid || !heure) continue;
    out.push([l.gclid, nomConversion, heure, Number(l.value || 0).toFixed(2), l.currency || "EUR"].map(csvCell).join(","));
  }
  return `${out.join("\n")}\n`;
}
