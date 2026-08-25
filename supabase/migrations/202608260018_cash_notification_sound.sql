-- ============================================================================
-- SECOTO — migration 018 : son de caisse enregistreuse sur les notifications
-- qui rapportent, réglable par le destinataire.
-- ----------------------------------------------------------------------------
-- Transactionnel, idempotent, aucune donnée existante modifiée.
--
-- ⚠ Leçon de l'incident du 25/08/2026 : `secoto_update_notification_preferences`
-- gagne un paramètre. En PostgREST, l'appel se fait par NOMS d'arguments : si
-- l'ancienne signature à 5 paramètres survivait à côté de la nouvelle à 6
-- (dont un avec DEFAULT), un appel portant les 5 anciens noms correspondrait
-- aux DEUX — et PostgREST refuserait de choisir, bloquant tout l'écran
-- Notifications. L'ancienne signature est donc explicitement supprimée, et le
-- nouveau paramètre est ajouté EN DERNIÈRE POSITION, jamais intercalé.
-- ============================================================================

begin;

-- ----------------------------------------------------------------------------
-- 1. La préférence, active par défaut
-- ----------------------------------------------------------------------------
alter table public.notification_preferences
  add column if not exists cash_sound_enabled boolean not null default true;

comment on column public.notification_preferences.cash_sound_enabled is
  'Son de caisse sur les notifications qui representent de l''argent : '
  'transporteur (nouvelle course, mission attribuee, paiement recu) et '
  'admin (paiement encaisse, nouvelle demande). Actif par defaut.';

-- ----------------------------------------------------------------------------
-- 2. Remplacement de la fonction de mise à jour, sans doublon possible
-- ----------------------------------------------------------------------------
drop function if exists public.secoto_update_notification_preferences(
  boolean, boolean, boolean, boolean, boolean
);

create or replace function public.secoto_update_notification_preferences(
  p_push_enabled boolean,
  p_email_enabled boolean,
  p_mute_missions boolean,
  p_mute_documents boolean,
  p_mute_frais boolean,
  p_cash_sound_enabled boolean default true
)
returns public.notification_preferences
language plpgsql
volatile
security definer
set search_path = ''
as $function$
declare
  v_user_id uuid := secoto_private.assert_authenticated();
  v_row public.notification_preferences%rowtype;
begin
  insert into public.notification_preferences as np (
    account_id, push_enabled, email_enabled,
    mute_missions, mute_documents, mute_frais,
    cash_sound_enabled, updated_at
  )
  values (
    v_user_id, coalesce(p_push_enabled, true), coalesce(p_email_enabled, true),
    coalesce(p_mute_missions, false), coalesce(p_mute_documents, false),
    coalesce(p_mute_frais, false), coalesce(p_cash_sound_enabled, true), now()
  )
  on conflict (account_id) do update set
    push_enabled       = excluded.push_enabled,
    email_enabled      = excluded.email_enabled,
    mute_missions      = excluded.mute_missions,
    mute_documents     = excluded.mute_documents,
    mute_frais         = excluded.mute_frais,
    cash_sound_enabled = excluded.cash_sound_enabled,
    updated_at         = now()
  returning * into v_row;
  return v_row;
end;
$function$;

revoke all on function public.secoto_update_notification_preferences(
  boolean, boolean, boolean, boolean, boolean, boolean) from public, anon;
grant execute on function public.secoto_update_notification_preferences(
  boolean, boolean, boolean, boolean, boolean, boolean) to authenticated;

-- ----------------------------------------------------------------------------
-- 3. Contrôle immédiat : une seule signature exposée
-- ----------------------------------------------------------------------------
do $guard$
declare
  v_count integer;
begin
  select count(*) into v_count
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public'
    and p.proname = 'secoto_update_notification_preferences';
  if v_count <> 1 then
    raise exception
      'secoto_update_notification_preferences existe en % exemplaires : PostgREST ne pourra pas choisir.',
      v_count;
  end if;
end
$guard$;

notify pgrst, 'reload schema';

commit;
