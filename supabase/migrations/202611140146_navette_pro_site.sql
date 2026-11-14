-- ============================================================================
-- SECOTO — MIGRATION 146 : NAVETTE PRO SUR LE SITE VITRINE
-- ----------------------------------------------------------------------------
-- À coller APRÈS la 145. Le site vitrine lit ses prix dans l'app au moment de
-- sa construction (RPC secoto_bareme_v3_public) : la page « Professionnels »
-- et son simulateur affichent donc les vrais prix Navette Pro, jamais des
-- chiffres recopiés à la main. Seuls les PRIX CLIENT sont publiés (1 voiture,
-- par voiture à partir de 2, 4x4) ; la rémunération transporteur n'y figure pas.
-- Tout changement des réglages navette_pro recalcule la table du site.
-- ADDITIF, rejouable.
-- ============================================================================

select secoto_private.mig074_patch(
  'secoto_private.bareme_v3_public_calcul()'::regprocedure,
  $a$'lourds', jsonb_build_object('gabarits', b -> 'lourds' -> 'gabarits',  -- 144$a$,
  $b$'navette_pro', (select jsonb_build_object(  -- 146 : prix client Navette Pro (comptes pros)
        'actif', coalesce((n ->> 'actif')::boolean, false),
        'libelle', coalesce(n ->> 'libelle', 'Navette Pro'),
        'fenetre_h', coalesce((n ->> 'fenetre_h')::int, 168),
        'gabarits', n -> 'gabarits',
        'axes', coalesce((select jsonb_agg(jsonb_build_object(
            'nom', a ->> 'nom', 'type', a ->> 'type',
            'departements', a -> 'departements', 'pays', a -> 'pays',
            'km_min', (a ->> 'km_min')::numeric, 'km_max', (a ->> 'km_max')::numeric,
            'voiture_1', round((a ->> 'transporteur_eur')::numeric + (n ->> 'marge_1_vehicule_eur')::numeric),
            'voiture_par_vehicule_2_plus', round((a ->> 'transporteur_eur')::numeric + (n ->> 'marge_par_vehicule_2_plus_eur')::numeric),
            'grand_1', round((a ->> 'transporteur_eur')::numeric * pg + (n ->> 'marge_1_vehicule_eur')::numeric),
            'grand_par_vehicule_2_plus', round((a ->> 'transporteur_eur')::numeric * pg + (n ->> 'marge_par_vehicule_2_plus_eur')::numeric)))
          from jsonb_array_elements(coalesce(n -> 'axes', '[]'::jsonb)) a), '[]'::jsonb))
      from (select secoto_private.navette_pro_reglages() as n,
                   coalesce((b -> 'eco' -> 'places' ->> 'grand')::numeric, 1.5) as pg) x),
    'lourds', jsonb_build_object('gabarits', b -> 'lourds' -> 'gabarits',  -- 144$b$);

-- Réglages navette_pro modifiés : table du site recalculée.
drop trigger if exists bareme_v3_public_cache on public.app_settings;
create trigger bareme_v3_public_cache after insert or update of value on public.app_settings
  for each row when (new.key = any (array['bareme_v3', 'trois_offres', 'navette_pro']))
  execute function secoto_private.bareme_v3_public_trigger();

select secoto_private.bareme_v3_public_rafraichir() is not null as site_recalcule;

notify pgrst, 'reload schema';
