-- ============================================================================
-- SECOTO - Patch : completer la table mission_requests.
-- Corrige "Could not find the '...' column of 'mission_requests'".
-- Ajoute (si absentes) toutes les colonnes que le formulaire de demande ecrit,
-- puis recharge le cache de schema PostgREST. Idempotent, rejouable.
-- A coller dans le SQL Editor Supabase.
-- ============================================================================

alter table public.mission_requests add column if not exists public_ref        text;
alter table public.mission_requests add column if not exists type              text;
alter table public.mission_requests add column if not exists status            text default 'pending';
alter table public.mission_requests add column if not exists from_city         text;
alter table public.mission_requests add column if not exists to_city           text;
alter table public.mission_requests add column if not exists pickup_address    text;
alter table public.mission_requests add column if not exists delivery_address  text;
alter table public.mission_requests add column if not exists mission_date      timestamptz;
alter table public.mission_requests add column if not exists vehicle           text;
alter table public.mission_requests add column if not exists plate             text;
alter table public.mission_requests add column if not exists distance_km       numeric(10,2);
alter table public.mission_requests add column if not exists client_name       text;
alter table public.mission_requests add column if not exists client_contact    text;
alter table public.mission_requests add column if not exists client_phone      text;
alter table public.mission_requests add column if not exists price_mode        text default 'fixed';
alter table public.mission_requests add column if not exists proposed_price    numeric(12,2);
alter table public.mission_requests add column if not exists notes             text;
alter table public.mission_requests add column if not exists created_by_role   text;
alter table public.mission_requests add column if not exists requester_name    text;
alter table public.mission_requests add column if not exists requester_company text;
alter table public.mission_requests add column if not exists approved_mission_id uuid;

-- Recharger le cache de schema pour que l'API voie tout de suite les colonnes.
notify pgrst, 'reload schema';
