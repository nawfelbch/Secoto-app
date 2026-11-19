-- ============================================================================
-- SECOTO 156 — Le Black Friday commence tout de suite (décision de Nawfal, 19/11/2026)
-- ----------------------------------------------------------------------------
-- La remise de la 153 démarrait le 27/11. Elle démarre maintenant :
--   · 19/11 → 30/11 : « Remise Black Friday » ;
--   · 01/12 → 31/12 : « Remise de Noël ».
-- Mêmes règles (jusqu'à 5 %, 40 € max., 50 € nets minimum Klarna compris, 154).
-- Nouveaux devis seulement. Rejouable.
-- ============================================================================
update public.app_settings
   set value = value || jsonb_build_object('debut', '2026-11-19')
 where key = 'promo_noel';
