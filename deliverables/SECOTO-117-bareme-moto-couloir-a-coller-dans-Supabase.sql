-- SECOTO 117 — à coller dans Supabase → SQL Editor, puis Run. Tout ou rien (begin/commit).
-- Seuls les NOUVEAUX devis moto changent ; les devis et commandes existants gardent leur prix.
begin;
-- ============================================================================
-- SECOTO — MIGRATION 117 : MOTO — PLAFOND 382 € SEULEMENT SUR PARIS ↔ SUD-EST
-- ----------------------------------------------------------------------------
-- Décision de Nawfal du 24/10/2026. Le prix plateau d'une moto était plafonné
-- à 382 € (transporteur 318,33 €) quelle que soit la distance : une Harley
-- Chamblet → Saint-Cyr-sur-Mer (606 km) a été envoyée à 37 transporteurs sans
-- qu'aucun ne la prenne. Désormais :
--   · Île-de-France (75, 77, 78, 91, 92, 93, 94, 95) ↔ Alpes-Maritimes (06),
--     Var (83), Bouches-du-Rhône (13), dans les deux sens : plafond inchangé ;
--   · partout ailleurs : plus de plafond, prix dégressif au-delà de 400 km
--     (0,85 €/km puis 0,68 €/km pour le transporteur, soit × 0,8 ; prix client
--     = transporteur × 1,2 comme avant).
-- Un transporteur qui a déclaré son propre tarif au km le garde tel quel.
-- Les devis et commandes existants ne changent pas. Voitures et utilitaires :
-- rien ne change. Réglages dans app_settings['bareme_transporteurs'].
-- ADDITIF, rejouable.
-- ============================================================================

update public.app_settings
   set value = value
     || jsonb_build_object('couloir_plafond', coalesce(value -> 'couloir_plafond', jsonb_build_object('moto', jsonb_build_object(
          'zone_a', jsonb_build_array('75', '77', '78', '91', '92', '93', '94', '95'),
          'zone_b', jsonb_build_array('06', '83', '13')))))
     || jsonb_build_object('degressif', coalesce(value -> 'degressif', jsonb_build_object('moto', jsonb_build_object(
          'au_dela_km', 400, 'coef', 0.8))))
 where key = 'bareme_transporteurs';

-- Le plafond s'applique-t-il à ce trajet ? Sans couloir défini pour la
-- catégorie : partout (comportement d'avant). Adresses inconnues : oui.
create or replace function secoto_private.plafond_applicable(p_class text, p_pickup jsonb, p_delivery jsonb)
returns boolean language sql stable security definer set search_path = ''
as $f$
  with c as (select secoto_private.bareme_transporteurs() -> 'couloir_plafond' -> p_class as z),
       d as (select secoto_private.department_of(p_pickup ->> 'postcode') as a,
                    secoto_private.department_of(p_delivery ->> 'postcode') as b)
  select case
    when (select z from c) is null then true
    when p_pickup is null or p_delivery is null then true
    else ((select a from d) in (select jsonb_array_elements_text((select z from c) -> 'zone_a'))
          and (select b from d) in (select jsonb_array_elements_text((select z from c) -> 'zone_b')))
      or ((select a from d) in (select jsonb_array_elements_text((select z from c) -> 'zone_b'))
          and (select b from d) in (select jsonb_array_elements_text((select z from c) -> 'zone_a')))
  end;
$f$;
revoke all on function secoto_private.plafond_applicable(text, jsonb, jsonb) from public, anon, authenticated;

-- Prix transporteur d'un trajet. p_plafond = false : pas de plafond, et le
-- tarif par défaut devient dégressif au-delà du seuil.
create or replace function secoto_private.carrier_trip_price_cents(p_account uuid, p_class text, p_km numeric, p_rolling boolean, p_plafond boolean)
returns integer language plpgsql stable security definer set search_path = ''
as $f$
declare
  v_rate jsonb := secoto_private.carrier_rate(p_account, p_class);
  v_b jsonb := secoto_private.bareme_transporteurs();
  v_km numeric := round(p_km, 1);
  v_eur numeric;
  v_seuil numeric;
  v_coef numeric;
  v_base numeric;
  v_cap numeric;
begin
  if v_rate is null or (v_rate ->> 'eur_per_km') is null or coalesce(p_km, 0) <= 0 then return null; end if;
  v_eur := (v_rate ->> 'eur_per_km')::numeric;
  v_base := v_km * v_eur;
  -- 117 : hors couloir, tarif par défaut dégressif au-delà du seuil.
  if not coalesce(p_plafond, true) and not coalesce((v_rate ->> 'declared')::boolean, false) then
    v_seuil := (v_b -> 'degressif' -> p_class ->> 'au_dela_km')::numeric;
    v_coef := (v_b -> 'degressif' -> p_class ->> 'coef')::numeric;
    if v_seuil is not null and v_coef is not null and v_km > v_seuil then
      v_base := v_seuil * v_eur + (v_km - v_seuil) * v_eur * v_coef;
    end if;
  end if;
  v_base := greatest(v_base, coalesce((v_rate ->> 'minimum_eur')::numeric, 0));
  -- Plafond client (moto) : la part distance du transporteur s'arrête au même point.
  v_cap := (v_b -> 'client_cap_eur' ->> p_class)::numeric;
  if v_cap is not null and coalesce(p_plafond, true) then
    v_base := least(v_base, round(v_cap / (v_b -> 'client_factor' ->> p_class)::numeric, 2));
  end if;
  if not coalesce(p_rolling, true) then
    v_base := v_base + coalesce((v_rate ->> 'non_rolling_eur')::numeric, 0);
  end if;
  return round(v_base * 100)::integer;
end;
$f$;
revoke all on function secoto_private.carrier_trip_price_cents(uuid, text, numeric, boolean, boolean) from public, anon, authenticated;

-- Ancienne signature : plafond partout, comme avant (appelants non adaptés).
create or replace function secoto_private.carrier_trip_price_cents(p_account uuid, p_class text, p_km numeric, p_rolling boolean)
returns integer language sql stable security definer set search_path = ''
as $f$
  select secoto_private.carrier_trip_price_cents(p_account, p_class, p_km, p_rolling, true);
$f$;

-- Prix de marché avec la destination (117) : le plafond dépend du trajet.
create or replace function secoto_private.market_price(p_price jsonb, p_vehicle jsonb, p_pickup jsonb, p_km numeric, p_pickup_at timestamptz, p_delivery jsonb)
returns jsonb language plpgsql stable security definer set search_path = ''
as $f$
declare
  v_b jsonb := secoto_private.bareme_transporteurs();
  v_class text := p_vehicle ->> 'class';
  v_rolling boolean := coalesce((p_vehicle ->> 'rolling')::boolean, true);
  v_plafond boolean := secoto_private.plafond_applicable(p_vehicle ->> 'class', p_pickup, p_delivery);
  v_prices integer[];
  v_n integer;
  v_k integer;
  v_pay integer;
  v_client integer;
  v_source text;
begin
  if p_price ? 'manual_reason' or v_class is null or not (v_b -> 'client_factor' ? v_class) then
    return p_price;
  end if;

  -- Un prix par transporteur (une entreprise et ses chauffeurs comptent pour un).
  select array_agg(x.c order by x.c) into v_prices from (
    select min(secoto_private.carrier_trip_price_cents(a.id, v_class, p_km, v_rolling, v_plafond)) as c
      from public.accounts a
     where a.role::text = 'transporter' and a.deleted_at is null
       and secoto_private.carrier_eligible_for_trip(a.id, p_vehicle, p_pickup, p_pickup_at)
     group by secoto_private.carrier_rate_owner(a.id)) x
   where x.c is not null;
  v_n := coalesce(array_length(v_prices, 1), 0);

  if v_n = 0 then
    -- Aucun transporteur encore inscrit sur ce trajet : barème de départ.
    v_pay := secoto_private.carrier_trip_price_cents(null, v_class, p_km, v_rolling, v_plafond);
    v_source := 'bareme_depart';
  else
    -- Le prix qui permet à plusieurs transporteurs de prendre la course.
    v_k := greatest(coalesce((v_b ->> 'min_carriers')::int, 3), 1);
    if v_n >= v_k then
      v_pay := v_prices[v_k];
    else
      -- Trop peu de transporteurs : aucun ne peut à lui seul faire monter le
      -- prix au-dessus du barème de départ.
      v_pay := least(v_prices[v_n], secoto_private.carrier_trip_price_cents(null, v_class, p_km, v_rolling, v_plafond));
    end if;
    v_source := 'prix_transporteurs';
  end if;
  if v_pay is null then return p_price; end if;
  v_client := secoto_private.client_from_carrier_cents(v_class, v_pay);

  return p_price || jsonb_build_object(
    'client_cents', v_client,
    'partner_cents', v_pay,
    'margin_cents', v_client - v_pay,
    'collect_cents', v_client,
    'capped', v_plafond and (v_b -> 'client_cap_eur' ->> v_class) is not null and v_client >= ((v_b -> 'client_cap_eur' ->> v_class)::numeric * 100)::int,
    'lines', jsonb_build_array(jsonb_build_object(
      'label', format('Transport sur plateau · %s km', replace(trim(trailing '.' from trim(trailing '0' from to_char(round(p_km, 1), 'FM999990.0'))), '.', ',')),
      'eur', round(v_client / 100.0, 2))),
    'detail', jsonb_build_array(jsonb_build_object(
      'pricing', 'bareme_transporteurs', 'source', v_source, 'carriers', v_n, 'partner_cents', v_pay,
      'plafond', v_plafond)));
end;
$f$;
revoke all on function secoto_private.market_price(jsonb, jsonb, jsonb, numeric, timestamptz, jsonb) from public, anon, authenticated;

-- Ancienne signature : destination inconnue, plafond partout (comme avant).
create or replace function secoto_private.market_price(p_price jsonb, p_vehicle jsonb, p_pickup jsonb, p_km numeric, p_pickup_at timestamptz)
returns jsonb language sql stable security definer set search_path = ''
as $f$
  select secoto_private.market_price(p_price, p_vehicle, p_pickup, p_km, p_pickup_at, null::jsonb);
$f$;

-- Création du devis : la destination est transmise.
select secoto_private.mig074_patch('public.secoto_quote_create(uuid,jsonb,jsonb)'::regprocedure,
  'v_price := secoto_private.market_price(v_price, v_vehicle, v_pickup, v_distance, v_pickup_at);',
  'v_price := secoto_private.market_price(v_price, v_vehicle, v_pickup, v_distance, v_pickup_at, v_delivery);  -- 117');

-- Trois offres : même règle de plafond que le devis.
select secoto_private.mig074_patch('secoto_private.calculer_offres(public.transport_quotes)'::regprocedure,
  'min(secoto_private.carrier_trip_price_cents(a.id, v_class, v_km, v_rolling)) as prix,',
  'min(secoto_private.carrier_trip_price_cents(a.id, v_class, v_km, v_rolling, secoto_private.plafond_applicable(v_class, q.pickup, q.delivery))) as prix,  -- 117');

-- Diffusion : le prix du transporteur est comparé avec la même règle.
select secoto_private.mig074_patch('secoto_private.carrier_accepts_pay(uuid,uuid)'::regprocedure,
  '(q.route ->> ''distance_km'')::numeric, coalesce((q.vehicle ->> ''rolling'')::boolean, true))',
  '(q.route ->> ''distance_km'')::numeric, coalesce((q.vehicle ->> ''rolling'')::boolean, true),
               secoto_private.plafond_applicable(q.vehicle ->> ''class'', q.pickup, q.delivery))  -- 117');

notify pgrst, 'reload schema';
commit;
