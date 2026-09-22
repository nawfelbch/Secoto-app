import { withLambda } from "@netlify/aws-lambda-compat";
// SECOTO — paiement d'un devis depuis un simple lien.
// ----------------------------------------------------------------------------
// Le client n'a pas de compte, pas d'application, souvent juste un SMS. Ce
// lien est la seule chose dont il dispose : il l'ouvre, il paie, c'est tout.
//
// Trois regles tiennent cette porte :
//   · le montant n'est jamais lu dans l'URL, il est relu en base au clic ;
//   · un devis deja paye, revoque, expire ou annule ne cree aucune session ;
//   · l'encaissement n'est acte que par le webhook Stripe, jamais ici.
import Stripe from "stripe";
import { createClient } from "@supabase/supabase-js";
import { createWithManagedPaymentsFallback, idempotencyKey } from "../lib/secoto-server.js";

const {
  STRIPE_SECRET_KEY,
  SUPABASE_SERVICE_ROLE_KEY,
  SUPABASE_URL,
  SECOTO_APP_URL = "https://app.secoto-transport.fr",
  STRIPE_TAX_CODE = "txcd_20030000",
} = process.env;

// Messages destines au client : ils doivent se suffire a eux-memes, sans
// jargon ni numero de mission.
const MOTIFS = {
  lien_inconnu: "Ce lien de paiement n'est plus valable. Demandez-en un nouveau à SECOTO.",
  lien_expire: "Ce lien de paiement a expiré. Demandez-en un nouveau à SECOTO.",
  lien_revoque: "Ce lien a été remplacé par un nouveau. Utilisez le dernier message reçu.",
  deja_paye: "Cette course est déjà réglée. Merci !",
  course_annulee: "Cette course a été annulée. Aucun paiement n'est dû.",
  date_depassee: "La date d'enlèvement est passée. Contactez SECOTO pour un nouveau devis.",
  reglement_especes: "Cette course se règle en espèces auprès du transporteur, le jour de la prestation.",
  compte_introuvable: "Paiement momentanément indisponible. Contactez SECOTO.",
};

export function page(titre, message, ton = "info") {
  const couleur = ton === "ok" ? "#0f7b4f" : "#b3341a";
  return `<!doctype html><html lang="fr"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>SECOTO — ${titre}</title></head>
<body style="margin:0;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif;background:#f6f7f9;color:#101828">
<div style="max-width:520px;margin:12vh auto;padding:32px;background:#fff;border-radius:16px;box-shadow:0 8px 30px rgba(16,24,40,.08)">
<p style="letter-spacing:.32em;font-weight:700;color:#e8622a;margin:0 0 18px">S E C O T O</p>
<h1 style="font-size:20px;margin:0 0 12px;color:${couleur}">${titre}</h1>
<p style="margin:0;line-height:1.55">${message}</p>
</div></body></html>`;
}

// Le particulier qui paie en ligne doit demander expressement l'execution
// immediate : sans cette trace, il garde 14 jours pour annuler, meme une fois
// le vehicule livre. La case n'est jamais pre-cochee.
export function pageRenonciation(token, montantCents, trajet) {
  const montant = (Number(montantCents || 0) / 100).toFixed(2).replace(".", ",");
  return `<!doctype html><html lang="fr"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>SECOTO — confirmation avant paiement</title></head>
<body style="margin:0;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif;background:#f6f7f9;color:#101828">
<div style="max-width:560px;margin:8vh auto;padding:32px;background:#fff;border-radius:16px;box-shadow:0 8px 30px rgba(16,24,40,.08)">
<p style="letter-spacing:.32em;font-weight:700;color:#e8622a;margin:0 0 18px">S E C O T O</p>
<h1 style="font-size:20px;margin:0 0 6px">Transport de véhicule${trajet ? ` — ${trajet}` : ""}</h1>
<p style="font-size:26px;font-weight:700;margin:0 0 20px">${montant} €</p>
<form method="post" action="?t=${token}">
<label style="display:flex;gap:12px;align-items:flex-start;line-height:1.5;margin-bottom:22px">
<input type="checkbox" name="consent" value="oui" required style="margin-top:4px;width:20px;height:20px">
<span>Je demande l'exécution de la prestation avant la fin du délai de rétractation de 14 jours,
et je reconnais perdre ce droit une fois le transport intégralement exécuté.</span>
</label>
<button type="submit" style="width:100%;padding:16px;border:0;border-radius:10px;background:#e8622a;color:#fff;font-size:16px;font-weight:700">
Continuer vers le paiement
</button>
</form>
<p style="font-size:12px;color:#667085;margin:18px 0 0;line-height:1.5">
Paiement sécurisé par Stripe. Le règlement vaut acceptation du devis. En cas d'annulation plus de
24 h avant l'enlèvement, vous êtes intégralement remboursé.
</p>
</div></body></html>`;
}

function html(statusCode, body) {
  return {
    statusCode,
    headers: { "Cache-Control": "no-store", "Content-Type": "text/html; charset=utf-8" },
    body,
  };
}

const handler = async (event) => {
  if (event.httpMethod !== "GET" && event.httpMethod !== "POST") {
    return html(405, page("Méthode non autorisée", "Ouvrez ce lien depuis votre navigateur."));
  }
  if (!STRIPE_SECRET_KEY || !SUPABASE_URL || !SUPABASE_SERVICE_ROLE_KEY) {
    return html(503, page("Paiement indisponible", MOTIFS.compte_introuvable));
  }

  // Retour depuis Stripe : on ne relance surtout pas une session de paiement.
  const retour = String(event.queryStringParameters?.retour || "");
  if (retour === "ok") {
    return html(200, page(
      "Merci, votre paiement est enregistré",
      "Vous recevrez la confirmation par e-mail. SECOTO prend le relais et vous tient informé de l'enlèvement du véhicule.",
      "ok",
    ));
  }
  if (retour === "annule") {
    return html(200, page(
      "Paiement interrompu",
      "Rien n'a été débité. Vous pouvez rouvrir le lien reçu pour régler la course quand vous le souhaitez.",
    ));
  }

  const token = String(event.queryStringParameters?.t || "").trim();
  if (!/^[a-f0-9]{24,64}$/.test(token)) {
    return html(404, page("Lien invalide", MOTIFS.lien_inconnu));
  }

  const admin = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  // Consentement envoye par la page de renonciation.
  if (event.httpMethod === "POST") {
    const corps = event.isBase64Encoded
      ? Buffer.from(event.body || "", "base64").toString("utf8")
      : String(event.body || "");
    const consent = new URLSearchParams(corps).get("consent") === "oui";
    if (!consent) {
      return html(200, page("Confirmation requise", "Cochez la case pour continuer vers le paiement."));
    }
    await admin.rpc("secoto_devis_link_open", { p_token: token });
    const accord = await admin.rpc("secoto_devis_link_waiver", { p_token: token, p_accepted: true });
    if (accord.error || accord.data?.error) {
      return html(503, page("Paiement indisponible", MOTIFS.compte_introuvable));
    }
  }

  const { data, error } = await admin.rpc("secoto_devis_link_open", { p_token: token });
  if (error) return html(503, page("Paiement indisponible", MOTIFS.compte_introuvable));
  if (data?.error) {
    const motif = MOTIFS[data.error] || MOTIFS.lien_inconnu;
    const paye = data.error === "deja_paye";
    return html(paye ? 200 : 410, page(paye ? "Course déjà réglée" : "Lien inutilisable", motif, paye ? "ok" : "info"));
  }

  const trajet = String(data.trajet || "").replace(/^ - $/, "").trim();

  // Particulier : la renonciation d'abord, le paiement ensuite.
  if (data.waiver_required) {
    return html(200, pageRenonciation(token, data.amount_cents, trajet));
  }
  const description = ["SECOTO — transport de véhicule", trajet, data.vehicule]
    .filter((part) => part && String(part).trim())
    .join(" · ")
    .slice(0, 250);

  const stripe = new Stripe(STRIPE_SECRET_KEY);
  try {
    const session = await createWithManagedPaymentsFallback((managed) => stripe.checkout.sessions.create(
      {
        ...managed,
        mode: "payment",
        line_items: [{
          price_data: {
            currency: data.currency || "eur",
            unit_amount: data.amount_cents,
            product_data: { name: description, tax_code: STRIPE_TAX_CODE },
          },
          quantity: 1,
        }],
        // Franchise en base, article 293 B : Stripe n'ajoute rien au prix.
        automatic_tax: { enabled: false },
        payment_intent_data: {
          description,
          metadata: {
            secoto_payment_id: data.payment_id,
            secoto_purpose: data.purpose || "devis_course",
            secoto_reference: data.reference || "",
          },
        },
        metadata: { secoto_payment_id: data.payment_id },
        success_url: `${SECOTO_APP_URL}/.netlify/functions/devis-pay?t=${token}&retour=ok`,
        cancel_url: `${SECOTO_APP_URL}/.netlify/functions/devis-pay?t=${token}&retour=annule`,
      },
      {
        idempotencyKey: idempotencyKey("secoto-devis", data.payment_id, {
          amount: data.amount_cents,
          currency: data.currency || "eur",
          description,
          taxCode: STRIPE_TAX_CODE,
        }),
      },
    ));

    if (!session?.url) return html(503, page("Paiement indisponible", MOTIFS.compte_introuvable));
    return { statusCode: 303, headers: { Location: session.url, "Cache-Control": "no-store" }, body: "" };
  } catch {
    return html(503, page("Paiement indisponible", MOTIFS.compte_introuvable));
  }
};

export default withLambda(handler);
