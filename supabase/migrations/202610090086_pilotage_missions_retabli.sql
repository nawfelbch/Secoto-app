-- ============================================================================
-- SECOTO 086 — Pilotage des missions rétabli (décision de Nawfal, 08/10/2026)
-- ----------------------------------------------------------------------------
-- Le pilotage d'une mission (étapes, réouverture d'un état des lieux, tarif,
-- attribution, lien de paiement, SMS) reste indispensable pour régler un
-- incident terrain avec un client réel. Le verrou de 084 sur les MISSIONS est
-- donc levé : SECOTO garde la main sur toutes les missions.
--
-- Inchangé (084) : sur une COMMANDE acceptée dans l'application, SECOTO ne
-- modifie plus le prix ni la rémunération, ne remplace plus le transporteur et
-- n'annule qu'avec remboursement intégral.
-- Migration rejouable.
-- ============================================================================
create or replace function secoto_private.mission_course_verrouillee(m public.missions)
returns boolean language sql stable security definer set search_path = '' as $$
  select false;
$$;
revoke all on function secoto_private.mission_course_verrouillee(public.missions) from public, anon, authenticated;

notify pgrst, 'reload schema';
