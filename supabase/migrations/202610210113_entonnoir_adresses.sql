-- ============================================================================
-- SECOTO — MIGRATION 113 : ENTONNOIR — SAISIE ET CHOIX D'ADRESSE
-- ----------------------------------------------------------------------------
-- Le 21/10, 13 visiteurs Google Ads sur 20 n'ont pas validé le premier écran.
-- Deux étapes de plus pour savoir s'ils partent sans rien taper (page fermée)
-- ou s'ils bloquent sur les adresses : « adresse_saisie » (1re lettre tapée)
-- et « adresse_choisie » (une adresse prise dans la liste). Toujours anonyme.
-- Rejouable.
-- ============================================================================
select secoto_private.mig074_patch('public.secoto_etape_formulaire(uuid,text,text,boolean,boolean)'::regprocedure,
  '''arrivee'', ''trajet'',',
  '''arrivee'', ''adresse_saisie'', ''adresse_choisie'', ''trajet'',');

notify pgrst, 'reload schema';
