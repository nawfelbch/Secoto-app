// Migration 038 — devis payable en un clic (sans réseau).
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const SQL = readFileSync(new URL("../supabase/migrations/202609230038_devis_payable_en_un_clic.sql", import.meta.url), "utf8");
const FONCTION = readFileSync(new URL("../netlify/functions/devis-pay.js", import.meta.url), "utf8");
const { page } = await import("../netlify/functions/devis-pay.js");

test("un seul lien de paiement vivant par mission", () => {
  // Deux adresses valides encaisseraient deux fois la même course.
  assert.match(SQL, /create unique index if not exists devis_payment_links_actif_idx/);
  assert.match(SQL, /where revoked_at is null and paid_at is null/);
});

test("le motif devis_course est autorisé sur les paiements", () => {
  const contrainte = SQL.slice(SQL.indexOf("payments_purpose_check"));
  assert.match(contrainte, /'devis_course'/);
});

test("le lien n'est ouvrable ni par un visiteur ni par un compte connecté", () => {
  assert.match(SQL, /revoke all on function public\.secoto_devis_link_open\(text\) from public, anon, authenticated/);
  assert.match(SQL, /revoke all on table public\.devis_payment_links from anon, authenticated/);
});

test("un lien payé, révoqué, expiré ou annulé ne prépare aucun paiement", () => {
  const ouverture = SQL.slice(SQL.indexOf("function public.secoto_devis_link_open"));
  for (const motif of ["deja_paye", "lien_revoque", "lien_expire", "course_annulee"]) {
    assert.match(ouverture, new RegExp(`'error', '${motif}'`));
  }
});

test("le montant vient de la base, jamais de l'URL", () => {
  // La fonction Netlify ne transmet qu'un jeton ; le montant est relu ensuite.
  assert.match(FONCTION, /secoto_devis_link_open", \{ p_token: token \}/);
  assert.doesNotMatch(FONCTION, /queryStringParameters\?\.(amount|montant)/);
  assert.match(FONCTION, /unit_amount: data\.amount_cents/);
});

test("le jeton doit ressembler à un jeton avant tout appel", () => {
  assert.match(FONCTION, /\/\^\[a-f0-9\]\{24,64\}\$\//);
});

test("le retour depuis Stripe ne relance pas de paiement", () => {
  const retour = FONCTION.slice(FONCTION.indexOf('retour === "ok"'));
  assert.match(retour, /paiement est enregistré/);
  assert.ok(FONCTION.indexOf('retour === "ok"') < FONCTION.indexOf("secoto_devis_link_open"));
});

test("le paiement vaut acceptation : le devis passe en signé et le bon part", () => {
  const trigger = SQL.slice(SQL.indexOf("function secoto_private.devis_course_paid"));
  assert.match(trigger, /statut = 'signe'::public\.secoto_doc_statut/);
  assert.match(trigger, /secoto_release_mission_order\(new\.mission_id\)/);
  assert.match(trigger, /new\.purpose <> 'devis_course' or new\.status <> 'paid'/);
});

test("la page client reste lisible et sans jargon", () => {
  const html = page("Lien inutilisable", "Ce lien a expiré.");
  assert.match(html, /<html lang="fr">/);
  assert.match(html, /Ce lien a expiré\./);
  assert.doesNotMatch(html, /mission_id|payment_id|acct_/);
});

// ---------------------------------------------------------------------------
// Migration 039 — deux voies de règlement pour la mise en relation.
// ---------------------------------------------------------------------------
const SQL39 = readFileSync(new URL("../supabase/migrations/202609230039_deux_voies_de_reglement.sql", import.meta.url), "utf8");
const MAINTENANCE = readFileSync(new URL("../netlify/functions/od-maintenance.js", import.meta.url), "utf8");

test("espèces : le lien de paiement est refusé au client", () => {
  // Il a déjà payé le transporteur sur place : encaisser serait payer deux fois.
  assert.match(SQL39, /''error'', ''reglement_especes''/);
  assert.match(FONCTION, /reglement_especes: "Cette course se règle en espèces/);
});

test("espèces : la dette de commission démarre à la livraison", () => {
  const trigger = SQL39.slice(SQL39.indexOf("trg_commission_especes_due"));
  assert.match(trigger, /new\.type::text <> 'plateau'/);
  assert.match(trigger, /commission_due_since = coalesce\(commission_due_since, now\(\)\)/);
});

test("une seule relance, et jamais après encaissement", () => {
  const relance = SQL39.slice(SQL39.indexOf("function public.secoto_commission_relances"));
  assert.match(relance, /m\.commission_reminder_sent_at is null/);
  assert.match(relance, /commission_settled_offline, false\) = false/);
  assert.match(relance, /m\.commission_paid_at is null/);
  assert.match(relance, /set commission_reminder_sent_at = now\(\)/);
  // L'administrateur reçoit un récapitulatif, pas une notification par course.
  assert.equal((relance.match(/notify_admins_event/g) || []).length, 1);
});

test("la maintenance déclenche les relances à chaque passage", () => {
  assert.match(MAINTENANCE, /rpc\("secoto_commission_relances"\)/);
});

test("carte : la course réglée à SECOTO débloque le versement du transporteur", () => {
  const payout = SQL39.slice(SQL39.indexOf("function secoto_private.trg_manual_mission_payout"));
  assert.match(payout, /purpose = 'devis_course' and p\.status = 'paid'/);
  assert.match(payout, /and not v_regle_par_carte/);
  // Les espèces restent exclues du versement automatique.
  assert.match(payout, /in \('especes', 'espèces', 'cash'\) then return new/);
});

// ---------------------------------------------------------------------------
// Migration 040 — tout se fait depuis « Devis à établir ».
// ---------------------------------------------------------------------------
const SQL40 = readFileSync(new URL("../supabase/migrations/202609230040_devis_a_la_demande_payable.sql", import.meta.url), "utf8");
const { pageRenonciation } = await import("../netlify/functions/devis-pay.js");

test("un lien porte une mission OU un devis, jamais les deux", () => {
  assert.match(SQL40, /check \(num_nonnulls\(mission_id, quote_id\) = 1\)/);
  assert.match(SQL40, /devis_payment_links_actif_quote_idx/);
});

test("payer vaut réserver : la commande et le paiement sont créés", () => {
  const book = SQL40.slice(SQL40.indexOf("function secoto_private.od_book_for_link"));
  assert.match(book, /insert into public\.transport_orders/);
  assert.match(book, /update public\.transport_quotes set status = 'accepted'/);
  assert.match(book, /'od_plateau' else 'od_convoyage'/);
  // Une commande déjà réservée ne crée pas de doublon.
  assert.match(book, /select \* into v_order from public\.transport_orders o where o\.quote_id = p_quote/);
});

test("le devis doit être tarifé et la date encore à venir", () => {
  const book = SQL40.slice(SQL40.indexOf("function secoto_private.od_book_for_link"));
  assert.match(book, /status not in \('priced', 'manual_priced', 'accepted'\)/);
  assert.match(book, /v_quote\.pickup_at <= now\(\) then raise exception 'QUOTE_DATE_DEPASSEE'/);
});

test("le particulier renonce à la rétractation avant de payer", () => {
  assert.match(SQL40, /function public\.secoto_devis_link_waiver/);
  assert.match(SQL40, /waiver_accepted    = true/);
  // La case n'est jamais pré-cochée et le refus ne déclenche rien.
  const page = pageRenonciation("abc123", 42000, "Sénas → Loguivy");
  assert.match(page, /type="checkbox" name="consent" value="oui" required/);
  assert.doesNotMatch(page, /checked/);
  assert.match(page, /420,00 €/);
  assert.match(SQL40, /not coalesce\(p_accepted, false\) then return jsonb_build_object\('error', 'consentement_refuse'\)/);
});

test("le paiement n'est proposé qu'après le consentement", () => {
  const ordre = FONCTION.indexOf("data.waiver_required") < FONCTION.indexOf("checkout.sessions.create");
  assert.ok(ordre, "la page de renonciation doit précéder la session Stripe");
  assert.match(FONCTION, /secoto_devis_link_waiver", \{ p_token: token, p_accepted: true \}/);
});
