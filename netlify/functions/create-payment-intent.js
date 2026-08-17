import { withLambda } from "@netlify/aws-lambda-compat";
// SECOTO — création de l'intention de paiement Stripe.
// ----------------------------------------------------------------------------
// Le client n'envoie QUE l'identifiant d'une ligne public.payments déjà créée
// par la base (secoto_prepare_commission_payment / _delivery_payment). Le
// montant n'est jamais transmis par le téléphone : il est relu côté serveur.
//
// Aucun In-App Purchase ici, volontairement : le convoyage et le transport de
// véhicules sont des services du monde réel consommés hors de l'application,
// explicitement exclus de l'obligation d'achat intégré côté Apple comme côté
// Google. Implémenter StoreKit ou Play Billing serait un motif de rejet.
import Stripe from "stripe";
import { createClient } from "@supabase/supabase-js";

const {
  STRIPE_SECRET_KEY,
  STRIPE_PUBLISHABLE_KEY,
  SUPABASE_ANON_KEY,
  SUPABASE_SERVICE_ROLE_KEY,
  SUPABASE_URL,
  SECOTO_APP_URL = "https://app.secoto-transport.fr",
  STRIPE_MOBILE_API_VERSION = "2025-03-31.basil",
} = process.env;

const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const ALLOWED_PLATFORMS = new Set(["ios", "android", "web"]);

function response(statusCode, body) {
  return {
    statusCode,
    headers: {
      "Cache-Control": "no-store",
      "Content-Type": "application/json; charset=utf-8",
    },
    body: JSON.stringify(body),
  };
}

function bearer(event) {
  const raw = event.headers?.authorization || event.headers?.Authorization || "";
  return raw.startsWith("Bearer ") ? raw.slice(7) : "";
}

export const handler = async (event) => {
  if (event.httpMethod !== "POST") return response(405, { error: "method_not_allowed" });
  if (!STRIPE_SECRET_KEY || !SUPABASE_URL || !SUPABASE_SERVICE_ROLE_KEY || !SUPABASE_ANON_KEY) {
    return response(503, { error: "server_not_configured" });
  }

  const accessToken = bearer(event);
  if (!accessToken) return response(401, { error: "unauthorized" });

  let payload;
  try {
    payload = JSON.parse(event.body || "{}");
  } catch {
    return response(400, { error: "invalid_json" });
  }
  const paymentId = payload.paymentId;
  const platform = ALLOWED_PLATFORMS.has(payload.platform) ? payload.platform : "web";
  if (!UUID_PATTERN.test(paymentId || "")) return response(400, { error: "invalid_payment_id" });

  // 1. Identité réelle de l'appelant, vérifiée par Supabase, jamais déduite
  //    d'un champ du corps de la requête.
  const anon = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const { data: userData, error: userError } = await anon.auth.getUser(accessToken);
  const userId = userData?.user?.id;
  if (userError || !userId) return response(401, { error: "unauthorized" });

  const admin = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  const { data: payment, error: paymentError } = await admin
    .from("payments")
    .select("id,mission_id,account_id,purpose,amount_cents,currency,status,provider_intent_id,waiver_required,waiver_accepted")
    .eq("id", paymentId)
    .single();
  if (paymentError || !payment) return response(404, { error: "payment_not_found" });
  if (payment.account_id !== userId) return response(403, { error: "forbidden" });
  if (payment.status === "paid") return response(409, { error: "already_paid" });
  if (!["pending", "processing"].includes(payment.status)) {
    return response(409, { error: "payment_not_payable" });
  }

  // 2. La renonciation au droit de rétractation doit être acquise AVANT
  //    l'encaissement, sinon la prestation n'est pas exécutable immédiatement.
  if (payment.waiver_required && !payment.waiver_accepted) {
    return response(428, { error: "waiver_required" });
  }

  const stripe = new Stripe(STRIPE_SECRET_KEY);

  // 3. Client Stripe réutilisable : c'est ce qui permet les cartes enregistrées.
  const { data: account } = await admin
    .from("accounts")
    .select("id,email,full_name,stripe_customer_id")
    .eq("id", userId)
    .single();

  let customerId = account?.stripe_customer_id || null;
  if (!customerId) {
    const customer = await stripe.customers.create({
      email: account?.email || undefined,
      name: account?.full_name || undefined,
      metadata: { secoto_account_id: userId },
    });
    customerId = customer.id;
    await admin.from("accounts").update({ stripe_customer_id: customerId }).eq("id", userId);
  }

  const description = payment.purpose === "commission_plateau"
    ? "SECOTO — reservation de votre creneau (frais de mise en relation)"
    : "SECOTO — prestation de convoyage";

  try {
    // 4a. Sur le web, pas de feuille native : session Stripe Checkout hébergée.
    //     Apple Pay et Google Pay y restent disponibles via le navigateur.
    if (platform === "web") {
      const session = await stripe.checkout.sessions.create(
        {
          mode: "payment",
          customer: customerId,
          line_items: [{
            price_data: {
              currency: payment.currency || "eur",
              unit_amount: payment.amount_cents,
              product_data: { name: description },
            },
            quantity: 1,
          }],
          payment_intent_data: {
            description,
            metadata: {
              secoto_payment_id: payment.id,
              secoto_mission_id: payment.mission_id,
              secoto_purpose: payment.purpose,
            },
          },
          metadata: { secoto_payment_id: payment.id },
          success_url: `${SECOTO_APP_URL}/?ecran=paiement&mission=${encodeURIComponent(payment.mission_id)}&paiement=ok`,
          cancel_url: `${SECOTO_APP_URL}/?ecran=paiement&mission=${encodeURIComponent(payment.mission_id)}&paiement=annule`,
        },
        { idempotencyKey: `secoto-checkout-${payment.id}` },
      );

      await admin
        .from("payments")
        .update({
          provider_intent_id: session.payment_intent || payment.provider_intent_id,
          status: "processing",
          updated_at: new Date().toISOString(),
        })
        .eq("id", payment.id);

      return response(200, {
        mode: "checkout",
        checkoutUrl: session.url,
        amountCents: payment.amount_cents,
        currency: payment.currency || "eur",
      });
    }

    // 4b. Réutilisation de l'intention existante : un double appui sur le
    //     bouton ne crée jamais deux intentions ni deux encaissements.
    let intent = null;
    if (payment.provider_intent_id) {
      intent = await stripe.paymentIntents.retrieve(payment.provider_intent_id);
      if (!["requires_payment_method", "requires_confirmation", "requires_action", "processing"].includes(intent.status)) {
        intent = null;
      }
    }
    if (!intent) {
      intent = await stripe.paymentIntents.create(
        {
          amount: payment.amount_cents,
          currency: payment.currency || "eur",
          customer: customerId,
          description,
          automatic_payment_methods: { enabled: true },
          setup_future_usage: "on_session",
          metadata: {
            secoto_payment_id: payment.id,
            secoto_mission_id: payment.mission_id,
            secoto_purpose: payment.purpose,
          },
        },
        { idempotencyKey: `secoto-payment-${payment.id}` },
      );
    }

    await admin
      .from("payments")
      .update({
        provider_intent_id: intent.id,
        status: "processing",
        updated_at: new Date().toISOString(),
      })
      .eq("id", payment.id);

    // 5. Sur iOS et Android, la feuille de paiement native a besoin d'une clé
    //    éphémère pour afficher les cartes enregistrées du client.
    let ephemeralKey = null;
    if (platform === "ios" || platform === "android") {
      // La version d'API doit correspondre a celle qu'attend le SDK Stripe
      // NATIF embarque par @capacitor-community/stripe, qui n'est pas celle du
      // SDK serveur. Elle est donc pilotee par une variable d'environnement.
      // Si la creation echoue, on continue SANS cle ephemere : le paiement
      // reste possible, seules les cartes enregistrees ne sont pas proposees.
      try {
        const key = await stripe.ephemeralKeys.create(
          { customer: customerId },
          { apiVersion: STRIPE_MOBILE_API_VERSION },
        );
        ephemeralKey = key.secret;
      } catch {
        ephemeralKey = null;
      }
    }

    return response(200, {
      mode: "payment_sheet",
      clientSecret: intent.client_secret,
      publishableKey: STRIPE_PUBLISHABLE_KEY || null,
      customerId,
      ephemeralKey,
      amountCents: payment.amount_cents,
      currency: payment.currency || "eur",
      returnUrl: `${SECOTO_APP_URL}/?ecran=paiement&mission=${encodeURIComponent(payment.mission_id)}`,
    });
  } catch (error) {
    await admin
      .from("payments")
      .update({
        last_error: String(error?.message || "stripe_error").slice(0, 500),
        updated_at: new Date().toISOString(),
      })
      .eq("id", payment.id);
    return response(502, { error: "stripe_unavailable" });
  }
};

export default withLambda(handler);
