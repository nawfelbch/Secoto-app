-- ============================================================================
-- SECOTO — MIGRATION 134 : OFFRE ÉCO RÉÉVALUÉE
-- ----------------------------------------------------------------------------
-- Demande de Nawfal du 12/11/2026 : une berline Paris → Nice en Éco doit
-- coûter 650 €, pas 481,50 €.
--   · Éco : 0,61 € par km entre les deux grandes villes (au lieu de 0,45 €) ;
--   · plafond Éco berline : 650 € (au lieu de 600 €) ;
--   · plafond atteint : le prix client s'arrête au plafond, mais la
--     rémunération du transporteur n'est plus remontée (marge ≥ 75 €).
-- Déjà appliqué en production le 12/11/2026. Rejouable.
-- ============================================================================

update public.app_settings
   set value = jsonb_set(jsonb_set(value, '{eco,eur_km}', '0.61'), '{gabarits,berline,eco_plafond_eur}', '650')
 where key = 'bareme_v3';

select secoto_private.mig074_patch(
  'secoto_private.offre_eco_v3(public.transport_quotes,integer)'::regprocedure,
  '    v_pay := v_cap - v_min_marge;',
  '    v_pay := least(v_pay, v_cap - v_min_marge);');

notify pgrst, 'reload schema';
