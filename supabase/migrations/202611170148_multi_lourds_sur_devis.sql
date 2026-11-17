-- ============================================================================
-- SECOTO — MIGRATION 148 : RUSTINE — PLUSIEURS VÉHICULES LOURDS = DEVIS MANUEL
-- ----------------------------------------------------------------------------
-- Demandé par Nawfal le 17/11/2026. Les devis à PLUSIEURS véhicules passent
-- encore par l'ancien moteur (secoto-pricing-2 : 1,25 €/km utilitaire, −25 %
-- dès le 2e véhicule) : 3 utilitaires sur 447 km affichaient 1 636 € au client
-- et 1 409 € au transporteur, impossible à placer.
-- En attendant la nouvelle grille (149), toute demande à plusieurs véhicules
-- comprenant un utilitaire, une caravane ou un camping-car passe en
-- « Devis à établir » : aucun prix automatique, SECOTO fixe le prix.
-- Un seul véhicule et les demandes de voitures/motos : inchangés.
-- ADDITIF, rejouable. Aucun devis ni commande existants modifiés.
-- ============================================================================

select secoto_private.mig074_patch(
  'public.secoto_quote_create(uuid,jsonb,jsonb)'::regprocedure,
  $a$  v_validity := least($a$,
  $b$  -- 148 : plusieurs véhicules dont un utilitaire, une caravane ou un camping-car -> devis manuel.
  if v_reason is null and v_mode = 'plateau' and jsonb_array_length(v_vehicles) > 1
     and exists (select 1 from jsonb_array_elements(v_vehicles) x
                  where secoto_private.est_lourd(secoto_private.gabarit_vehicule(x.value))) then
    v_reason := 'sur_devis_plusieurs_lourds';
  end if;
  v_validity := least($b$);

notify pgrst, 'reload schema';
