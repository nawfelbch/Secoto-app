-- ============================================================================
-- SECOTO — RÉPARATION IMMÉDIATE des candidatures transporteur.
-- ----------------------------------------------------------------------------
-- À coller EN ENTIER dans Supabase → SQL Editor → Run.
-- Ne modifie aucune donnée. Rejouable sans risque.
-- Contrairement au script précédent, RIEN ici ne peut annuler la réparation :
-- l'audit final est un simple rapport, jamais une erreur bloquante.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. ÉTAT AVANT — ce que PostgREST voit aujourd'hui
-- ----------------------------------------------------------------------------
select 'AVANT' as moment, p.oid::regprocedure::text as signature
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' and p.proname = 'secoto_apply_to_mission';

-- ----------------------------------------------------------------------------
-- 2. RÉPARATION — ne conserver qu'UNE version de secoto_apply_to_mission
--    (la plus complète et la plus récente : celle de la migration 013)
-- ----------------------------------------------------------------------------
do $repair$
declare
  v_keep oid;
  v_drop record;
  v_signature text;
begin
  select p.oid into v_keep
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname = 'secoto_apply_to_mission'
  order by p.pronargs desc, p.oid desc
  limit 1;

  if v_keep is null then
    raise exception
      'secoto_apply_to_mission est absente de la base : appliquez d''abord la migration 013.';
  end if;

  for v_drop in
    select p.oid::regprocedure::text as signature
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname = 'secoto_apply_to_mission'
      and p.oid <> v_keep
  loop
    execute format('drop function %s', v_drop.signature);
    raise notice 'Surcharge en trop supprimée : %', v_drop.signature;
  end loop;

  select p.oid::regprocedure::text into v_signature
  from pg_proc p where p.oid = v_keep;

  execute format('revoke all on function %s from public, anon', v_signature);
  execute format('grant execute on function %s to authenticated', v_signature);
  raise notice 'Signature conservée : %', v_signature;

  if not (select p.prosecdef from pg_proc p where p.oid = v_keep) then
    raise warning
      'La version conservée n''est PAS security definer : rejouez la migration 015 pour restaurer le corps canonique.';
  end if;
end
$repair$;

-- ----------------------------------------------------------------------------
-- 3. Rechargement du cache de schéma PostgREST
-- ----------------------------------------------------------------------------
notify pgrst, 'reload schema';

-- ----------------------------------------------------------------------------
-- 4. ÉTAT APRÈS — une seule ligne doit apparaître, security definer = true
-- ----------------------------------------------------------------------------
select 'APRES' as moment,
       p.oid::regprocedure::text as signature,
       p.prosecdef              as security_definer,
       has_function_privilege('authenticated', p.oid, 'execute') as authenticated_peut_executer
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' and p.proname = 'secoto_apply_to_mission';

-- ----------------------------------------------------------------------------
-- 5. AUDIT — toute AUTRE fonction réellement ambiguë pour PostgREST,
--    c'est-à-dire présente plusieurs fois avec les MÊMES noms de paramètres.
--    Zéro ligne = plus aucune candidature ni action ne peut échouer ainsi.
--    (Des surcharges aux paramètres DIFFÉRENTS sont normales et sans danger.)
-- ----------------------------------------------------------------------------
select s.proname                       as fonction,
       count(*)                        as exemplaires,
       string_agg(s.signature, '  |  ') as signatures
from (
  select p.proname,
         (select array_agg(x order by x)
            from unnest(coalesce(p.proargnames, '{}'::text[])) x) as argnames,
         p.oid::regprocedure::text as signature
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname like 'secoto\_%'
) s
group by s.proname, s.argnames
having count(*) > 1;
