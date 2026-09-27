-- ============================================================================
-- SECOTO — 054 : FERMER L'ACCES ANONYME AUX VUES METIER
-- ----------------------------------------------------------------------------
-- Les vues secoto_* sont volontairement en SECURITY DEFINER : chacune porte
-- son propre filtre (auth.uid(), secoto_is_admin(),
-- secoto_current_transporter_matches_mission()) et un security_barrier. C'est
-- ce que l'Advisor Supabase signale ; ce n'est pas un defaut.
--
-- Le vrai defaut etait ailleurs : Supabase accorde par defaut un SELECT au role
-- anon sur toute nouvelle table ou vue du schema public. Six vues etaient donc
-- interrogeables par un visiteur non connecte. Aucune ligne ne sortait — un
-- anonyme a auth.uid() a null et secoto_is_admin() a false — mais toute la
-- securite reposait alors sur le seul WHERE de la vue, sans seconde barriere.
--
-- Cette migration retire ce droit, supprime le droit par defaut pour les vues
-- futures, et pose un controle bloquant.
--
-- Elle ne change AUCUN droit du role authenticated : les ecrans client,
-- transporteur et direction fonctionnent a l'identique.
-- ============================================================================

-- 1. Retirer le SELECT accorde par defaut a anon ------------------------------
do $revoke_anon$
declare
  v_view text;
begin
  foreach v_view in array array[
    'secoto_groupages_transporteur_v1',
    'secoto_missions_admin_v2',
    'secoto_missions_client_v2',
    'secoto_missions_transporter_v2',
    'secoto_public_missions_v2',
    'secoto_revenue_ytd_v1',
    'secoto_admin_alertes_v1',
    'secoto_mission_manual_v1'
  ] loop
    if to_regclass('public.' || v_view) is not null then
      execute format('revoke all on table public.%I from anon', v_view);
    end if;
  end loop;
end
$revoke_anon$;

-- 2. Les vues creees plus tard ne repartent plus ouvertes a anon --------------
alter default privileges in schema public revoke all on tables from anon;

-- 3. Controle bloquant --------------------------------------------------------
do $controle$
declare
  v_restant text;
begin
  select string_agg(c.relname, ', ' order by c.relname)
    into v_restant
  from pg_class c
  join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'public'
    and c.relkind = 'v'
    and has_table_privilege('anon', c.oid, 'SELECT');

  if v_restant is not null then
    raise exception 'Vues encore lisibles par anon : %', v_restant;
  end if;

  raise notice 'OK : aucune vue du schema public n''est lisible par anon';
end
$controle$;
