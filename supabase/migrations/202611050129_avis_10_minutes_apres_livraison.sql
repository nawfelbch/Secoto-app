-- ============================================================================
-- SECOTO — MIGRATION 129 : DEMANDE D'AVIS 10 MINUTES APRÈS LA LIVRAISON
-- ----------------------------------------------------------------------------
-- Décision de Nawfal du 05/11/2026 : l'e-mail « Votre véhicule est bien arrivé
-- — votre avis sur SECOTO » (lien Google) partait le lendemain à 10 h. Il part
-- désormais 10 minutes après la livraison, quand le client vient de récupérer
-- son véhicule. Les exclusions ne changent pas (incident, annulation,
-- remboursement). Les demandes déjà programmées pour demain sont avancées.
-- ADDITIF, rejouable.
-- ============================================================================

select secoto_private.mig074_patch('secoto_private.trg_mission_review_request()'::regprocedure,
  '(((now() at time zone ''Europe/Paris'')::date + 1) + make_time(v_heure, 0, 0)) at time zone ''Europe/Paris'')',
  'now() + interval ''10 minutes'' /* 129 */)');

update public.review_requests
   set due_at = least(due_at, created_at + interval '10 minutes')
 where status = 'pending';

notify pgrst, 'reload schema';
