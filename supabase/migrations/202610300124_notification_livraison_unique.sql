-- ============================================================================
-- SECOTO — MIGRATION 124 : UNE SEULE NOTIFICATION « MISSION LIVRÉE »
-- ----------------------------------------------------------------------------
-- Constat du 30/10/2026 (MIS-2026-5D21F9DC, Gouvieux → Maintenon) : à chaque
-- livraison, l'administrateur et le client recevaient deux « Mission livree »
-- à la même seconde (même chose les 23, 24 et 28/10).
--
-- Cause : la validation de l'état des lieux d'arrivée
-- (secoto_finalize_tracking_event) envoie « Mission livree », et le
-- déclencheur trg_secoto_mission_delivered (missions) en envoie un second au
-- passage en « livrée ». Les deux portaient une clé différente, donc aucun
-- dédoublonnage. Même doublon côté client quand l'administrateur clôture la
-- mission (secoto_transition_mission).
--
-- Correctif : ces envois reprennent la clé du déclencheur. La notification
-- n'est créée qu'une fois (« on conflict (event_key) do nothing »). Les
-- « Mise a jour de la mission » (étapes terrain) ne changent pas.
-- ADDITIF, rejouable.
-- ============================================================================

-- 1. État des lieux d'arrivée : administrateurs.
select secoto_private.mig074_patch('public.secoto_finalize_tracking_event(uuid,text,jsonb,jsonb,uuid)'::regprocedure,
  '''tracking:'' || v_event.id::text',
  'case when p_event_type = ''delivery_inspection'' then ''delivered:'' || p_mission_id::text || '':admin'' else ''tracking:'' || v_event.id::text end /* 124 */');

-- 2. État des lieux d'arrivée : client.
select secoto_private.mig074_patch('public.secoto_finalize_tracking_event(uuid,text,jsonb,jsonb,uuid)'::regprocedure,
  '''tracking-client:'' || v_event.id::text',
  'case when p_event_type = ''delivery_inspection'' then ''delivered:'' || p_mission_id::text || '':client'' else ''tracking-client:'' || v_event.id::text end /* 124 */');

-- 3. Clôture par l'administrateur : client.
select secoto_private.mig074_patch('public.secoto_transition_mission(uuid,text,uuid)'::regprocedure,
  '''mission-completed:client:'' || p_mission_id::text',
  '''delivered:'' || p_mission_id::text || '':client'' /* 124 */');

notify pgrst, 'reload schema';
