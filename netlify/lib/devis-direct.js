// SECOTO 077 — liens de paiement de devis plateau en paiement direct.
// Utilisé par netlify/functions/devis-pay.js.
import { createWithManagedPaymentsFallback, idempotencyKey } from "./secoto-server.js";

const { SECOTO_APP_URL = "https://app.secoto-transport.fr" } = process.env;

/**
 * 077 — Session Stripe du circuit direct, ouverte depuis un lien de devis.
 *  · devis du transport à la demande : enregistrement de la carte (aucun
 *    débit) ; le client est débité chez le transporteur qui accepte ;
 *  · mission manuelle : paiement directement sur le compte du transporteur
 *    attribué, commission SECOTO prélevée par Stripe.
 * Les montants viennent de la base (secoto_devis_link_open), jamais de l'URL.
 */
const eur = (cents) => `${(Number(cents) / 100).toFixed(2).replace(".", ",")} €`;

/**
 * 081 — Décomposition affichée sur la page Stripe, juste au-dessus du bouton
 * (avant toute validation) : prix réservé au transporteur + commission SECOTO.
 */
export function messageDecomposition(data) {
  const total = Number(data?.amount_cents);
  const commission = Number(data?.commission_cents);
  if (!Number.isFinite(total) || !Number.isFinite(commission) || commission < 0 || commission > total) return null;
  return `Dont prix réservé au transporteur : ${eur(total - commission)}. `
    + `Commission de mise en relation SECOTO : ${eur(commission)}. `
    + "SECOTO agit en tant qu'intermédiaire ; le transport est assuré par un transporteur indépendant.";
}

export async function sessionDirecte({ admin, stripe, data, token, description }) {
  const decompo = messageDecomposition(data);
  const texte = (suite) => ({ custom_text: { submit: { message: [decompo, suite].filter(Boolean).join(" ").slice(0, 1200) } } });
  const metadata = {
    secoto_payment_id: data.payment_id,
    secoto_purpose: data.purpose || "",
    secoto_reference: data.reference || "",
    secoto_circuit: "direct",
  };
  const retour = (code) => `${SECOTO_APP_URL}/.netlify/functions/devis-pay?t=${token}&retour=${code}`;

  if (data.connected_account_id) {
    return createWithManagedPaymentsFallback((managed) => stripe.checkout.sessions.create(
      {
        ...managed,
        mode: "payment",
        line_items: [{
          price_data: { currency: data.currency || "eur", unit_amount: data.amount_cents, product_data: { name: description } },
          quantity: 1,
        }],
        payment_intent_data: { application_fee_amount: data.application_fee_cents, description, metadata },
        ...texte("Le paiement est encaissé directement sur le compte du transporteur."),
        metadata,
        success_url: retour("ok"),
        cancel_url: retour("annule"),
      },
      {
        stripeAccount: data.connected_account_id,
        idempotencyKey: idempotencyKey("secoto-devis-direct", data.payment_id, {
          account: data.connected_account_id, amount: data.amount_cents, fee: data.application_fee_cents, description, managed, decompo,
        }),
      },
    ));
  }

  // Devis du transport à la demande : la carte est enregistrée chez SECOTO
  // (client Stripe du compte), puis recopiée chez le transporteur au débit.
  const { data: compte } = await admin.from("accounts")
    .select("id,email,full_name,stripe_customer_id").eq("id", data.account_id).single();
  if (!compte) throw new Error("compte_introuvable");
  let customerId = compte.stripe_customer_id || null;
  if (!customerId) {
    const customer = await stripe.customers.create(
      { email: compte.email || undefined, name: compte.full_name || undefined, metadata: { secoto_account_id: compte.id } },
      { idempotencyKey: `secoto-customer-${compte.id}` },
    );
    customerId = customer.id;
    await admin.from("accounts").update({ stripe_customer_id: customerId }).eq("id", compte.id);
  }
  const session = await createWithManagedPaymentsFallback((managed) => stripe.checkout.sessions.create(
    {
      ...managed,
      mode: "setup",
      customer: customerId,
      currency: data.currency || "eur",
      setup_intent_data: { metadata, description: `Validation de carte — ${description}`.slice(0, 250) },
      ...texte(`Aucun débit maintenant : vous n'êtes débité de ${eur(data.amount_cents)} que lorsqu'un transporteur indépendant accepte votre transport, directement sur son compte.`),
      metadata,
      success_url: retour("carte"),
      cancel_url: retour("annule"),
    },
    { idempotencyKey: idempotencyKey("secoto-devis-direct-setup", data.payment_id, { customerId, managed, decompo }) },
  ));
  await admin.from("payments").update({ status: "processing", updated_at: new Date().toISOString() })
    .eq("id", data.payment_id).in("status", ["pending", "failed"]);
  return session;
}
