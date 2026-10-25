-- SECOTO 118 — à coller dans Supabase → SQL Editor, puis Run. Tout ou rien (begin/commit).
begin;
-- ============================================================================
-- SECOTO — MIGRATION 118 : LE PAIEMENT RÉUSSI DEVIENT LA RÉFÉRENCE
-- ----------------------------------------------------------------------------
-- Incident du 25/10/2026 (CMD-2026-DC0B44F6) : deux prélèvements à la
-- livraison refusés (solde insuffisant), puis le client a payé lui-même
-- (« Payer maintenant »). Le paiement gardait l'identifiant Stripe du
-- PREMIER essai, refusé : le virement au transporteur a échoué (« Cannot use
-- a failed charge as a source_transaction »). Corrigé à la main le soir même.
-- Désormais, quand Stripe confirme un paiement réussi, son identifiant
-- remplace celui d'un essai précédent. Les autres événements ne changent pas.
-- ADDITIF, rejouable.
-- ============================================================================

select secoto_private.mig074_patch(
  'public.secoto_od_apply_payment_event(uuid,text,text,text,integer,timestamptz,text)'::regprocedure,
  'provider_intent_id = coalesce(provider_intent_id, p_intent_id),',
  'provider_intent_id = case when v_new = ''paid'' and p_intent_id is not null then p_intent_id else coalesce(provider_intent_id, p_intent_id) end,  -- 118');

notify pgrst, 'reload schema';
commit;
