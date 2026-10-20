-- ============================================================================
-- SECOTO — MIGRATION 107 : TOUTES LES COURSES À TOUS LES TRANSPORTEURS DU BON TYPE
-- ----------------------------------------------------------------------------
-- Décision de Nawfal du 20/10/2026 : chaque transporteur reçoit TOUJOURS
-- toutes les courses disponibles de son métier :
--   · convoyage -> tous les convoyeurs ;
--   · plateau standard -> tous les transporteurs VL et PL ;
--   · plateau prestige (plateau fermé) -> VL / PL dont l'aptitude prestige est
--     approuvée par SECOTO (inchangé).
-- Ne filtrent PLUS : « Ma disponibilité », zones, classes de véhicules, jours,
-- barème personnel du transporteur, offre Express / Standard / Éco, et le
-- refus des courses plateau standard (receives_standard_plateau).
-- Restent exigés (sécurité, promesses publiées) : compte actif et validé par
-- SECOTO, documents en règle, aucune marge SECOTO impayée en retard, et la
-- course n'a pas déjà été refusée par ce transporteur.
-- Nouveau : un transporteur validé APRÈS la diffusion reçoit quand même les
-- courses en cours (complément chaque minute par la maintenance).
-- Rejouable. Aucune donnée existante modifiée, aucun paiement touché.
-- ============================================================================

create or replace function secoto_private.od_partner_eligible(p_partner uuid, p_order uuid)
returns boolean language sql stable security definer set search_path = ''
as $f$
  select exists (
    select 1
    from public.transport_orders o
    join public.transport_quotes q on q.id = o.quote_id
    join public.accounts a on a.id = p_partner
    where o.id = p_order
      and a.role::text = 'transporter' and a.status::text = 'active'
      and coalesce(a.is_verified, false) and a.deleted_at is null
      and secoto_private.partner_documents_valid(a.id)
      and (
        (o.mode = 'convoyage' and a.transporter_type::text = 'convoyeur')
        or (o.mode = 'plateau' and a.transporter_type::text in ('vl', 'pl') and (
              coalesce(q.vehicle ->> 'category', 'standard') = 'standard'
           or (q.vehicle ->> 'category' = 'luxury' and a.luxury_closed_transport_status = 'approved')))
      )
      and not exists (select 1 from public.transport_offers x where x.order_id = o.id and x.partner_id = a.id and x.status = 'declined')
      and not secoto_private.commission_en_retard(a.id)  -- 100 : marge SECOTO impayée
  );
$f$;

-- Diffusion : plus de filtre sur le barème personnel ni sur l'offre choisie.
select secoto_private.mig074_patch('secoto_private.od_broadcast(uuid)'::regprocedure,
  'and (v_order.offre = ''eco'' or secoto_private.carrier_accepts_pay(a.id, p_order_id))',
  '/* 107 : tous les transporteurs du bon type */');
select secoto_private.mig074_patch('secoto_private.od_broadcast(uuid)'::regprocedure,
  'and secoto_private.offre_partenaire_ok(a.id, v_order.offre) loop  -- 099',
  'loop  -- 099 / 107');

-- Complément de diffusion : transporteurs devenus éligibles après le tour en
-- cours (nouveau compte validé, documents complétés…). Même offre, même
-- rémunération, même échéance que les autres ; les autres ne sont pas touchés.
create or replace function secoto_private.od_completer_diffusion(p_order_id uuid)
returns integer language plpgsql security definer set search_path = ''
as $f$
declare
  v_order public.transport_orders%rowtype;
  v_quote public.transport_quotes%rowtype;
  v_offer_id uuid;
  v_count integer := 0;
  r record;
begin
  select * into v_order from public.transport_orders o where o.id = p_order_id for update;
  if v_order.status is distinct from 'searching_partner' or v_order.lock_partner_id is not null
     or coalesce(v_order.dispatch_round, 0) < 1 or v_order.offers_expire_at is null or v_order.offers_expire_at <= now() then
    return 0;
  end if;
  if not secoto_private.flag('dispatch_notifications') then return 0; end if;
  select * into v_quote from public.transport_quotes q where q.id = v_order.quote_id;

  for r in select a.id from public.accounts a
            where a.role::text = 'transporter'
              and not exists (select 1 from public.transport_offers x
                               where x.order_id = p_order_id and x.partner_id = a.id and x.round = v_order.dispatch_round)
              and secoto_private.od_partner_eligible(a.id, p_order_id) loop
    v_offer_id := null;
    insert into public.transport_offers(order_id, partner_id, round, partner_pay_cents, expires_at)
    values (p_order_id, r.id, v_order.dispatch_round, v_order.partner_pay_cents, v_order.offers_expire_at)
    on conflict (order_id, partner_id, round) do nothing
    returning id into v_offer_id;
    if v_offer_id is not null then
      v_count := v_count + 1;
      perform secoto_private.notify_event(r.id, 'mission_offer', 'Mission disponible',
        format('%s · %s → %s · %s · %s € pour vous',
          coalesce(nullif(v_quote.vehicle ->> 'model', ''), 'Véhicule'),
          v_quote.pickup ->> 'city', v_quote.delivery ->> 'city',
          case when coalesce((v_quote.vehicle ->> 'rolling')::boolean, true) then 'roulant' else 'NON ROULANT' end,
          to_char(v_order.partner_pay_cents / 100.0, 'FM999990D00')),
        null, 'offre', 'offer:' || v_offer_id::text, v_offer_id);
    end if;
  end loop;
  return v_count;
end;
$f$;
revoke all on function secoto_private.od_completer_diffusion(uuid) from public, anon, authenticated;

create or replace function public.secoto_od_completer_diffusions()
returns jsonb language plpgsql security definer set search_path = ''
as $f$
declare r record; v_total integer := 0;
begin
  for r in select o.id from public.transport_orders o
            where o.status = 'searching_partner' and o.lock_partner_id is null
              and o.offers_expire_at > now()
            order by o.created_at limit 50 loop
    v_total := v_total + secoto_private.od_completer_diffusion(r.id);
  end loop;
  return jsonb_build_object('offres_ajoutees', v_total);
end;
$f$;
revoke all on function public.secoto_od_completer_diffusions() from public, anon, authenticated;
grant execute on function public.secoto_od_completer_diffusions() to service_role;

-- Les courses en recherche reçoivent tout de suite les transporteurs manquants.
select public.secoto_od_completer_diffusions();

notify pgrst, 'reload schema';
