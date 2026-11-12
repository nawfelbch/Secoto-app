-- ============================================================================
-- SECOTO — MIGRATION 140 : E-MAIL D'ANNULATION CLAIR QUAND RIEN N'EST PRÉLEVÉ
-- ----------------------------------------------------------------------------
-- Demandé par Nawfal le 12/11/2026. L'e-mail « Commande annulée » disait
-- toujours « Le détail (montant éventuellement retenu ou remboursé) est
-- disponible dans votre espace » : inquiétant pour un client qui n'a rien payé
-- (paiement à l'arrivée, espèces). Désormais :
--   · rien débité (ni capture ni paiement) : « Aucun montant n'a été prélevé
--     sur votre carte : il n'y a rien à rembourser. »
--     (paiement en cours de traitement : phrase actuelle, par prudence)
--   · sinon : phrase actuelle (frais retenus ou remboursement).
-- ADDITIF, rejouable (mig074_patch ignore un patch déjà appliqué).
-- ============================================================================

select secoto_private.mig074_patch(
  'secoto_private.email_client_etape(public.transport_orders,text)'::regprocedure,
  '      ''Le détail (montant éventuellement retenu ou remboursé) est disponible dans votre espace SECOTO.'',',
  '      case when v_payment.id is not null and v_payment.captured_at is null and v_payment.paid_at is null  -- 140
                and coalesce(v_payment.status, '''') not in (''paid'', ''processing'', ''captured'', ''succeeded'', ''refunded'', ''partially_refunded'')
        then ''Aucun montant n''''a été prélevé sur votre carte : il n''''y a rien à rembourser.''
        else ''Le détail (montant éventuellement retenu ou remboursé) est disponible dans votre espace SECOTO.'' end,');
