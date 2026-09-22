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
    .select("id,role,email,stripe_connect_account_id,stripe_connect_onboarded_at")
    .eq("id", userId).single();
  if (!account || account.role !== "transporter") return json(403, { error: "forbidden" });

  const stripe = new Stripe(STRIPE_SECRET_KEY);
  let acctId = account.stripe_connect_account_id;

  const sync = async (acct) => {
    const s = connectStatusFromAccount(acct);
    await admin.from("accounts").update({
      stripe_connect_status: s.status,
      stripe_transfers_enabled: s.transfers_enabled,
      stripe_payouts_enabled: s.payouts_enabled,
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
        // Clé par utilisateur : deux appuis simultanés ne créent qu'un compte.
        const acct = await stripe.accounts.create({
          type: "express",
          country: "FR",
          email: account.email || undefined,
          capabilities: { transfers: { requested: true } },
          business_profile: { mcc: "4214", product_description: "Transport de véhicules réalisé pour SECOTO" },
          metadata: { secoto_account_id: userId },
        }, { idempotencyKey: `secoto-connect-account-${userId}` });
        await admin.from("accounts")
          .update({ stripe_connect_account_id: acct.id, stripe_connect_status: "incomplete", stripe_connect_updated_at: new Date().toISOString() })
          .eq("id", userId).is("stripe_connect_account_id", null);
        const { data: relu } = await admin.from("accounts").select("stripe_connect_account_id").eq("id", userId).single();
        acctId = relu?.stripe_connect_account_id || acct.id;
      }
      const link = await stripe.accountLinks.create({
        account: acctId,
        type: "account_onboarding",
        refresh_url: `${SECOTO_APP_URL}/?ecran=bank&connect=relancer`,
        return_url: `${SECOTO_APP_URL}/?ecran=bank&connect=retour`,
      });
      return json(200, { url: link.url });
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
