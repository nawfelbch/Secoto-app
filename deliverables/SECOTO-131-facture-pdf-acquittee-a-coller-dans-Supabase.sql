-- ============================================================================
-- SECOTO — MIGRATION 131 : FACTURE ACQUITTÉE EN PDF POUR CHAQUE CLIENT
-- ----------------------------------------------------------------------------
-- Demande de Nawfal du 09/11/2026 : chaque client qui a payé reçoit
-- automatiquement la facture acquittée en PDF, sur le modèle de celle envoyée
-- à M. Caujolle (FAC-202610-0001) :
--   · paiement en ligne (carte, Klarna…) : facture + page 2 « justificatif de
--     paiement » tirée de Stripe, avec le lien du reçu officiel ;
--   · espèces et virement : facture seule, avec la date du règlement.
-- Le PDF est produit par la fonction send-transactional-email au moment de
-- l'envoi de l'e-mail « od-invoice:<commande> » déjà mis en file par
-- od_issue_invoice (carte, Klarna, virement).
-- Seul ajout côté base : le règlement en espèces confirmé par le transporteur
-- émet désormais lui aussi la facture. ADDITIF, rejouable.
-- ============================================================================

select secoto_private.mig074_patch(
  'public.secoto_reglement_especes(uuid,boolean)'::regprocedure,
  '    perform secoto_private.audit(''especes_recu'', ''transport_order'', v_order.id::text, jsonb_build_object(''marge_cents'', v_marge));',
  '    perform secoto_private.audit(''especes_recu'', ''transport_order'', v_order.id::text, jsonb_build_object(''marge_cents'', v_marge));
    perform secoto_private.od_issue_invoice(v_order.id); -- 131 : facture acquittée (espèces)');

notify pgrst, 'reload schema';
