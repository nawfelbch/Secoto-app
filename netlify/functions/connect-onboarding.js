import { withLambda } from "@netlify/aws-lambda-compat";
// SECOTO — compte de versement Stripe Connect du transporteur (migration 036).
//  action "status"    : état du compte, resynchronisé depuis Stripe
//  action "link"      : crée le compte Express si besoin, puis le lien
//                       d'inscription hébergé par Stripe (identité, IBAN)
//  action "dashboard" : lien de connexion à l'espace Express du transporteur
//
// Le transporteur ne transmet JAMAIS d'identifiant Stripe : le compte est
// toujours retrouvé depuis son compte SECOTO authentifié, côté serveur.
import Stripe from "stripe";
import { authenticatedUserId, bearer, json, parseBody, serviceClient, withCors } from "../lib/secoto-server.js";

const { STRIPE_SECRET_KEY, SECOTO_APP_URL = "https://app.secoto-transport.fr" } = process.env;

// 074 : paiement direct plateau.
const PLATEAU_TYPES = new Set(["vl", "pl"]);
const DIRECT_PRODUCT_DESCRIPTION = "Transport de véhicules sur camion plateau, réservé via SECOTO";
export const PAYMENT_DOMAIN = new URL(SECOTO_APP_URL).hostname;

// Stripe n'accepte plus la création de comptes « v1 » pour les nouvelles
// intégrations (c'est déjà le cas en mode test). Le compte est alors créé avec
// l'API v2, avec la même répartition qu'un compte Express : SECOTO paie les
// frais Stripe et reste responsable en dernier recours. Tout le reste
// (lecture, liens d'inscription, paiements) accepte les deux versions.
export function isAccountsV1Refused(error) {
  const message = String(error?.raw?.message || error?.message || "");
  return /v2\/core\/accounts|Accounts v1/i.test(message);
}

export function v2AccountParams({ email, userId, directOn }) {
  return {
    contact_email: email || undefined,
    identity: { country: "fr" },
    dashboard: "express",
    defaults: {
      currency: "eur",
      responsibilities: { fees_collector: "application", losses_collector: "application" },
    },
    configuration: {
      recipient: { capabilities: { stripe_balance: { stripe_transfers: { requested: true } } } },
      ...(directOn ? { merchant: { mcc: "4214", capabilities: { card_payments: { requested: true } } } } : {}),
    },
    metadata: { secoto_account_id: userId },
  };
}

export async function createConnectedAccount(stripe, { email, userId, directOn, cle }, creerV1) {
  try {
    return await creerV1();
  } catch (error) {
    if (!isAccountsV1Refused(error)) throw error;
    return stripe.v2.core.accounts.create(v2AccountParams({ email, userId, directOn }), { idempotencyKey: `${cle}-v2` });
  }
}

export async function onboardingLink(stripe, acctId, { merchant = false } = {}) {
  const refresh = `${SECOTO_APP_URL}/?ecran=bank&connect=relancer`;
  const retour = `${SECOTO_APP_URL}/?ecran=bank&connect=retour`;
  try {
    return await stripe.accountLinks.create({ account: acctId, type: "account_onboarding", refresh_url: refresh, return_url: retour });
  } catch (erreurV1) {
    if (erreurV1?.type !== "StripeInvalidRequestError") throw erreurV1;
    // Compte créé en v2 : lien d'inscription v2. Si la version v2 échoue
    // aussi, c'est le motif d'origine qui est remonté.
    const lienV2 = (configurations) => stripe.v2.core.accountLinks.create({
      account: acctId,
      use_case: { type: "account_onboarding", account_onboarding: { configurations, refresh_url: refresh, return_url: retour } },
    });
    try {
      return await lienV2(merchant ? ["recipient", "merchant"] : ["recipient"]);
    } catch {
      if (merchant) {
        try { return await lienV2(["recipient"]); } catch { /* motif d'origine ci-dessous */ }
      }
      throw erreurV1;
    }
  }
}

// Activation du paiement direct sur un compte existant. Chaque réglage est
// demandé séparément : un réglage refusé par Stripe pour ce type de compte
// n'empêche pas les autres.
export async function upgradeForDirect(stripe, acctId) {
  const heure = new Date().toISOString().slice(0, 13);
  try {
    await stripe.accounts.update(acctId, {
      capabilities: { card_payments: { requested: true }, transfers: { requested: true } },
      business_profile: { product_description: DIRECT_PRODUCT_DESCRIPTION },
    }, { idempotencyKey: `secoto-direct-upgrade-${acctId}-${heure}` });
  } catch (error) {
    if (!isAccountsV1Refused(error) && !/v2/i.test(String(error?.message || ""))) throw error;
    await stripe.v2.core.accounts.update(acctId, {
      configuration: { merchant: { mcc: "4214", capabilities: { card_payments: { requested: true } } } },
    }, { idempotencyKey: `secoto-direct-upgrade-v2-${acctId}-${heure}` });
  }
  try {
    await stripe.accounts.update(acctId, { settings: { payouts: { debit_negative_balances: true } } });
  } catch (error) {
    console.error("[connect-onboarding] debit_negative_balances", error?.message);
  }
}

// Traduit l'état Stripe en un statut SECOTO simple, affiché au transporteur.
export function connectStatusFromAccount(acct) {
  const transfers = acct?.capabilities?.transfers === "active";
  const payouts = Boolean(acct?.payouts_enabled);
  const disabled = acct?.requirements?.disabled_reason || null;
  let status = "incomplete";
  if (transfers && payouts) status = "active";
  else if (disabled && !String(disabled).startsWith("requirements.pending")) status = "restricted";
  else if (acct?.details_submitted) status = "pending";
  return {
    status,
    transfers_enabled: transfers,
    payouts_enabled: payouts,
    // 074 : encaisser lui-même les paiements par carte (circuit direct plateau).
    card_payments_enabled: acct?.capabilities?.card_payments === "active",
    details_submitted: Boolean(acct?.details_submitted),
    currently_due: acct?.requirements?.currently_due?.length || 0,
  };
}

const handler = async (event) => {
  if (event.httpMethod !== "POST") return json(405, { error: "method_not_allowed" });
  const admin = serviceClient();
  if (!admin || !STRIPE_SECRET_KEY) return json(503, { error: "server_not_configured" });
  const userId = await authenticatedUserId(bearer(event));
  if (!userId) return json(401, { error: "unauthorized" });
  const action = parseBody(event)?.action;

  const { data: account } = await admin.from("accounts")
    .select("id,role,email,transporter_type,stripe_connect_account_id,stripe_connect_onboarded_at")
    .eq("id", userId).single();
  if (!account || account.role !== "transporter") return json(403, { error: "forbidden" });

  const stripe = new Stripe(STRIPE_SECRET_KEY);
  let acctId = account.stripe_connect_account_id;
  const plateau = PLATEAU_TYPES.has(String(account.transporter_type || ""));

  const sync = async (acct) => {
    const s = connectStatusFromAccount(acct);
    await admin.from("accounts").update({
      stripe_connect_status: s.status,
      stripe_transfers_enabled: s.transfers_enabled,
      stripe_payouts_enabled: s.payouts_enabled,
      stripe_card_payments_enabled: s.card_payments_enabled,
      stripe_connect_updated_at: new Date().toISOString(),
      ...(s.status === "active" && !account.stripe_connect_onboarded_at
        ? { stripe_connect_onboarded_at: new Date().toISOString() } : {}),
    }).eq("id", userId);
    return s;
  };

  try {
    if (action === "status") {
      if (!acctId) return json(200, { status: "none" });
      return json(200, await sync(await stripe.accounts.retrieve(acctId)));
    }

    if (action === "link") {
      if (!acctId) {
        const { data: flag } = await admin.from("secoto_feature_flags").select("enabled").eq("key", "plateau_paiement_direct").maybeSingle();
        const directOn = plateau && Boolean(flag?.enabled);
        // Clé par utilisateur : deux appuis simultanés ne créent qu'un compte.
        const cle = `secoto-connect-account-${userId}-${new Date().toISOString().slice(0, 13)}`;
        const acct = await createConnectedAccount(stripe, { email: account.email, userId, directOn, cle }, () => stripe.accounts.create({
          type: "express",
          country: "FR",
          email: account.email || undefined,
          // 074 : un transporteur plateau encaisse lui-même les paiements de
          // ses clients (circuit direct) ; un convoyeur reçoit des virements.
          // Interrupteur éteint : création strictement identique à avant.
          capabilities: directOn
            ? { transfers: { requested: true }, card_payments: { requested: true } }
            : { transfers: { requested: true } },
          business_profile: {
            mcc: "4214",
            product_description: directOn ? DIRECT_PRODUCT_DESCRIPTION : "Transport de véhicules réalisé pour SECOTO",
          },
          metadata: { secoto_account_id: userId },
          // La cle d'idempotence protege du double-clic, mais Stripe rejoue aussi
          // les ERREURS memorisees pendant 24 h : une panne passagere bloquerait
          // le transporteur une journee entiere. La cle change donc chaque heure.
        }, { idempotencyKey: cle }));
        await admin.from("accounts")
          .update({ stripe_connect_account_id: acct.id, stripe_connect_status: "incomplete", stripe_connect_updated_at: new Date().toISOString() })
          .eq("id", userId).is("stripe_connect_account_id", null);
        const { data: relu } = await admin.from("accounts").select("stripe_connect_account_id").eq("id", userId).single();
        acctId = relu?.stripe_connect_account_id || acct.id;
      }
      const link = await onboardingLink(stripe, acctId, { merchant: plateau });
      return json(200, { url: link.url });
    }

    // 074 : activation du paiement direct (plateau). Une seule fois :
    //  1. le compte peut encaisser les cartes (card_payments) ;
    //  2. Stripe lui verse automatiquement ce qu'il encaisse (calendrier
    //     automatique, inchangé) ; un remboursement ultérieur est repris sur
    //     ses paiements suivants ou, à défaut, sur son compte bancaire ;
    //  3. Apple Pay et Google Pay sont autorisés sur la version web de l'app
    //     pour ce compte (l'app iPhone / Android n'a besoin de rien).
    // Si Stripe réclame des informations, le transporteur reçoit le lien
    // d'inscription hébergé : il n'installe rien et ne revoit plus Stripe.
    if (action === "direct") {
      if (!plateau) return json(403, { error: "plateau_only" });
      if (!acctId) return json(409, { error: "no_account" });
      await upgradeForDirect(stripe, acctId);
      try {
        await stripe.paymentMethodDomains.create({ domain_name: PAYMENT_DOMAIN }, { stripeAccount: acctId });
      } catch (erreur) {
        // Domaine déjà enregistré : normal. Autre motif : tracé, non bloquant
        // (la carte reste toujours proposée).
        if (!/already|exist/i.test(String(erreur?.message || ""))) console.error("[connect-onboarding] domaine", erreur?.message);
      }
      const acct = await stripe.accounts.retrieve(acctId);
      const etat = await sync(acct);
      if (etat.card_payments_enabled && !acct?.requirements?.currently_due?.length) return json(200, { ...etat, url: null });
      const link = await onboardingLink(stripe, acctId, { merchant: true });
      return json(200, { ...etat, url: link.url });
    }

    // Diagnostic : identifie le compte Stripe derriere la cle du serveur, sans
    // jamais exposer la cle elle-meme.
    if (action === "diag") {
      const me = await stripe.accounts.retrieve();
      return json(200, { account: me?.id || null, livemode: me?.charges_enabled ?? null, country: me?.country || null });
    }

    if (action === "dashboard") {
      if (!acctId) return json(409, { error: "no_account" });
      const login = await stripe.accounts.createLoginLink(acctId);
      return json(200, { url: login.url });
    }

    return json(400, { error: "unknown_action" });
  } catch (error) {
    console.error("[connect-onboarding]", action, error?.message);
    // Le motif exact vient de Stripe (configuration de la plateforme, capacite
    // manquante...). Sans lui, le transporteur et l'admin restent aveugles.
    return json(502, {
      error: "stripe_unavailable",
      detail: error?.raw?.message || error?.message || null,
      code: error?.code || error?.raw?.code || null,
    });
  }
};

export default withLambda(withCors(handler));
