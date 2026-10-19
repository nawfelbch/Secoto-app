-- SECOTO — à coller dans Supabase › SQL Editor (102 puis 103), en une seule fois.

-- ============================================================================
-- SECOTO — MIGRATION 102 : NOTIFICATIONS — APERÇU DÉTAILLÉ PAR DÉFAUT
-- ----------------------------------------------------------------------------
-- Demande de Nawfal du 19/10/2026 : « l'aperçu détaillé des notifications doit
-- être l'option cochée dès le début : si les notifications sont activées, il
-- doit voir toutes les infos depuis son téléphone verrouillé ».
--
--   1. « Aperçu détaillé » devient la valeur par défaut, et les préférences
--      existantes en « masqué » passent en « détaillé » (le transporteur peut
--      toujours revenir à « masqué » dans Ma disponibilité).
--   2. « Notifications hors connexion » devient actif par défaut : un
--      transporteur qui n'a jamais ouvert l'écran Disponibilité reçoit ses
--      propositions sur son téléphone (51 comptes sur 63 au 19/10). Les
--      préférences déjà enregistrées ne sont pas modifiées.
--   3. Une préférence absente du formulaire n'écrase plus la valeur enregistrée.
--
-- Rejouable. Aucune table ni colonne supprimée.
-- ============================================================================

alter table public.partner_dispatch_preferences alter column lockscreen_privacy set default 'detailed';
alter table public.partner_dispatch_preferences alter column notify_offline set default true;
update public.partner_dispatch_preferences set lockscreen_privacy = 'detailed', updated_at = now()
 where lockscreen_privacy = 'masked';

create or replace function public.secoto_my_dispatch_preferences()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_user uuid := secoto_private.assert_authenticated(); v jsonb;
begin
  select to_jsonb(p) - 'account_id' into v from public.partner_dispatch_preferences p where p.account_id = v_user;
  return coalesce(v, jsonb_build_object('available', false, 'notify_offline', true, 'lockscreen_privacy', 'detailed',
    'zones', '[]'::jsonb, 'vehicle_classes', '[]'::jsonb, 'equipment', '[]'::jsonb, 'weekdays', '[]'::jsonb));
end;
$$;

create or replace function public.secoto_update_dispatch_preferences(p_payload jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_user uuid := secoto_private.assert_authenticated();
  v_zones text[]; v_classes text[]; v_equipment text[]; v_days smallint[];
  v_available boolean := coalesce((p_payload ->> 'available')::boolean, false);
begin
  if secoto_private.account_role(v_user) <> 'transporter' then
    raise exception 'Réservé aux partenaires transporteurs et convoyeurs.';
  end if;
  select coalesce(array_agg(distinct upper(z)), '{}') into v_zones
    from jsonb_array_elements_text(coalesce(p_payload -> 'zones', '[]'::jsonb)) z;
  if exists (select 1 from unnest(v_zones) z where z !~ '^([0-9]{2}|2A|2B|97[1-6])$') then
    raise exception 'Zone invalide : indiquez des numéros de département (ex. 75, 92, 2A).';
  end if;
  select coalesce(array_agg(distinct c), '{}') into v_classes
    from jsonb_array_elements_text(coalesce(p_payload -> 'vehicle_classes', '[]'::jsonb)) c;
  if exists (select 1 from unnest(v_classes) c where c not in ('voiture', 'utilitaire', 'moto', 'autre')) then
    raise exception 'Catégorie de véhicule invalide.';
  end if;
  select coalesce(array_agg(distinct e), '{}') into v_equipment
    from jsonb_array_elements_text(coalesce(p_payload -> 'equipment', '[]'::jsonb)) e;
  if exists (select 1 from unnest(v_equipment) e where e not in ('treuil', 'camion_ferme', 'plateau_2_places', 'plateau_3_places', 'hayon')) then
    raise exception 'Équipement invalide.';
  end if;
  select coalesce(array_agg(distinct d::smallint), '{}') into v_days
    from jsonb_array_elements_text(coalesce(p_payload -> 'weekdays', '[]'::jsonb)) d;
  if exists (select 1 from unnest(v_days) d where d not between 1 and 7) then
    raise exception 'Jour invalide.';
  end if;

  -- 102 : notifications hors connexion et aperçu détaillé par défaut ; une clé
  -- absente du formulaire garde la valeur déjà enregistrée.
  insert into public.partner_dispatch_preferences as p(account_id, available, available_changed_at, notify_offline, lockscreen_privacy, zones, vehicle_classes, equipment, weekdays, updated_at)
  values (v_user, v_available, now(), coalesce((p_payload ->> 'notify_offline')::boolean, true),
          case when p_payload ->> 'lockscreen_privacy' = 'masked' then 'masked' else 'detailed' end,
          v_zones, v_classes, v_equipment, v_days, now())
  on conflict (account_id) do update set
    available = excluded.available,
    available_changed_at = case when p.available is distinct from excluded.available then now() else p.available_changed_at end,
    notify_offline = case when p_payload ? 'notify_offline' then excluded.notify_offline else p.notify_offline end,
    lockscreen_privacy = case when p_payload ? 'lockscreen_privacy' then excluded.lockscreen_privacy else p.lockscreen_privacy end,
    zones = excluded.zones, vehicle_classes = excluded.vehicle_classes,
    equipment = excluded.equipment, weekdays = excluded.weekdays, updated_at = now();
  return public.secoto_my_dispatch_preferences();
end;
$$;

notify pgrst, 'reload schema';

-- ============================================================================
-- SECOTO — MIGRATION 103 : ADMINISTRATION SIMPLIFIÉE
-- ----------------------------------------------------------------------------
-- 1. secoto_admin_a_traiter() : les compteurs de la boîte « À traiter »
--    (devis à chiffrer, commandes sans transporteur, règlements à l'arrivée en
--    attente, marges dues par les transporteurs).
-- 2. secoto_admin_quote_suggest(devis, km) : le prix du barème actif pour un
--    devis manuel, à partir d'une distance calculée par le serveur. Lecture
--    seule : rien n'est enregistré, l'administrateur valide ou ajuste.
-- ADDITIF : deux fonctions en lecture seule. Rejouable.
-- ============================================================================

create or replace function public.secoto_admin_a_traiter()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  perform secoto_private.assert_admin();
  return jsonb_build_object(
    'devis_a_chiffrer', (select count(*) from public.transport_quotes q
                          where q.status = 'manual_review' and q.created_at > now() - interval '30 days'),
    'commandes_sans_transporteur', (select count(*) from public.transport_orders o where o.status = 'searching_partner'),
    'reglements_en_attente', (select count(*) from public.transport_orders o join public.payments p on p.id = o.payment_id
                               where o.status = 'delivered' and p.debit_a_livraison and p.status in ('requires_capture', 'capture_failed')),
    'marges_dues', (select count(*) from public.commissions_dues c where c.statut = 'due'));
end;
$$;

create or replace function public.secoto_admin_quote_suggest(p_quote_id uuid, p_distance_km numeric)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_quote public.transport_quotes%rowtype;
  v_grid public.pricing_grids%rowtype;
  v_prix jsonb;
begin
  perform secoto_private.assert_admin();
  if p_distance_km is null or p_distance_km <= 0 or p_distance_km > 6000 then
    raise exception 'Distance invalide.';
  end if;
  select * into v_quote from public.transport_quotes q where q.id = p_quote_id;
  if not found then raise exception 'Devis introuvable.' using errcode = 'P0002'; end if;
  select * into v_grid from public.pricing_grids g where g.mode = v_quote.mode and g.status = 'active';
  if v_grid.id is null then raise exception 'Aucun barème actif pour ce mode.'; end if;
  v_prix := secoto_private.price_with_grid(v_quote.mode, v_grid.params, p_distance_km, v_quote.vehicle,
    greatest(extract(epoch from (v_quote.pickup_at - now())) / 3600, 1));
  return jsonb_build_object(
    'distance_km', p_distance_km,
    'client_cents', (v_prix ->> 'client_cents')::integer,
    'partner_cents', (v_prix ->> 'partner_cents')::integer,
    'manual_reason', v_prix ->> 'manual_reason',
    'vehicules', greatest(coalesce(jsonb_array_length(case when jsonb_typeof(to_jsonb(v_quote) -> 'vehicles') = 'array'
                                                          then to_jsonb(v_quote) -> 'vehicles' end), 1), 1));
end;
$$;

revoke all on function public.secoto_admin_a_traiter() from public, anon;
revoke all on function public.secoto_admin_quote_suggest(uuid, numeric) from public, anon;
grant execute on function public.secoto_admin_a_traiter() to authenticated;
grant execute on function public.secoto_admin_quote_suggest(uuid, numeric) to authenticated;

notify pgrst, 'reload schema';
