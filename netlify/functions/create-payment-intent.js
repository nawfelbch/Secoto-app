import { withLambda } from "@netlify/aws-lambda-compat";
import { MANAGED_PAYMENTS_ENABLED, createWithManagedPaymentsFallback, withCors } from "../lib/secoto-server.js";
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
import { createHash } from "node:crypto";
import Stripe from "stripe";
import { messageDecomposition } from "../lib/devis-direct.js";
import { urlRetour } from "../lib/retour-app.js";
import { createClient } from "@supabase/supabase-js";

const {
  STRIPE_SECRET_KEY,
  STRIPE_PUBLISHABLE_KEY,
  SUPABASE_ANON_KEY,
  SUPABASE_SERVICE_ROLE_KEY,
  SUPABASE_URL,
  SECOTO_APP_URL = "https://app.secoto-transport.fr",
  STRIPE_MOBILE_API_VERSION = "2025-03-31.basil",
  // Code fiscal Stripe de la prestation. Par defaut : « General - Services ».
  // Stripe Tax le REFUSE absent des que le calcul automatique est actif sur le
  // compte : sans lui, la session de paiement est rejetee avec
  // « Invalid line_items[0]: the product tax code is missing ».
  STRIPE_TAX_CODE = "txcd_20030000",
  // SECOTO est en franchise en base (article 293 B du CGI) : aucune TVA n'est
  // due, donc aucun calcul automatique. Passer cette variable a "true" le jour
  // ou SECOTO sort de la franchise et facture la TVA.
  STRIPE_AUTOMATIC_TAX = "false",
} = process.env;

// Managed Payments impose automatic_tax[enabled]=true. Les deux reglages sont
// donc lies : on ne peut pas laisser le compte dans un etat que Stripe refuse.
const AUTOMATIC_TAX_ENABLED =
  MANAGED_PAYMENTS_ENABLED || String(STRIPE_AUTOMATIC_TAX).toLowerCase() === "true";

// Une cle d'idempotence Stripe est liee A VIE aux parametres de son premier
// usage : rejouee avec des parametres differents, Stripe refuse la requete
// (« Keys for idempotent requests can only be used with the same parameters »).
// Une cle basee sur le seul identifiant de paiement condamne donc ce paiement
// des que le montant, le libelle ou la fiscalite changent. On y ajoute
// l'empreinte des parametres : un double appui reste protege (memes parametres,
// meme cle), une modification legitime repart proprement.
function idempotencyKey(prefix, id, params) {
  const empreinte = createHash("sha256").update(JSON.stringify(params)).digest("hex").slice(0, 16);
  return `${prefix}-${id}-${empreinte}`;
}

const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const ALLOWED_PLATFORMS = new Set(["ios", "android", "web"]);

// Coordonnées pré-remplies dans la feuille de paiement de l'application :
// le client n'a rien à ressaisir (Klarna demande notamment l'e-mail).
export function billingPrefill(account) {
  const email = String(account?.email || "").trim();
  const name = String(account?.full_name || "").trim();
  if (!email && !name) return null;
  return { ...(email ? { email } : {}), ...(name ? { name } : {}) };
}

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

const handler = async (event) => {
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
  // 2.3.6+ : la feuille de paiement intégrée connaît son adresse de retour
  // (secoto://stripe-redirect) et peut donc afficher Klarna, Satispay…
  const feuilleKlarna = platform !== "web" && payload.feuilleKlarna === true;
  if (!UUID_PATTERN.test(paymentId || "")) return response(400, { error: "invalid_payment_id" });
  if (platform !== "web" && !STRIPE_PUBLISHABLE_KEY) {
    return response(503, { error: "server_not_configured" });
  }

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
    .select("id,mission_id,order_id,account_id,purpose,amount_cents,currency,status,provider_intent_id,waiver_required,waiver_accepted,capture_method,payment_circuit,setup_intent_id,direct_action_required_at,debit_a_confirmation,debit_a_livraison,reglement_tentatives,reglement_debit_tente_at")
    .eq("id", paymentId)
    .single();
  if (paymentError || !payment) return response(404, { error: "payment_not_found" });
  if (payment.account_id !== userId) return response(403, { error: "forbidden" });
  if (payment.status === "paid") return response(409, { error: "already_paid" });
  const direct = payment.payment_circuit === "direct";
  // 099 : offre choisie -> carte enregistrée, débit à la confirmation (compte SECOTO).
  const differe = !direct && payment.debit_a_confirmation === true;
  // 074 : en paiement direct, la carte peut être (re)validée tant qu'aucun
  // transporteur n'a été débité, et la validation bancaire peut être demandée.
  const payableStatuses = direct || differe
    ? ["pending", "processing", "failed", "capture_failed", "requires_capture"]
    : ["pending", "processing"];
  if (!payableStatuses.includes(payment.status)) {
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
    const customer = await stripe.customers.create(
      {
        email: account?.email || undefined,
        name: account?.full_name || undefined,
        metadata: { secoto_account_id: userId },
      },
      { idempotencyKey: `secoto-customer-${userId}` },
    );
    customerId = customer.id;
    await admin.from("accounts").update({ stripe_customer_id: customerId }).eq("id", userId);
  }

  const description = {
    commission_plateau: "SECOTO — reservation de votre creneau (frais de mise en relation)",
    convoyage_livraison: "SECOTO — prestation de convoyage",
    od_convoyage: "SECOTO — convoyage a la demande",
    od_plateau: "SECOTO — transport de vehicule sur plateau",
    od_plateau_commission: "SECOTO — frais de mise en relation (transport sur plateau)",
    subscription_extension: "SECOTO — extension de forfait",
  }[payment.purpose] || "SECOTO — prestation";
  // Migration 030 : autorisation seule, capture après attribution confirmée.
  const captureMethod = payment.capture_method === "manual" ? "manual" : "automatic";
  const returnScreen = payment.order_id ? "courses" : payment.purpose === "subscription_extension" ? "abonnement" : "paiement";
  const returnQuery = payment.order_id
    ? `commande=${encodeURIComponent(payment.order_id)}`
    : payment.mission_id ? `mission=${encodeURIComponent(payment.mission_id)}` : "";
  const intentMetadata = {
    secoto_payment_id: payment.id,
    secoto_mission_id: payment.mission_id || "",
    secoto_order_id: payment.order_id || "",
    secoto_purpose: payment.purpose,
  };

  if (direct || differe) {
    try {
      return await directFlow({ admin, stripe, payment, platform, customerId, account, returnScreen, returnQuery, differe, feuilleKlarna });
    } catch (error) {
      await admin.from("payments").update({
        last_error: String(error?.message || "stripe_error").slice(0, 500),
        updated_at: new Date().toISOString(),
      }).eq("id", payment.id);
      return response(502, { error: "stripe_unavailable" });
    }
  }

  try {
    // 4a. Sur le web, pas de feuille native : session Stripe Checkout hébergée.
    //     Apple Pay et Google Pay y restent disponibles via le navigateur.
    if (platform === "web") {
      const session = await createWithManagedPaymentsFallback((managed) => stripe.checkout.sessions.create(
        {
          ...managed,
          mode: "payment",
          customer: customerId,
          line_items: [{
            price_data: {
              currency: payment.currency || "eur",
              unit_amount: payment.amount_cents,
              product_data: { name: description, tax_code: STRIPE_TAX_CODE },
              // Le prix affiche au client est le prix final : s'il devait un
              // jour inclure de la TVA, elle serait comprise dedans, jamais
              // ajoutee par-dessus.
              tax_behavior: AUTOMATIC_TAX_ENABLED ? "inclusive" : undefined,
            },
            quantity: 1,
          }],
          // Franchise en base par defaut : Stripe ne doit rien ajouter au prix.
          automatic_tax: { enabled: AUTOMATIC_TAX_ENABLED },
          payment_intent_data: {
            description,
            capture_method: captureMethod,
            metadata: intentMetadata,
          },
          metadata: { secoto_payment_id: payment.id },
          success_url: `${SECOTO_APP_URL}/?ecran=${returnScreen}&${returnQuery}&paiement=ok`,
          cancel_url: `${SECOTO_APP_URL}/?ecran=${returnScreen}&${returnQuery}&paiement=annule`,
        },
        {
          idempotencyKey: idempotencyKey("secoto-checkout", payment.id, {
            amount: payment.amount_cents,
            currency: payment.currency || "eur",
            description,
            captureMethod,
            taxCode: STRIPE_TAX_CODE,
            automaticTax: AUTOMATIC_TAX_ENABLED,
            managedPayments: MANAGED_PAYMENTS_ENABLED,
            customerId,
            returnScreen,
            returnQuery,
          }),
        },
      ));

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
      intent = await createWithManagedPaymentsFallback((managed) => stripe.paymentIntents.create(
        {
          ...managed,
          amount: payment.amount_cents,
          currency: payment.currency || "eur",
          customer: customerId,
          description,
          automatic_payment_methods: { enabled: true },
          capture_method: captureMethod,
          setup_future_usage: "on_session",
          metadata: intentMetadata,
        },
        {
          idempotencyKey: idempotencyKey("secoto-payment", payment.id, {
            amount: payment.amount_cents,
            currency: payment.currency || "eur",
            description,
            captureMethod,
            customerId,
            managedPayments: MANAGED_PAYMENTS_ENABLED,
          }),
        },
      ));
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
      captureMethod,
      returnUrl: `${SECOTO_APP_URL}/?ecran=${returnScreen}&${returnQuery}`,
      billing: billingPrefill(account),
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

// ---------------------------------------------------------------------------
// 074 — Paiement direct au transporteur (plateau et moto).
//  · Réservation : le client VALIDE sa carte, sans débit (SetupIntent sur le
//    compte SECOTO : aucune somme n'y est encaissée). Le débit aura lieu à
//    l'acceptation, sur le compte du transporteur (netlify/lib/paiement-direct.js).
//  · Si sa banque exige une validation au moment du débit : page de paiement
//    Stripe ouverte SUR LE COMPTE DU TRANSPORTEUR, commission SECOTO comprise.
// ---------------------------------------------------------------------------
export async function directFlow({ admin, stripe, payment, platform, customerId, account, returnScreen, returnQuery, differe = false, feuilleKlarna = false, now = Date.now() }) {
  // 099 : même parcours pour le débit à la confirmation, mais tout se passe sur
  // le compte SECOTO (aucun compte transporteur, aucune commission séparée).
  const circuit = differe ? "differe" : "direct";
  const { data: order } = await admin
    .from("transport_orders")
    .select("id,status,public_ref,lock_expires_at,mode_reglement")
    .eq("id", payment.order_id)
    .single();
  if (!order) return response(404, { error: "payment_not_found" });
  // 100 : règlement à l'arrivée -> la carte enregistrée doit pouvoir être
  // prélevée hors session à la livraison : carte seule (Apple Pay et Google Pay
  // compris). Klarna et les autres moyens se règlent à la livraison.
  const carteSeule = payment.debit_a_livraison === true;

  const metadata = {
    secoto_payment_id: payment.id,
    secoto_order_id: payment.order_id || "",
    secoto_purpose: payment.purpose,
    secoto_circuit: circuit,
  };
  const retourOk = `${SECOTO_APP_URL}/?ecran=${returnScreen}&${returnQuery}&paiement=ok`;
  const retourAnnule = `${SECOTO_APP_URL}/?ecran=${returnScreen}&${returnQuery}&paiement=annule`;
  // Depuis l'iPhone / Android, la page Stripe s'ouvre dans le navigateur : la
  // fin du parcours renvoie dans l'application (passerelle /retour-app.html).
  const retourOkAppli = urlRetour(SECOTO_APP_URL, `ecran=${returnScreen}&${returnQuery}&paiement=ok`, platform);
  const retourAnnuleAppli = urlRetour(SECOTO_APP_URL, `ecran=${returnScreen}&${returnQuery}&paiement=annule`, platform);

  // 100 : véhicule livré, règlement à faire par le client lui-même (Klarna,
  // carte refusée, espèces non reçues, ou simplement payer sans attendre).
  if (carteSeule && order.status === "delivered" && ["requires_capture", "capture_failed"].includes(payment.status)) {
    // 104 : prélèvement automatique en cours sur la carte enregistrée — on
    // n'ouvre pas un second paiement en parallèle.
    if (payment.reglement_debit_tente_at && now - new Date(payment.reglement_debit_tente_at).getTime() < 2 * 60000) {
      return response(409, { error: "debit_en_cours", message: "Le prélèvement de votre carte est en cours. Réessayez dans quelques minutes si besoin." });
    }
    const memoriser = (champs) => admin.from("payments").update({ ...champs, updated_at: new Date(now).toISOString() }).eq("id", payment.id);
    const description = `Transport de véhicule — commande ${order.public_ref}`;
    const livraison = { ...metadata, secoto_circuit: "livraison" };
    if (feuilleKlarna) {
      const intent = await createWithManagedPaymentsFallback((managed) => stripe.paymentIntents.create(
        {
          ...managed,
          amount: payment.amount_cents,
          currency: payment.currency || "eur",
          customer: customerId,
          description,
          automatic_payment_methods: { enabled: true },
          metadata: livraison,
        },
        { idempotencyKey: idempotencyKey("secoto-livraison-sheet", payment.id, { amount: payment.amount_cents, customerId, managed, tentative: payment.reglement_tentatives || 0 }) },
      ));
      const ephemeralKey = await stripe.ephemeralKeys
        .create({ customer: customerId }, { apiVersion: STRIPE_MOBILE_API_VERSION })
        .then((key) => key.secret)
        .catch(() => null);
      await memoriser({ reglement_client_intent_id: intent.id });
      return response(200, {
        mode: "payment_sheet",
        clientSecret: intent.client_secret,
        publishableKey: STRIPE_PUBLISHABLE_KEY || null,
        customerId,
        ephemeralKey,
        amountCents: payment.amount_cents,
        currency: payment.currency || "eur",
        circuit: "livraison",
        billing: billingPrefill(account),
      });
    }
    // Page Stripe valable 23 h ; la clé change chaque heure pour ne jamais
    // renvoyer une session expirée.
    const heure = Math.floor(now / 3600000);
    const expiresAt = Math.floor((heure * 3600000 + 24 * 3600000 - 60000) / 1000);
    const session = await createWithManagedPaymentsFallback((managed) => stripe.checkout.sessions.create(
      {
        ...managed,
        mode: "payment",
        customer: customerId,
        line_items: [{
          price_data: { currency: payment.currency || "eur", unit_amount: payment.amount_cents, product_data: { name: description } },
          quantity: 1,
        }],
        payment_intent_data: { description, metadata: livraison },
        expires_at: expiresAt,
        metadata: livraison,
        success_url: platform === "web" ? retourOk : retourOkAppli,
        cancel_url: platform === "web" ? retourAnnule : retourAnnuleAppli,
      },
      { idempotencyKey: idempotencyKey("secoto-livraison-checkout", payment.id, { amount: payment.amount_cents, expiresAt, managed, platform, tentative: payment.reglement_tentatives || 0 }) },
    ));
    await memoriser({ reglement_client_session_id: session.id });
    return response(200, { mode: "checkout", checkoutUrl: session.url, amountCents: payment.amount_cents, currency: payment.currency || "eur", circuit: "livraison" });
  }

  // Validation bancaire demandée au moment du débit.
  if (order.status === "partner_locked" && payment.direct_action_required_at && payment.status === "requires_capture") {
    if (differe) {
      const { data: ctx } = await admin.rpc("secoto_differe_charge_context", { p_order_id: order.id });
      if (!ctx || ctx.error) return response(409, { error: "payment_not_payable" });
      const lockMs = order.lock_expires_at ? Date.parse(order.lock_expires_at) : 0;
      const expiresAt = Math.floor(Math.min(Math.max(now + 31 * 60 * 1000, lockMs), now + 23 * 3600 * 1000) / 1000);
      const description = `Transport de véhicule — commande ${order.public_ref}`;
      // Application 2.3.6+ : paiement dans la feuille intégrée (Klarna en
      // plusieurs fois compris), sans passer par le navigateur. Montant lu en
      // base ; une intention par acceptation de transporteur.
      if (feuilleKlarna) {
        const intent = await createWithManagedPaymentsFallback((managed) => stripe.paymentIntents.create(
          {
            ...managed,
            amount: ctx.amount_cents,
            currency: ctx.currency || "eur",
            customer: customerId,
            description,
            automatic_payment_methods: { enabled: true },
            metadata,
          },
          { idempotencyKey: idempotencyKey("secoto-differe-sheet", payment.id, { amount: ctx.amount_cents, customerId, managed, offer: ctx.lock_offer_id || "" }) },
        ));
        const ephemeralKey = await stripe.ephemeralKeys
          .create({ customer: customerId }, { apiVersion: STRIPE_MOBILE_API_VERSION })
          .then((key) => key.secret)
          .catch(() => null);
        return response(200, {
          mode: "payment_sheet",
          clientSecret: intent.client_secret,
          publishableKey: STRIPE_PUBLISHABLE_KEY || null,
          customerId,
          ephemeralKey,
          amountCents: ctx.amount_cents,
          currency: ctx.currency || "eur",
          circuit,
          billing: billingPrefill(account),
        });
      }
      const session = await createWithManagedPaymentsFallback((managed) => stripe.checkout.sessions.create(
        {
          ...managed,
          mode: "payment",
          customer: customerId,
          line_items: [{
            price_data: { currency: ctx.currency || "eur", unit_amount: ctx.amount_cents, product_data: { name: description } },
            quantity: 1,
          }],
          payment_intent_data: { description, metadata },
          expires_at: expiresAt,
          metadata,
          success_url: retourOkAppli,
          cancel_url: retourAnnuleAppli,
        },
        { idempotencyKey: idempotencyKey("secoto-differe-checkout", payment.id, { amount: ctx.amount_cents, expiresAt, managed, platform, offer: ctx.lock_offer_id || "" }) },
      ));
      return response(200, { mode: "checkout", checkoutUrl: session.url, amountCents: ctx.amount_cents, currency: ctx.currency || "eur", circuit });
    }
    const { data: ctx } = await admin.rpc("secoto_direct_charge_context", { p_order_id: order.id });
    if (!ctx || ctx.error || !ctx.connected_account_id) return response(409, { error: "payment_not_payable" });
    const lockMs = order.lock_expires_at ? Date.parse(order.lock_expires_at) : 0;
    const expiresAt = Math.floor(Math.max(now + 31 * 60 * 1000, lockMs) / 1000);
    const description = `Transport de véhicule sur plateau — commande ${order.public_ref}`;
    const session = await createWithManagedPaymentsFallback((managed) => stripe.checkout.sessions.create(
      {
        ...managed,
        mode: "payment",
        line_items: [{
          price_data: { currency: ctx.currency || "eur", unit_amount: ctx.amount_cents, product_data: { name: description } },
          quantity: 1,
        }],
        payment_intent_data: { application_fee_amount: ctx.application_fee_cents, description, metadata },
        // 081 : décomposition affichée au-dessus du bouton, avant validation.
        ...(messageDecomposition({ amount_cents: ctx.amount_cents, commission_cents: ctx.application_fee_cents })
          ? { custom_text: { submit: { message: messageDecomposition({ amount_cents: ctx.amount_cents, commission_cents: ctx.application_fee_cents }) } } }
          : {}),
        customer_email: account?.email || undefined,
        expires_at: expiresAt,
        metadata,
        success_url: retourOkAppli,
        cancel_url: retourAnnuleAppli,
      },
      {
        stripeAccount: ctx.connected_account_id,
        idempotencyKey: idempotencyKey("secoto-direct-checkout", payment.id, {
          account: ctx.connected_account_id, amount: ctx.amount_cents, fee: ctx.application_fee_cents, expiresAt, managed, decompo: 1, platform,
        }),
      },
    ));
    return response(200, { mode: "checkout", checkoutUrl: session.url, amountCents: ctx.amount_cents, currency: ctx.currency || "eur", circuit: "direct" });
  }

  // Carte (re)validée uniquement tant qu'aucun transporteur n'a été débité.
  if (!["awaiting_payment", "searching_partner"].includes(order.status)) {
    return response(409, { error: "payment_not_payable" });
  }

  // Application 2.3.6+ : feuille de paiement intégrée, Klarna et Satispay
  // compris (elle connaît son adresse de retour secoto://stripe-redirect).
  if (feuilleKlarna) {
    let setupIntent = null;
    if (payment.setup_intent_id) {
      setupIntent = await stripe.setupIntents.retrieve(payment.setup_intent_id);
      if (!["requires_payment_method", "requires_confirmation", "requires_action"].includes(setupIntent.status)) setupIntent = null;
    }
    if (!setupIntent) {
      setupIntent = await stripe.setupIntents.create(
        {
          customer: customerId,
          usage: "off_session",
          ...(carteSeule ? { payment_method_types: ["card"] } : { automatic_payment_methods: { enabled: true } }),
          description: `Validation de carte — commande ${order.public_ref}`,
          metadata,
        },
        { idempotencyKey: idempotencyKey(`secoto-${circuit}-setup`, payment.id, { customerId, status: payment.status, previous: payment.setup_intent_id || "" }) },
      );
    }
    await admin.from("payments").update({
      setup_intent_id: setupIntent.id,
      ...(["pending", "failed"].includes(payment.status) ? { status: "processing" } : {}),
      updated_at: new Date(now).toISOString(),
    }).eq("id", payment.id);

    // Sans clé éphémère, la validation reste possible : seules les cartes
    // enregistrées ne sont pas proposées.
    const ephemeralKey = await stripe.ephemeralKeys
      .create({ customer: customerId }, { apiVersion: STRIPE_MOBILE_API_VERSION })
      .then((key) => key.secret)
      .catch(() => null);
    return response(200, {
      mode: "setup_sheet",
      setupIntentClientSecret: setupIntent.client_secret,
      publishableKey: STRIPE_PUBLISHABLE_KEY || null,
      customerId,
      ephemeralKey,
      amountCents: payment.amount_cents,
      currency: payment.currency || "eur",
      circuit,
      returnUrl: `${SECOTO_APP_URL}/?ecran=${returnScreen}&${returnQuery}`,
      billing: billingPrefill(account),
    });
  }

  // Web, et application 2.3.5 ou antérieure (feuille sans adresse de retour,
  // donc sans Klarna) : page Stripe en mode « setup ». Depuis l'iPhone /
  // Android, elle s'ouvre dans le navigateur et revient dans l'application
  // (passerelle /retour-app.html).
  // Stripe « Managed Payments » (actif par défaut sur le compte SECOTO)
  // refuse le mode « setup » : on le désactive pour cette requête.
  const natif = platform !== "web";
  const session = await createWithManagedPaymentsFallback((managed) => stripe.checkout.sessions.create(
    {
      ...managed,
      mode: "setup",
      customer: customerId,
      currency: payment.currency || "eur",
      ...(carteSeule ? { payment_method_types: ["card"] } : {}),
      setup_intent_data: { metadata, description: `Validation de carte — commande ${order.public_ref}` },
      metadata,
      success_url: natif ? retourOkAppli : retourOk,
      cancel_url: natif ? retourAnnuleAppli : retourAnnule,
    },
    { idempotencyKey: idempotencyKey(`secoto-${circuit}-setup-web`, payment.id, { customerId, status: payment.status, returnScreen, returnQuery, managed, ...(natif ? { platform } : {}) }) },
  ));
  if (["pending", "failed"].includes(payment.status)) {
    await admin.from("payments").update({ status: "processing", updated_at: new Date(now).toISOString() }).eq("id", payment.id);
  }
  return response(200, { mode: "checkout", checkoutUrl: session.url, amountCents: payment.amount_cents, currency: payment.currency || "eur", circuit, setup: true });
}

export default withLambda(withCors(handler));
