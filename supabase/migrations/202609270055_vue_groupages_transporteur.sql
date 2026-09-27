-- ============================================================================
-- SECOTO — 055 : REMETTRE LA VUE DES GROUPAGES DANS LE DEPOT
-- ----------------------------------------------------------------------------
-- public.secoto_groupages_transporteur_v1 tournait en production sans exister
-- dans aucune migration : elle avait ete creee a la main dans l'editeur SQL.
-- Une base reconstruite depuis le depot perdait les groupages sans aucun
-- message d'erreur.
--
-- La definition ci-dessous est celle relevee en production le 27/09/2026,
-- reprise a l'identique. Cette migration ne change donc rien au comportement
-- observable : elle rend seulement la vue reproductible.
--
-- Qui voit quoi :
--   - la direction voit tous les groupages suggeres ;
--   - un transporteur verifie ne voit un groupage que s'il est eligible aux
--     DEUX missions qui le composent ;
--   - personne d'autre ne voit rien, et anon n'a aucun droit.
-- ============================================================================

create or replace view public.secoto_groupages_transporteur_v1
with (security_barrier = true, security_invoker = false)
as
select
  g.id,
  g.mission_a_id,
  g.mission_b_id,
  g.detour_pct,
  g.capacity_total,
  g.window_start,
  g.window_end,
  g.kind,
  g.score,
  g.created_at,
  ma.public_ref as mission_a_ref,
  ma.from_city  as a_from,
  ma.to_city    as a_to,
  mb.public_ref as mission_b_ref,
  mb.from_city  as b_from,
  mb.to_city    as b_to
from public.groupages_suggeres g
join public.missions ma on ma.id = g.mission_a_id
join public.missions mb on mb.id = g.mission_b_id
where ma.status = 'published'::text
  and mb.status = 'published'::text
  and (
    secoto_private.is_admin(auth.uid())
    or (
      secoto_private.is_verified_transporter(auth.uid())
      and secoto_private.transporter_matches_mission(auth.uid(), ma.id)
      and secoto_private.transporter_matches_mission(auth.uid(), mb.id)
    )
  );

revoke all on table public.secoto_groupages_transporteur_v1 from public, anon;
grant select on table public.secoto_groupages_transporteur_v1 to authenticated;

comment on view public.secoto_groupages_transporteur_v1 is
  'Groupages suggeres. Direction : tout. Transporteur verifie : uniquement les '
  'groupages dont il satisfait les deux missions. Vue SECURITY DEFINER : le '
  'filtre est porte par la vue elle-meme, jamais par l''appelant.';

-- Controle bloquant : la vue existe et reste fermee a anon --------------------
do $controle$
begin
  if to_regclass('public.secoto_groupages_transporteur_v1') is null then
    raise exception 'La vue des groupages n''a pas ete creee';
  end if;

  if has_table_privilege('anon', 'public.secoto_groupages_transporteur_v1', 'SELECT') then
    raise exception 'La vue des groupages est lisible par anon';
  end if;

  if not has_table_privilege('authenticated', 'public.secoto_groupages_transporteur_v1', 'SELECT') then
    raise exception 'La vue des groupages n''est plus lisible par authenticated';
  end if;

  raise notice 'OK : vue des groupages en place, fermee a anon';
end
$controle$;
