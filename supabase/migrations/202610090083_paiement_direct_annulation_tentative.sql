-- ============================================================================
-- SECOTO 083 — Paiement direct : une tentative de débit annulée n'annule pas
-- la commande
-- ----------------------------------------------------------------------------
-- En paiement direct, la ligne de paiement représente la carte validée du
-- client ; chaque débit chez le transporteur est une TENTATIVE (un
-- PaymentIntent sur son compte). Quand la banque exige une validation, le
-- serveur annule la tentative hors session et le client paie lui-même depuis
-- l'app. Stripe signale alors « payment_intent.canceled » : ce signal annulait
-- à tort toute la commande (vu en test le 08/10 : commande « Annulée »,
-- transporteur privé de sa mission).
--
-- Désormais, en paiement direct, l'annulation d'une tentative est seulement
-- tracée ; la commande ne s'annule que par les fonctions d'annulation SECOTO
-- (client, administrateur, maintenance). Ancien circuit inchangé.
-- Migration rejouable.
-- ============================================================================
select secoto_private.mig074_patch(
  'public.secoto_od_apply_payment_event(uuid, text, text, text, integer, timestamptz, text)'::regprocedure,
  '      if v_payment.status in (''pending'', ''processing'', ''requires_capture'', ''capture_failed'', ''failed'') then v_new := ''cancelled''; end if;',
  '      -- 083 : paiement direct -> une tentative annulée ne touche ni la carte ni la commande.
      if v_payment.status in (''pending'', ''processing'', ''requires_capture'', ''capture_failed'', ''failed'')
         and v_payment.payment_circuit is distinct from ''direct'' then v_new := ''cancelled''; end if;');

notify pgrst, 'reload schema';
