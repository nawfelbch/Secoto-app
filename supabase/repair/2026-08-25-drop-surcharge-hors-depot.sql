-- ============================================================================
-- SECOTO — suppression ciblée de la surcharge hors dépôt de
-- secoto_apply_to_mission (incident PGRST203 du 25/08/2026).
-- ----------------------------------------------------------------------------
-- Les deux signatures présentes en base ont été identifiées avec certitude
-- dans le journal console du navigateur :
--
--   CONSERVÉE — migration 013, versionnée dans le dépôt, security definer :
--     (p_mission_id, p_proposed_price, p_message, p_idempotency_key,
--      p_pickup_earliest_at, p_pickup_latest_at,
--      p_delivery_earliest_at, p_delivery_latest_at, p_proposed_price_grouped)
--
--   SUPPRIMÉE — surcharge appliquée directement en production, jamais
--   versionnée, p_idempotency_key relégué en dernière position :
--     (p_mission_id, p_proposed_price, p_message,
--      p_pickup_earliest_at, p_pickup_latest_at,
--      p_delivery_earliest_at, p_delivery_latest_at,
--      p_proposed_price_grouped, p_idempotency_key)
--
-- Aucune donnée touchée. Rejouable (drop if exists).
-- ============================================================================

drop function if exists public.secoto_apply_to_mission(
  uuid, numeric, text,
  timestamptz, timestamptz, timestamptz, timestamptz, numeric, uuid
);

notify pgrst, 'reload schema';

-- Vérification : une seule ligne, security_definer = true, execute = true.
select p.oid::regprocedure::text as signature,
       p.prosecdef              as security_definer,
       has_function_privilege('authenticated', p.oid, 'execute') as authenticated_execute
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' and p.proname = 'secoto_apply_to_mission';
