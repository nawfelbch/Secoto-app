-- ============================================================================
-- SECOTO — MIGRATION 091 : « BATTERIE FAIBLE » NE BLOQUE PLUS LE PRIX
-- ----------------------------------------------------------------------------
-- Décision de Nawfal du 14/10/2026 : un client qui coche « Batterie faible »
-- sur un véhicule non roulant doit avoir son prix tout de suite (plateau,
-- supplément non roulant de 80 € compris), pas un devis manuel.
--
--   - Le texte libre « Précisions » n'a jamais déclenché de devis manuel :
--     inchangé.
--   - Les contraintes listées dans le barème (clé « contraintes_sans_devis »)
--     sont tarifées automatiquement. Sans cette clé : « batterie_faible ».
--   - Les autres contraintes (clé indisponible, garde au sol basse, gabarit hors
--     norme, non immatriculé, accès difficile) restent en devis manuel.
--
-- ADDITIF : une fonction nouvelle, la fonction de prix complétée par
-- remplacement de repère (une seule condition). Aucun prix déjà émis n'est
-- recalculé. Aucune policy touchée. Rejouable.
-- ============================================================================

create or replace function secoto_private.contraintes_sans_devis(p jsonb)
returns text[] language sql immutable set search_path = ''
as $f$
  select case
    when jsonb_typeof(p -> 'contraintes_sans_devis') = 'array'
      then array(select jsonb_array_elements_text(p -> 'contraintes_sans_devis'))
    else array['batterie_faible']
  end;
$f$;
revoke all on function secoto_private.contraintes_sans_devis(jsonb) from public, anon, authenticated;

-- Devis manuel seulement si au moins une contrainte n'est PAS dans la liste.
select secoto_private.mig074_patch(
  'secoto_private.price_with_grid(text,jsonb,numeric,jsonb,numeric)'::regprocedure,
  'jsonb_array_length(p_vehicle -> ''constraints'') > 0',
  'exists (select 1 from jsonb_array_elements_text(p_vehicle -> ''constraints'') as c(v) where c.v <> all (secoto_private.contraintes_sans_devis(p)))');
