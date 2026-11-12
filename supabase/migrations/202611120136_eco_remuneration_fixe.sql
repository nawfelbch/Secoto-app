-- ============================================================================
-- SECOTO — MIGRATION 136 : RÉMUNÉRATION ÉCO FIXE
-- ----------------------------------------------------------------------------
-- Demande de Nawfal du 12/11/2026 : en Éco, le transporteur (porte-voitures
-- poids lourd uniquement, déjà filtré par offre_partenaire_ok) est payé un
-- montant fixe de référence : 400 € en France, 640 € France ↔ étranger.
-- Jamais plus de 640 € automatiquement ; au-delà, c'est SECOTO qui fixe la
-- rémunération en attribuant lui-même la course. Marge SECOTO ≥ 75 €.
-- Déjà appliqué en production le 12/11/2026. Rejouable.
-- ============================================================================

update public.app_settings
   set value = jsonb_set(jsonb_set(value, '{eco,transporteur_france_eur}', '400'), '{eco,transporteur_international_eur}', '640')
 where key = 'bareme_v3';

select secoto_private.mig074_patch(
  'secoto_private.offre_eco_v3(public.transport_quotes,integer)'::regprocedure,
  '  -- Éco n''a de sens que moins chère que Standard.',
  '  -- 136 : rémunération Éco fixe (porte-voitures PL), jamais plus de 640 € ; marge ≥ 75 €.
  v_pay := least(v_client - round(coalesce((b ->> ''marge_min_eur'')::numeric, 75) * 100)::int,
                 round(coalesce((e ->> case when v_intl then ''transporteur_international_eur'' else ''transporteur_france_eur'' end)::numeric,
                                case when v_intl then 640 else 400 end) * 100)::int);
  -- Éco n''a de sens que moins chère que Standard.');

notify pgrst, 'reload schema';
