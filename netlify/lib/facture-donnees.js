// ============================================================================
// SECOTO — données de la facture acquittée d'une commande à la demande.
// ----------------------------------------------------------------------------
// Tout vient de la base (commande, devis, client, transporteur, suivi) et, pour
// un paiement en ligne, de Stripe (carte, date et heure, code d'autorisation,
// 3-D Secure, lien du reçu officiel). Rien n'est deviné : une information
// introuvable n'apparaît pas sur la facture.
// ============================================================================

const MARQUES = { visa: "Visa", mastercard: "Mastercard", amex: "American Express", cartes_bancaires: "CB", discover: "Discover", diners: "Diners", jcb: "JCB", unionpay: "UnionPay" };
const FINANCEMENT = { debit: "débit", credit: "crédit", prepaid: "prépayée" };
const PAYS = { FR: "France", BE: "Belgique", CH: "Suisse", LU: "Luxembourg", DE: "Allemagne", ES: "Espagne", IT: "Italie", GB: "Royaume-Uni", PT: "Portugal", NL: "Pays-Bas", MA: "Maroc", DZ: "Algérie", TN: "Tunisie" };
const KLARNA = { pay_in_installments: "paiement en plusieurs fois", pay_later: "paiement différé", pay_now: "paiement immédiat" };

const departement = (place) => {
  const cp = String(place?.postcode || "").trim();
  return /^\d{5}$/.test(cp) ? (cp.startsWith("97") ? cp.slice(0, 3) : cp.slice(0, 2)) : "";
};
const ville = (place) => {
  const dep = departement(place);
  return `${place?.city || ""}${dep ? ` (${dep})` : ""}`.trim();
};

/** Moyen de paiement lisible d'après le détail Stripe de la transaction. */
export function moyenDePaiement(details) {
  if (!details?.type) return { type: "en_ligne", moyen: "Paiement en ligne" };
  if (details.type === "card" && details.card) {
    const c = details.card;
    const parts = ["Carte", MARQUES[c.brand] || (c.brand ? c.brand.toUpperCase() : ""), FINANCEMENT[c.funding] || ""].filter(Boolean).join(" ");
    const pays = c.country ? ` (${PAYS[c.country] || c.country})` : "";
    const wallet = c.wallet?.type === "apple_pay" ? " via Apple Pay" : c.wallet?.type === "google_pay" ? " via Google Pay" : "";
    return {
      type: "carte",
      moyen: `${parts}${c.last4 ? ` •••• ${c.last4}` : ""}${pays}${wallet}`,
      troisDS: c.three_d_secure?.result === "authenticated",
      codeAutorisation: c.authorization_code || "",
    };
  }
  if (details.type === "klarna") {
    const cat = KLARNA[details.klarna?.payment_method_category];
    return { type: "klarna", moyen: `Klarna${cat ? ` — ${cat}` : ""}` };
  }
  if (details.type === "link") return { type: "en_ligne", moyen: "Link (Stripe)" };
  return { type: "en_ligne", moyen: `Paiement en ligne (${details.type})` };
}

/** Transaction Stripe réussie de la commande (paiement à la livraison, « Payer maintenant », Checkout). */
export async function transactionStripe(stripe, payment) {
  const candidats = [payment.reglement_client_intent_id, payment.provider_intent_id].filter((v) => /^pi_/.test(v || ""));
  if (payment.reglement_client_session_id) {
    try {
      const session = await stripe.checkout.sessions.retrieve(payment.reglement_client_session_id);
      const pi = typeof session.payment_intent === "string" ? session.payment_intent : session.payment_intent?.id;
      if (pi) candidats.unshift(pi);
    } catch { /* session expirée ou supprimée : on essaie les autres références */ }
  }
  for (const id of [...new Set(candidats)]) {
    const intent = await stripe.paymentIntents.retrieve(id, { expand: ["latest_charge"] });
    const charge = intent.latest_charge && typeof intent.latest_charge === "object" ? intent.latest_charge : null;
    if (intent.status === "succeeded" && charge?.paid) return { intent, charge };
  }
  return null;
}

export async function collecterFacture(admin, stripe, orderId) {
  const { data: order, error } = await admin
    .from("transport_orders")
    .select("id,public_ref,status,mode,mode_reglement,invoice_number,invoiced_at,client_price_cents,pickup_at,mission_id,assigned_partner_id,account_id,quote_id,payment_id,is_test")
    .eq("id", orderId)
    .maybeSingle();
  if (error) throw new Error(`facture_commande:${error.message}`);
  if (!order?.invoice_number) throw new Error("facture_sans_numero");

  const [{ data: quote }, { data: payment }, { data: client }, { data: carrier }, { data: events }] = await Promise.all([
    admin.from("transport_quotes").select("vehicle,pickup,delivery,route").eq("id", order.quote_id).maybeSingle(),
    admin.from("payments").select("status,amount_cents,paid_at,captured_at,provider_intent_id,reglement_client_intent_id,reglement_client_session_id,especes_statut,especes_declare_at").eq("id", order.payment_id).maybeSingle(),
    admin.from("accounts").select("full_name,email,phone,company_name,billing_legal_name,billing_address,billing_siren").eq("id", order.account_id).maybeSingle(),
    order.assigned_partner_id
      ? admin.from("accounts").select("full_name,company_name").eq("id", order.assigned_partner_id).maybeSingle()
      : Promise.resolve({ data: null }),
    order.mission_id
      ? admin.from("mission_tracking_events").select("event_type,created_at").eq("mission_id", order.mission_id).order("created_at", { ascending: true })
      : Promise.resolve({ data: [] }),
  ]);
  if (!payment) throw new Error("facture_paiement_introuvable");

  const evenement = (type) => (events || []).find((e) => String(e.event_type) === type)?.created_at || null;
  const vehicle = quote?.vehicle || {};
  const pro = Boolean(client?.billing_siren || client?.billing_legal_name || client?.company_name);

  // Règlement : paiement en ligne réussi, sinon espèces ou virement.
  let reglement = null;
  const tx = await transactionStripe(stripe, payment);
  if (tx) {
    const { intent, charge } = tx;
    const moyen = moyenDePaiement(charge.payment_method_details);
    const rembourse = Number(charge.amount_refunded || 0);
    reglement = {
      ...moyen,
      date: new Date(charge.created * 1000),
      intentId: intent.id,
      chargeId: charge.id,
      montantCents: charge.amount,
      statut: rembourse > 0 ? `Paiement réussi · remboursé à hauteur de ${(rembourse / 100).toFixed(2).replace(".", ",")} €` : "Paiement réussi · aucun remboursement",
      libelleReleve: charge.calculated_statement_descriptor || "",
      recuUrl: charge.receipt_url || "",
      // Sans nom de titulaire chez Stripe, on n'associe pas une adresse e-mail
      // tierce au client : la page 2 reprend alors le nom et l'e-mail du compte.
      payeur: charge.billing_details?.name ? { nom: charge.billing_details.name, email: charge.billing_details.email || "" } : null,
    };
  } else if (payment.especes_statut === "recu") {
    reglement = { type: "especes", date: payment.especes_declare_at };
  } else if (order.mode_reglement === "virement" && payment.status === "paid") {
    reglement = { type: "virement", date: payment.paid_at || payment.captured_at };
  }
  if (!reglement?.date) throw new Error("facture_reglement_introuvable");

  return {
    numero: order.invoice_number,
    dateEmission: order.invoiced_at,
    ref: order.public_ref,
    montantCents: order.client_price_cents,
    client: {
      nom: client?.billing_legal_name || client?.company_name || client?.full_name || "Client",
      type: pro ? "Professionnel" : "Particulier",
      adresse: typeof client?.billing_address === "string" ? client.billing_address : "",
      email: client?.email || "",
      telephone: client?.phone || "",
    },
    transport: {
      vehicule: `${String(vehicle.model || "").trim() || "Véhicule"}${vehicle.rolling === false ? " (non roulant)" : ""}`,
      mode: order.mode === "convoyage" ? "convoyage" : "plateau",
      priseEnCharge: evenement("pickup_inspection") || order.pickup_at,
      livraison: evenement("delivery_inspection"),
      transporteur: carrier?.company_name || carrier?.full_name || "",
    },
    adresseDepart: quote?.pickup?.label || quote?.pickup?.city || "",
    adresseArrivee: quote?.delivery?.label || quote?.delivery?.city || "",
    distanceKm: Number(quote?.route?.distance_km) || null,
    trajetCourt: `${ville(quote?.pickup)} - ${ville(quote?.delivery)}`,
    reglement,
  };
}

/** Corps de l'e-mail qui accompagne la facture PDF. */
export function corpsEmailFacture(d) {
  return [
    "Bonjour,",
    "",
    `Merci pour votre confiance ! Veuillez trouver ci-joint votre facture acquittée ${d.numero} (commande ${d.ref}) :`,
    "",
    `- ${d.transport.vehicule}, ${d.transport.mode === "convoyage" ? "convoyage par la route" : "transport sur camion plateau"}`,
    `- ${d.trajetCourt}${d.distanceKm ? `, ${Math.round(d.distanceKm)} km` : ""}`,
    `- Montant : ${(d.montantCents / 100).toFixed(2).replace(".", ",")} €, réglé intégralement`,
    "",
    ["carte", "klarna", "en_ligne"].includes(d.reglement.type)
      ? "La page 2 du PDF contient le justificatif de paiement et le lien vers le reçu officiel émis par Stripe, notre prestataire de paiement."
      : "La facture indique la date et le mode de votre règlement.",
    "",
    "Besoin d'une mention particulière (adresse postale, raison sociale) ? Répondez simplement à cet e-mail.",
    "",
    "Bien cordialement,",
    "L'Équipe SECOTO",
    "07 83 27 82 31",
  ].join("\n");
}
