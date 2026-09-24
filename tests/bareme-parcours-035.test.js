// ============================================================================
// SECOTO 034-035 — le barème et le parcours décidés le 18/09/2026 sont bien
// ceux qui sont écrits en base et affichés à l'écran.
// ============================================================================
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const GRID = readFileSync(new URL("../supabase/migrations/202609180034_bareme_secoto_2026.sql", import.meta.url), "utf8");
const FLOW = readFileSync(new URL("../supabase/migrations/202609180035_parcours_commande_final.sql", import.meta.url), "utf8");

const od = await import("../src/lib/orderCopy.js");

// ---------------------------------------------------------------------------
// Barème
// ---------------------------------------------------------------------------
test("le barème plateau porte exactement les tarifs décidés", () => {
  const plateau = GRID.slice(GRID.indexOf("do $plateau$"), GRID.indexOf("do $convoyage$"));
  assert.match(plateau, /'voiture',\s+jsonb_build_object\('client_eur_per_km', 1\.12, 'partner_eur_per_km', 0\.97\)/);
  assert.match(plateau, /'moto',\s+jsonb_build_object\('client_eur_per_km', 1\.00, 'partner_eur_per_km', 0\.85, 'client_cap_eur', 400\)/);
  assert.match(plateau, /'utilitaire', jsonb_build_object\('client_eur_per_km', 1\.25, 'partner_eur_per_km', 1\.10\)/);
  assert.match(plateau, /'minimum_eur', 115/);
  assert.match(plateau, /'non_rolling_client_eur', 80/);
  assert.match(plateau, /'non_rolling_partner_eur', 60/);
});

test("le barème convoyage est un forfait de 1,00 €/km, convoyeur 0,55 et 0,65 en utilitaire", () => {
  const conv = GRID.slice(GRID.indexOf("do $convoyage$"));
  assert.match(conv, /'voiture',\s+jsonb_build_object\('client_eur_per_km', 1\.00, 'partner_eur_per_km', 0\.55\)/);
  assert.match(conv, /'moto',\s+jsonb_build_object\('client_eur_per_km', 1\.00, 'partner_eur_per_km', 0\.55\)/);
  assert.match(conv, /'utilitaire', jsonb_build_object\('client_eur_per_km', 1\.00, 'partner_eur_per_km', 0\.65\)/);
  assert.match(conv, /'minimum_eur', 115/);
});

test("SECOTO encaisse la totalité : aucun transport n'est réglé en direct", () => {
  // Les deux branches du moteur renvoient collect = prix client, direct = 0.
  const returns = GRID.match(/'collect_cents',[^\n]*\n\s*'transport_direct_cents',[^\n]*/g) || [];
  assert.equal(returns.length, 2, "le moteur a deux points de sortie");
  for (const block of returns) {
    assert.match(block, /'collect_cents', \(v_client \* 100\)::integer/);
    assert.match(block, /'transport_direct_cents', 0/);
  }
  // La réservation reprend le prix client, pas une commission.
  assert.match(FLOW, /v_quote\.client_price_cents, 0, v_quote\.pickup_at\)/);
});

test("le contrôle en base couvre les prix annoncés à Nawfal", () => {
  for (const expected of [
    /56000 or \(v ->> 'partner_cents'\)::int <> 48500/,   // voiture 500 km
    /30000 or \(v ->> 'partner_cents'\)::int <> 25500/,   // moto 300 km
    /40000 or \(v ->> 'partner_cents'\)::int <> 34000/,   // moto 800 km, plafond
    /25000 or \(v ->> 'partner_cents'\)::int <> 22000/,   // utilitaire 200 km
    /11500 or \(v ->> 'partner_cents'\)::int <> 9960/,    // plancher 115 €
    /64000 or \(v ->> 'partner_cents'\)::int <> 54500/,   // non roulant +80/+60
    /40000 or \(v ->> 'partner_cents'\)::int <> 22000/,   // convoyage 400 km
    /40000 or \(v ->> 'partner_cents'\)::int <> 26000/,   // convoyage utilitaire
  ]) assert.match(GRID, expected);
});

// ---------------------------------------------------------------------------
// Parcours
// ---------------------------------------------------------------------------
test("les délais décidés sont ceux de la politique en base", () => {
  assert.match(FLOW, /'offer_ttl_minutes', 2880/);            // 48 h
  assert.match(FLOW, /'max_rounds', 1/);                      // un seul tour
  assert.match(FLOW, /'no_partner_refund_hours', 24/);        // remboursement sous 24 h
  assert.match(FLOW, /'payout_delay_hours', 48/);             // transporteur sous 48 h
  assert.match(FLOW, /'free_cancel_hours_before_pickup', 24/);
  assert.match(FLOW, /'late_cancel_retained_pct', 50/);
});

test("le paiement est toujours encaissé tout de suite", () => {
  assert.match(FLOW, /v_strategy := 'capture_then_refund';/);
  assert.doesNotMatch(FLOW.slice(FLOW.indexOf("secoto_od_book_quote")), /authorize_then_capture'\s*\n?\s*else/);
  assert.match(FLOW, /'pending', 'automatic',/);
});

test("la diffusion n'exige plus de préférences réglées", () => {
  assert.match(FLOW, /left join public\.partner_dispatch_preferences pr/);
  assert.match(FLOW, /coalesce\(pr\.available, true\)/);
  for (const filter of ["zones", "vehicle_classes", "weekdays"]) {
    assert.match(FLOW, new RegExp(`pr\\.account_id is null or cardinality\\(pr\\.${filter}\\) = 0`));
  }
});

test("la notification transporteur porte le modèle, les villes, l'état et la rémunération", () => {
  const broadcast = FLOW.slice(FLOW.indexOf("function secoto_private.od_broadcast"), FLOW.indexOf("-- 5. RÉSERVATION"));
  assert.match(broadcast, /v_state := case when coalesce\(\(v_quote\.vehicle ->> 'rolling'\)::boolean, true\) then 'roulant' else 'NON ROULANT' end/);
  assert.match(broadcast, /vehicle ->> 'model'/);
  assert.match(broadcast, /pickup ->> 'city'.*delivery ->> 'city'/s);
  assert.match(broadcast, /€ pour vous/);
});

test("l'annulation applique la règle 24 h / 50 %", () => {
  assert.match(FLOW, /v_late := v_order\.pickup_at - make_interval\(hours => v_free_h::int\) <= now\(\);/);
  assert.match(FLOW, /v_refund := v_order\.client_price_cents - round\(v_order\.client_price_cents \* v_pct \/ 100\)::int;/);
  // Une commande confirmée reste annulable ; seule la prise en charge bloque.
  assert.match(FLOW, /if v_order\.status = 'picked_up' then/);
});

test("le transporteur est réglé dans les 48 h, dans les deux modes", () => {
  const trg = FLOW.slice(FLOW.indexOf("function secoto_private.trg_od_sync_from_mission"), FLOW.indexOf("-- 12. PILOTAGE"));
  assert.match(trg, /v_delay := secoto_private\.policy_num\('payout_delay_hours', 48\);/);
  assert.doesNotMatch(trg, /if v_order\.mode = 'convoyage' then/);
  assert.match(trg, /due_at, mode\)/);
});

test("l'administrateur peut modifier les conditions en cours de mission", () => {
  assert.match(FLOW, /function public\.secoto_admin_od_update_conditions\(p_order_id uuid, p_payload jsonb, p_note text\)/);
  assert.match(FLOW, /if v_order\.status in \('cancelled', 'no_partner'\) then/);
  assert.match(FLOW, /update public\.transport_offers set partner_pay_cents = v_partner/);
  assert.match(FLOW, /Écart de prix à régulariser/);
});

test("les candidatures cèdent la place à accepter ou refuser", () => {
  assert.match(FLOW, /function public\.secoto_mission_accept\(p_mission_id uuid, p_idempotency_key uuid\)/);
  assert.match(FLOW, /from public\.missions m where m\.id = p_mission_id for update/);
  assert.match(FLOW, /Les candidatures sont remplacées par l''''acceptation directe/);
  // Le tableau des missions publiées expose la rémunération, jamais la marge.
  const vue = FLOW.slice(
    FLOW.indexOf("create or replace view public.secoto_public_missions_v2"),
    FLOW.indexOf("grant select on table public.secoto_public_missions_v2"),
  );
  assert.match(vue, /^\s*m\.carrier_pay$/m);
  assert.match(vue, /coalesce\(m\.vehicle_rolling, true\) as vehicle_rolling/);
  const colonnes = vue.slice(vue.indexOf("select"), vue.indexOf("from public.missions"));
  assert.doesNotMatch(colonnes, /m\.client_price|m\.margin|m\.commission_amount|m\.client_total_due/);
});

test("la facture est émise à l'encaissement avec la mention de TVA", () => {
  assert.match(FLOW, /perform secoto_private\.od_issue_invoice\(v_order\.id\);/);
  assert.match(FLOW, /secoto_private\.next_doc_number\('FAC'\)/);
  assert.match(FLOW, /TVA non applicable, article 293 B du CGI\./);
});

test("aucun interrupteur n'est ouvert par les migrations", () => {
  assert.doesNotMatch(GRID, /set enabled = true/);
  assert.doesNotMatch(FLOW, /set enabled = true/);
  assert.match(FLOW, /insert into public\.secoto_feature_flags\(key\) values \('direct_accept'\) on conflict \(key\) do nothing;/);
});

// ---------------------------------------------------------------------------
// Ce que lit le client à l'écran
// ---------------------------------------------------------------------------
test("les libellés client disent exactement ce qui se passe", () => {
  assert.equal(od.OFFER_WINDOW_HOURS, 48);
  assert.equal(od.NO_PARTNER_REFUND_HOURS, 24);
  assert.equal(od.FREE_CANCEL_HOURS, 24);
  assert.equal(od.LATE_CANCEL_RETAINED_PCT, 50);

  const texte = od.paymentExplanation({ funding: "card", mode: "plateau", client_price_cents: 56000 });
  assert.match(texte, /560\s*€/);
  assert.match(texte, /réserve 48 h/);
  // Depuis la 045, le texte distingue le déclenchement du remboursement du
  // délai bancaire : promettre « remboursé sous 24 h » générait des relances.
  assert.match(texte, /remboursement intégral est lancé sous 24 h/);
  assert.match(texte, /banque le crédite sous 5 à 10 jours/);
  assert.doesNotMatch(texte, /mise en relation/);

  assert.match(od.cancellationPolicy(), /jusqu’à 24 h avant/);
  assert.match(od.cancellationPolicy(), /50 % sont retenus/);
  assert.match(od.cancellationNotice({ cancellable: true, late: false }), /remboursé intégralement/);
  assert.match(
    od.cancellationNotice({ cancellable: true, late: true, retained_pct: 50, refund_cents: 28000 }),
    /50 % sont retenus, 280\s*€/,
  );
});

test("le suivi client ne promet plus d'autorisation bancaire", () => {
  assert.deepEqual(od.MILESTONES.map((m) => m.key), [
    "demande_recue", "paiement_encaisse", "partenaire_confirme", "vehicule_recupere", "livraison_effectuee",
  ]);
  assert.equal(od.ORDER_STATUS_LABEL.no_partner, "Aucun transporteur disponible — remboursement en cours");
});

// ---------------------------------------------------------------------------
// Garde-fou de construction : sans les variables Supabase, le bundle se
// construit « avec succès » mais ne contient plus l'application.
// ---------------------------------------------------------------------------
test("la construction refuse de produire un bundle vide", () => {
  const config = readFileSync(new URL("../vite.config.js", import.meta.url), "utf8");
  assert.match(config, /VITE_SUPABASE_URL/);
  assert.match(config, /VITE_SUPABASE_ANON_KEY/);
  assert.match(config, /command === 'build'/);
  assert.match(config, /throw new Error\(/);
});

test("le tableau des missions publiées survit à une base pas encore migrée", () => {
  const app = readFileSync(new URL("../src/App.jsx", import.meta.url), "utf8");
  assert.match(app, /PUBLIC_MISSION_COLUMNS_FALLBACK/);
  assert.match(app, /async function fetchPublicMissions\(limit\)/);
  // Repli uniquement sur une colonne manquante, jamais sur une erreur de droits.
  assert.match(app, /column\|colonne\|42703/);
});

// ---------------------------------------------------------------------------
// Stripe Tax : une session sans code fiscal est refusée dès que le calcul
// automatique est actif sur le compte (« the product tax code is missing »).
// SECOTO est en franchise en base : rien ne doit être ajouté au prix affiché.
// ---------------------------------------------------------------------------
test("les sessions Stripe portent un code fiscal et n'ajoutent aucune taxe", () => {
  for (const nom of ["create-payment-intent", "subscription-checkout"]) {
    const src = readFileSync(new URL(`../netlify/functions/${nom}.js`, import.meta.url), "utf8");
    assert.match(src, /STRIPE_TAX_CODE = "txcd_20030000"/, nom);
    assert.match(src, /tax_code: STRIPE_TAX_CODE/, nom);
    assert.match(src, /automatic_tax: \{ enabled: AUTOMATIC_TAX_ENABLED \}/, nom);
    // Franchise en base par défaut : le calcul automatique reste fermé.
    assert.match(src, /STRIPE_AUTOMATIC_TAX = "false"/, nom);
    // S'il est ouvert un jour, la TVA est comprise dans le prix, jamais ajoutée.
    assert.match(src, /tax_behavior: AUTOMATIC_TAX_ENABLED \? "inclusive" : undefined/, nom);
  }
});

test("le message d'erreur de paiement dit ce qui ne va pas", async () => {
  const src = readFileSync(new URL("../src/lib/payments.js", import.meta.url), "utf8");
  assert.match(src, /const PAYMENT_ERRORS = \{/);
  for (const code of ["server_not_configured", "unauthorized", "payment_not_found", "stripe_unavailable"]) {
    assert.match(src, new RegExp(`${code}:`), code);
  }
  assert.doesNotMatch(src, /throw new Error\("Le service de paiement est momentanément indisponible\."\)/);
});

// ---------------------------------------------------------------------------
// Une cle d'idempotence Stripe est liee a vie aux parametres de son premier
// usage. Basee sur le seul identifiant, elle condamne le paiement des que le
// montant, le libelle ou la fiscalite changent.
// ---------------------------------------------------------------------------
test("les clés d'idempotence Stripe portent l'empreinte des paramètres", async () => {
  const { createHash } = await import("node:crypto");
  for (const nom of ["create-payment-intent", "subscription-checkout"]) {
    const src = readFileSync(new URL(`../netlify/functions/${nom}.js`, import.meta.url), "utf8");
    assert.match(src, /function idempotencyKey\(prefix, id, params\)/, nom);
    assert.match(src, /createHash\("sha256"\)\.update\(JSON\.stringify\(params\)\)/, nom);
    // Plus aucune clé construite sur le seul identifiant.
    assert.doesNotMatch(src, /idempotencyKey: `secoto-(checkout|payment|sub-checkout)-\$\{[^`]*\}`/, nom);
  }
  // Mêmes paramètres → même clé (un double appui reste protégé).
  const cle = (p) => createHash("sha256").update(JSON.stringify(p)).digest("hex").slice(0, 16);
  assert.equal(cle({ amount: 82746, taxCode: "txcd_20030000" }), cle({ amount: 82746, taxCode: "txcd_20030000" }));
  // Paramètre différent → clé différente (la reprise est possible).
  assert.notEqual(cle({ amount: 82746, taxCode: null }), cle({ amount: 82746, taxCode: "txcd_20030000" }));
});

// ---------------------------------------------------------------------------
// Libellés de cases à cocher : en boîte flexible, le texte devient un élément
// qui peut se réduire à zéro, et le libellé s'affiche une lettre par ligne.
// ---------------------------------------------------------------------------
test("les cases à cocher n'écrasent jamais leur libellé", () => {
  const css = readFileSync(new URL("../src/ondemand/ondemand.css", import.meta.url), "utf8");
  const bloc = css.slice(css.indexOf(".od-checks"), css.indexOf(".od-steps-inline"));
  // Grille « auto 1fr » : la seconde colonne prend toute la place restante.
  assert.match(bloc, /grid-template-columns: auto minmax\(0, 1fr\)/);
  // La classe posée directement sur un <label> est couverte elle aussi.
  assert.match(bloc, /label\.od-checks \{/);
  // Aucune coupure caractère par caractère.
  assert.doesNotMatch(bloc, /overflow-wrap: anywhere/);
  assert.doesNotMatch(bloc, /word-break: break-all/);
});

test("aucun message d'erreur brut du navigateur n'atteint l'écran", async () => {
  const { readdirSync } = await import("node:fs");
  const dossiers = [
    new URL("../src/", import.meta.url),
    new URL("../src/ondemand/", import.meta.url),
  ];
  for (const dossier of dossiers) {
    for (const nom of readdirSync(dossier).filter((f) => f.endsWith(".jsx"))) {
      const src = readFileSync(new URL(nom, dossier), "utf8");
      assert.doesNotMatch(
        src,
        /setError\((e|err|error)\.message/,
        `${nom} : passer par humanizeError, sinon « Load failed » s'affiche tel quel`,
      );
    }
  }
  // Le traducteur couvre bien le message de WebKit.
  const { humanizeError } = await import("../src/lib/humanError.js");
  const msg = humanizeError(new TypeError("Load failed"));
  assert.doesNotMatch(msg, /Load failed/);
  assert.match(msg, /réseau|Connexion/i);
});

// ---------------------------------------------------------------------------
// L'application native est servie depuis capacitor://localhost : sans réponse
// au preflight CORS, WebKit abandonne et l'écran affiche « Load failed ».
// ---------------------------------------------------------------------------
test("les fonctions appelées par l'application répondent au preflight CORS", async () => {
  const { withCors, corsHeaders, ALLOWED_ORIGINS } = await import("../netlify/lib/secoto-server.js");
  assert.ok(ALLOWED_ORIGINS.has("capacitor://localhost"));

  const enveloppe = withCors(async () => ({ statusCode: 200, headers: { "Content-Type": "application/json" }, body: "{}" }));
  const pre = await enveloppe({ httpMethod: "OPTIONS", headers: { origin: "capacitor://localhost" } });
  // Jamais 204 : ce statut interdit tout corps, et la couche Lambda de Netlify
  // en construit un — la verification prealable echouait alors en 502, ce qui
  // rendait l'application iOS inutilisable quelle que soit la connexion.
  assert.equal(pre.statusCode, 200);
  assert.notEqual(pre.statusCode, 204);
  assert.ok(pre.body && pre.body.length > 0, "un statut 2xx avec corps, pas un 204 vide");
  assert.equal(pre.headers["Access-Control-Allow-Origin"], "capacitor://localhost");
  assert.match(pre.headers["Access-Control-Allow-Headers"], /Authorization/);

  const post = await enveloppe({ httpMethod: "POST", headers: { origin: "capacitor://localhost" } });
  assert.equal(post.statusCode, 200);
  assert.equal(post.headers["Content-Type"], "application/json");
  assert.equal(post.headers["Access-Control-Allow-Origin"], "capacitor://localhost");

  // Une origine inconnue ne se voit jamais renvoyer sa propre adresse.
  assert.equal(corsHeaders("https://exemple.invalid")["Access-Control-Allow-Origin"], "https://app.secoto-transport.fr");

  for (const nom of ["quote-transport", "create-payment-intent", "offer-accept", "subscription-checkout"]) {
    const src = readFileSync(new URL(`../netlify/functions/${nom}.js`, import.meta.url), "utf8");
    assert.match(src, /export default withLambda\(withCors\(handler\)\);/, nom);
  }
});

// ---------------------------------------------------------------------------
// Stripe « Managed Payments » est actif par défaut sur le compte : dans ce
// mode Stripe devient redevable de la taxe et exige automatic_tax. SECOTO est
// en franchise en base — rien ne doit s'ajouter au prix annoncé.
// ---------------------------------------------------------------------------
test("Managed Payments est désactivé requête par requête", async () => {
  const lib = await import("../netlify/lib/secoto-server.js");
  assert.equal(lib.MANAGED_PAYMENTS_ENABLED, false);
  assert.deepEqual(lib.managedPaymentsParams(), { managed_payments: { enabled: false } });

  // Un compte dont l'API ignore le paramètre ne doit pas bloquer le paiement.
  let appels = 0;
  const resultat = await lib.createWithManagedPaymentsFallback(async (managed) => {
    appels += 1;
    if (appels === 1) {
      assert.deepEqual(managed, { managed_payments: { enabled: false } });
      const e = new Error("Received unknown parameter: managed_payments");
      e.param = "managed_payments";
      throw e;
    }
    assert.deepEqual(managed, {});
    return { id: "cs_test" };
  });
  assert.equal(resultat.id, "cs_test");
  assert.equal(appels, 2);

  // Une vraie erreur Stripe remonte telle quelle, elle n'est pas avalée.
  await assert.rejects(
    lib.createWithManagedPaymentsFallback(async () => { throw new Error("Your card was declined."); }),
    /card was declined/,
  );

  for (const nom of ["create-payment-intent", "subscription-checkout"]) {
    const src = readFileSync(new URL(`../netlify/functions/${nom}.js`, import.meta.url), "utf8");
    assert.match(src, /createWithManagedPaymentsFallback/, nom);
    // Les deux réglages restent cohérents : Managed Payments impose la taxe.
    assert.match(src, /MANAGED_PAYMENTS_ENABLED \|\| String\(STRIPE_AUTOMATIC_TAX\)/, nom);
  }
});

test("aucune fonction ne repond 204 a une verification prealable", async () => {
  const { readdirSync } = await import("node:fs");
  const dossier = new URL("../netlify/functions/", import.meta.url);
  for (const nom of readdirSync(dossier).filter((f) => f.endsWith(".js"))) {
    const src = readFileSync(new URL(nom, dossier), "utf8");
    assert.doesNotMatch(src, /OPTIONS"\) return respond\(204/, nom);
    assert.doesNotMatch(src, /statusCode: 204/, nom);
  }
});
