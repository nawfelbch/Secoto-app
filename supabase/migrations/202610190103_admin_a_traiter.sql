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
