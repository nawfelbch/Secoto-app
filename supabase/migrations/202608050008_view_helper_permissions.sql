-- SECOTO 1.2 — correctif des vues appelant des helpers privés
-- À exécuter après 202608050007_luxury_routing_enforcement.sql.
--
-- Les vues PostgREST ne doivent pas appeler directement les fonctions du
-- schéma secoto_private, dont l'exécution est volontairement retirée aux rôles
-- client. Elles passent désormais par des wrappers publics à portée minimale.

begin;

do $guard$
begin
  if to_regprocedure('secoto_private.is_admin(uuid)') is null then
    raise exception 'Helper secoto_private.is_admin(uuid) absent.';
  end if;

  if to_regprocedure(
    'secoto_private.transporter_matches_mission(uuid,uuid)'
  ) is null then
    raise exception
      'Helper secoto_private.transporter_matches_mission(uuid,uuid) absent.';
  end if;

  if to_regclass('public.secoto_missions_admin_v2') is null
     or to_regclass('public.secoto_public_missions_v2') is null then
    raise exception 'Vues SECOTO requises absentes.';
  end if;
end
$guard$;

create or replace function public.secoto_is_admin()
returns boolean
language sql
stable
security definer
set search_path = ''
as $function$
  select secoto_private.is_admin(auth.uid());
$function$;

create or replace function
  public.secoto_current_transporter_matches_mission(
    p_mission_id uuid
  )
returns boolean
language sql
stable
security definer
set search_path = ''
as $function$
  select secoto_private.transporter_matches_mission(
    auth.uid(),
    p_mission_id
  );
$function$;

revoke all on function public.secoto_is_admin()
  from public, anon;
revoke all on function
  public.secoto_current_transporter_matches_mission(uuid)
  from public, anon;

grant execute on function public.secoto_is_admin()
  to authenticated;
grant execute on function
  public.secoto_current_transporter_matches_mission(uuid)
  to authenticated;

create or replace view public.secoto_missions_admin_v2
with (security_barrier = true, security_invoker = false)
as
select
  m.id,
  m.public_ref,
  m.type,
  m.status,
  m.progress_status,
  m.from_city,
  m.to_city,
  m.pickup_address,
  m.delivery_address,
  m.mission_date,
  m.vehicle,
  m.plate,
  m.distance_km,
  m.carrier_cost,
  m.client_price,
  m.carrier_pay,
  m.margin,
  m.client_name,
  m.client_contact,
  m.client_phone,
  m.price_mode,
  m.proposed_price,
  m.payment_method,
  m.notes,
  m.created_by_role,
  m.client_account_id,
  m.assigned_transporter_id,
  m.assigned_transporter_name,
  m.source_request_id,
  m.created_at,
  m.vehicle_category
from public.missions m
where public.secoto_is_admin();

create or replace view public.secoto_public_missions_v2
with (security_barrier = true, security_invoker = false)
as
select
  m.id,
  m.public_ref,
  m.type,
  m.status,
  m.progress_status,
  m.from_city,
  m.to_city,
  m.vehicle,
  m.distance_km,
  m.created_at,
  m.vehicle_category
from public.missions m
where public.secoto_current_transporter_matches_mission(m.id);

grant select on table public.secoto_missions_admin_v2
  to authenticated;
grant select on table public.secoto_public_missions_v2
  to authenticated;

comment on function public.secoto_is_admin() is
  'Indique uniquement si le compte authentifié courant est administrateur SECOTO.';
comment on function
  public.secoto_current_transporter_matches_mission(uuid) is
  'Vérifie uniquement la compatibilité du transporteur authentifié avec une mission.';

notify pgrst, 'reload schema';

commit;
