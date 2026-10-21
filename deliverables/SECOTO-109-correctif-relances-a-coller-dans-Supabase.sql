-- ============================================================================
-- SECOTO — MIGRATION 109 : CORRECTIF DES RELANCES DE DEVIS (106)
-- ----------------------------------------------------------------------------
-- En production, secoto_devis_relances échouait à CHAQUE passage (erreur
-- « invalid input syntax for type integer ») : PostgreSQL ne garantit pas
-- l'ordre des conditions, et convertissait en nombre le 3e morceau de clés
-- e-mail d'un autre format (« …:uuid:uuid »). Résultat : aucune relance n'est
-- jamais partie. On compare désormais des clés exactes, sans conversion.
-- Rejouable. Ne touche à rien d'autre.
-- ============================================================================
select secoto_private.mig074_patch('public.secoto_devis_relances(integer)'::regprocedure,
  'and split_part(e.event_key, '':'', 3)::int >= v_etape)',
  'and e.event_key in (select ''relance-devis:'' || r.id::text || '':'' || s from generate_series(v_etape, 9) s) /* 109 */)');

notify pgrst, 'reload schema';
