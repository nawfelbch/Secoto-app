-- ============================================================================
-- SECOTO — CORRECTIF 050 : DEUX BLOCAGES SUR LE DEVIS SANS COMPTE
-- ----------------------------------------------------------------------------
-- 1. La contrainte posee par la migration 049 refusait TOUT devis anonyme.
--    Elle exige qu'une ligne sans proprietaire porte un jeton ; or le jeton est
--    pose juste apres l'insertion, et une contrainte CHECK est verifiee a
--    l'insertion meme. PostgreSQL ne sait pas differer un CHECK : la contrainte
--    est donc retiree. Le jeton reste garanti par la fonction qui cree le
--    devis, et les lignes sans proprietaire sont purgees au bout de 30 jours.
--
-- 2. Un libelle d'adresse devait faire au moins 5 caracteres. « Nice », « Lyon »
--    et « Caen » en font 4 : choisir sa ville dans la liste renvoyait
--    « Adresse invalide. ». Le minimum passe a 2. Le code postal et les
--    coordonnees restent exiges, donc l'adresse reste verifiee.
-- ============================================================================

-- 1. La contrainte qui bloquait les devis anonymes -----------------------------
alter table public.transport_quotes drop constraint if exists transport_quotes_anon_check;

comment on column public.transport_quotes.anon_token is
  'Jeton du devis etabli sans compte, pose par secoto_anon_quote_create. '
  'Efface des que le devis est rattache a un client. Les lignes sans '
  'proprietaire ni jeton sont purgees au bout de 30 jours.';

-- 2. Les villes de quatre lettres ------------------------------------------------
do $patch$
declare
  v_src text;
  v_neuf text;
  v_ancre text := 'not between 5 and 300 or length(coalesce(v_delivery ->> ''label'', '''')) not between 5 and 300';
begin
  select pg_get_functiondef(p.oid) into v_src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'secoto_quote_create';

  if v_src is null then
    raise exception 'secoto_quote_create absente : appliquez d''abord la migration 030.';
  end if;
  if position(v_ancre in v_src) = 0 then
    raise notice 'Regle de longueur deja corrigee ou introuvable : rien a faire.';
    return;
  end if;

  v_neuf := replace(v_src, v_ancre,
    'not between 2 and 300 or length(coalesce(v_delivery ->> ''label'', '''')) not between 2 and 300');
  execute v_neuf;
  raise notice 'Les libelles d''adresse de 2 caracteres sont desormais acceptes.';
end;
$patch$;

-- 3. Controle ---------------------------------------------------------------------
-- Aucune ligne sans proprietaire ne doit trainer sans jeton.
select count(*) as devis_orphelins_sans_jeton
  from public.transport_quotes
 where account_id is null and anon_token is null;

notify pgrst, 'reload schema';
