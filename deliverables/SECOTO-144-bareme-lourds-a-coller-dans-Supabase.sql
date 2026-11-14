-- ============================================================================
-- SECOTO — MIGRATION 144 : BARÈME UTILITAIRES, CARAVANES, CAMPING-CARS
-- ----------------------------------------------------------------------------
-- Validé par Nawfal le 14/11/2026 : ces véhicules longs et lourds étaient sous-
-- estimés. Nouveau calcul, pensé à partir de ce que touchent le transporteur et
-- SECOTO :
--   · rémunération transporteur : 375 € minimum, puis montée jusqu'à 700 € à
--     345 km et 800 € à 465 km, puis 1,66 €/km au-delà ;
--   · prix client : SECOTO garde au moins 75 € NET après URSSAF (21,2 % de la
--     marge) et frais de paiement (5 %, cas Klarna, le plus cher), arrondi aux
--     5 € supérieurs ; jamais sous le minimum du gabarit (450 €) ;
--   · Express = Standard × 1,2 (client et transporteur) ; pas d'Éco ;
--   · caravane / camping-car : +20 % au-delà de 3 t, +10 % au-delà de 7 m
--     (sur la rémunération), sur devis au-delà de 3,5 t ; non roulant : supplément.
-- Exemples : 345 km 850 € (transporteur 700 €), Paris → Lyon 960 € (800 €),
-- Paris → Nice 1 785 € (1 572 €). Réglages : app_settings['bareme_v3'].lourds.
-- Les citadines, berlines, 4x4 et motos ne changent pas.
-- ADDITIF, rejouable. Aucun prix de commande existante n'est modifié.
-- ============================================================================

update public.app_settings
   set value = jsonb_set(value, '{lourds}', jsonb_build_object(
     'gabarits', jsonb_build_array('utilitaire', 'caravane', 'camping_car'),
     'transporteur_min_eur', 375,
     'palier_depart_km', 200,
     'palier_1_km', 345, 'palier_1_eur', 700,
     'palier_2_km', 465, 'palier_2_eur', 800,
     'eur_km_au_dela', 1.66,
     'net_min_eur', 75,
     'urssaf_pct', 21.2,
     'frais_paiement_pct', 5,
     'arrondi_eur', 5,
     'express_coef', 1.2,
     'eco', false), true)
 where key = 'bareme_v3' and not (value ? 'lourds');

-- Rémunération transporteur d'un véhicule lourd (euros) pour une distance.
create or replace function secoto_private.lourds_transporteur_eur(p_km numeric)
returns numeric language plpgsql stable security definer set search_path = '' as $$
declare
  l jsonb := secoto_private.bareme_v3_reglages() -> 'lourds';
  v_min numeric := coalesce((l ->> 'transporteur_min_eur')::numeric, 375);
  k0 numeric := coalesce((l ->> 'palier_depart_km')::numeric, 200);
  k1 numeric := coalesce((l ->> 'palier_1_km')::numeric, 345);
  e1 numeric := coalesce((l ->> 'palier_1_eur')::numeric, 700);
  k2 numeric := coalesce((l ->> 'palier_2_km')::numeric, 465);
  e2 numeric := coalesce((l ->> 'palier_2_eur')::numeric, 800);
  v_au_dela numeric := coalesce((l ->> 'eur_km_au_dela')::numeric, 1.66);
  v numeric;
begin
  v := case
    when p_km <= k0 then v_min
    when p_km < k1 then v_min + (p_km - k0) * (e1 - v_min) / (k1 - k0)
    when p_km <= k2 then e1 + (p_km - k1) * (e2 - e1) / (k2 - k1)
    else e2 + (p_km - k2) * v_au_dela
  end;
  return greatest(v_min, v);
end;
$$;
revoke all on function secoto_private.lourds_transporteur_eur(numeric) from public, anon, authenticated;

-- Prix client (centimes) qui laisse au moins net_min_eur à SECOTO après URSSAF
-- (sur la marge) et frais de paiement (sur le prix).
create or replace function secoto_private.lourds_client_cents(p_pay_cents integer, p_minimum_cents integer)
returns integer language plpgsql stable security definer set search_path = '' as $$
declare
  l jsonb := secoto_private.bareme_v3_reglages() -> 'lourds';
  u numeric := coalesce((l ->> 'urssaf_pct')::numeric, 21.2) / 100;
  k numeric := coalesce((l ->> 'frais_paiement_pct')::numeric, 5) / 100;
  v_net numeric := coalesce((l ->> 'net_min_eur')::numeric, 75) * 100;
  v_arrondi numeric := coalesce((l ->> 'arrondi_eur')::numeric, 5) * 100;
  v numeric;
begin
  -- prix - pay - k*prix - u*(prix - pay) >= net  =>  prix >= (net + (1-u)*pay) / (1-k-u)
  v := (v_net + (1 - u) * p_pay_cents) / (1 - k - u);
  v := ceil(v / v_arrondi) * v_arrondi;
  return greatest(coalesce(p_minimum_cents, 0), v::int);
end;
$$;
revoke all on function secoto_private.lourds_client_cents(integer, integer) from public, anon, authenticated;

create or replace function secoto_private.est_lourd(p_gabarit text)
returns boolean language sql stable security definer set search_path = '' as $$
  select coalesce(p_gabarit in (select jsonb_array_elements_text(secoto_private.bareme_v3_reglages() -> 'lourds' -> 'gabarits')), false);
$$;
revoke all on function secoto_private.est_lourd(text) from public, anon, authenticated;

-- Barème v3 : branche « véhicules lourds » (le reste est inchangé).
create or replace function secoto_private.bareme_v3(p_price jsonb, p_vehicle jsonb, p_pickup jsonb, p_delivery jsonb, p_km numeric)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  b jsonb := secoto_private.bareme_v3_reglages();
  v_gab text := secoto_private.gabarit_vehicule(p_vehicle);
  g jsonb;
  v_km numeric := round(coalesce(p_km, 0), 1);
  v_tranches jsonb;
  t jsonb;
  v_prev numeric := 0;
  v_pay numeric;
  v_poids numeric := nullif(p_vehicle ->> 'weight_kg', '')::numeric;
  v_long numeric := nullif(p_vehicle ->> 'length_m', '')::numeric;
  v_dep_a text := secoto_private.department_of(p_pickup ->> 'postcode');
  v_dep_b text := secoto_private.department_of(p_delivery ->> 'postcode');
  v_ajust text := null;
  v_pay_c integer;
  v_client integer;
  v_cap numeric;
  v_lourd boolean;
begin
  if not secoto_private.flag('bareme_v3') or p_price ? 'manual_reason' or v_km <= 0
     or coalesce(p_vehicle ->> 'category', 'standard') <> 'standard' or v_gab is null then
    return p_price;
  end if;
  if v_gab = 'poids_lourd' then
    return p_price || jsonb_build_object('manual_reason', 'sur_devis_poids_lourd');
  end if;
  if v_gab in ('caravane', 'camping_car') and v_poids > coalesce((b ->> 'poids_max_kg')::numeric, 3500) then
    return p_price || jsonb_build_object('manual_reason', 'sur_devis_plus_3_5_t');
  end if;
  g := b -> 'gabarits' -> v_gab;
  if g is null then return p_price; end if;
  v_lourd := secoto_private.est_lourd(v_gab);  -- 144

  if v_lourd then
    -- 144 : utilitaire, caravane, camping-car — rémunération transporteur garantie.
    v_pay := secoto_private.lourds_transporteur_eur(v_km);
  else
    -- Forfait + kilomètres par tranches dégressives.
    v_tranches := coalesce(case when v_gab = 'utilitaire' then b -> 'tranches_utilitaire' end, b -> 'tranches');
    v_pay := coalesce((b ->> 'forfait_eur')::numeric, 60);
    for t in select value from jsonb_array_elements(v_tranches) loop
      exit when v_km <= v_prev;
      v_pay := v_pay + (least(v_km, coalesce((t ->> 'jusqu_a_km')::numeric, v_km)) - v_prev) * (t ->> 'eur_km')::numeric;
      v_prev := coalesce((t ->> 'jusqu_a_km')::numeric, v_km);
    end loop;
    v_pay := v_pay * (g ->> 'coef')::numeric;
  end if;

  -- Caravane / camping-car : plus cher si lourd ou long.
  if v_gab in ('caravane', 'camping_car') then
    if v_poids > coalesce((b ->> 'poids_majore_kg')::numeric, 3000) then
      v_pay := v_pay * (1 + coalesce((b ->> 'poids_majoration_pct')::numeric, 20) / 100);
    end if;
    if v_long > coalesce((b ->> 'longueur_majoree_m')::numeric, 7) then
      v_pay := v_pay * (1 + coalesce((b ->> 'longueur_majoration_pct')::numeric, 10) / 100);
    end if;
  end if;

  -- Voitures : axe principal moins cher, zones sans retour plus cher.
  if v_gab in ('citadine', 'berline', 'grand') then
    if v_dep_a in (select jsonb_array_elements_text(b -> 'axe_departements'))
       and v_dep_b in (select jsonb_array_elements_text(b -> 'axe_departements')) then
      v_pay := v_pay * (1 + coalesce((b ->> 'axe_pct')::numeric, -5) / 100);
      v_ajust := 'axe';
    elsif v_dep_a not in (select jsonb_array_elements_text(b -> 'grandes_zones'))
       or v_dep_b not in (select jsonb_array_elements_text(b -> 'grandes_zones')) then
      v_pay := v_pay * (1 + coalesce((b ->> 'hors_zone_pct')::numeric, 5) / 100);
      v_ajust := 'hors_zone';
    end if;
  end if;

  if not coalesce((p_vehicle ->> 'rolling')::boolean, true) then
    v_pay := v_pay + coalesce((g ->> 'non_roulant_eur')::numeric, 70);
  end if;

  v_pay_c := round(v_pay * 100)::int;
  if v_lourd then
    -- 144 : le prix part de la rémunération ; elle reste celle calculée.
    v_client := secoto_private.lourds_client_cents(v_pay_c, round((g ->> 'minimum_eur')::numeric * 100)::int);
  else
    v_client := secoto_private.client_v3_cents(v_pay_c, round((g ->> 'minimum_eur')::numeric * 100)::int);
    -- Moto : prix plafonné sur l'axe Île-de-France ↔ Côte d'Azur (promesse existante).
    if v_gab = 'moto' and secoto_private.plafond_applicable('moto', p_pickup, p_delivery) then
      v_cap := coalesce((b ->> 'moto_plafond_couloir_eur')::numeric, 382) * 100;
      v_client := least(v_client, v_cap::int);
    end if;
    v_pay_c := v_client - secoto_private.marge_v3_cents(v_client);
  end if;

  return (p_price - 'manual_reason') || jsonb_build_object(
    'client_cents', v_client,
    'partner_cents', v_pay_c,
    'margin_cents', v_client - v_pay_c,
    'collect_cents', v_client,
    'lines', jsonb_build_array(jsonb_build_object(
      'label', format('Transport sur plateau · %s km', replace(trim(trailing '.' from trim(trailing '0' from to_char(v_km, 'FM999990.0'))), '.', ',')),
      'eur', round(v_client / 100.0, 2))),
    'detail', jsonb_build_array(jsonb_build_object(
      'pricing', case when v_lourd then 'bareme_secoto_v3_lourds' else 'bareme_secoto_v3' end,
      'gabarit', v_gab, 'ajustement', v_ajust,
      'poids_kg', v_poids, 'longueur_m', v_long, 'partner_cents', v_pay_c)));
end;
$$;
revoke all on function secoto_private.bareme_v3(jsonb, jsonb, jsonb, jsonb, numeric) from public, anon, authenticated;

-- Express : × 1,2 pour les véhicules lourds (× 1,35 pour les autres, inchangé).
select secoto_private.mig074_patch(
  'secoto_private.calculer_offres(public.transport_quotes)'::regprocedure,
  $a$  v_coef numeric := coalesce((r -> 'express' ->> 'coef')::numeric, 1.30);$a$,
  $b$  v_coef numeric := case when secoto_private.est_lourd(secoto_private.gabarit_vehicule(q.vehicle))  -- 144
                          then coalesce((secoto_private.bareme_v3_reglages() -> 'lourds' ->> 'express_coef')::numeric, 1.20)
                          else coalesce((r -> 'express' ->> 'coef')::numeric, 1.30) end;$b$);

-- Pas d'Éco pour les véhicules lourds (pour le moment).
select secoto_private.mig074_patch(
  'secoto_private.offre_eco_v3(public.transport_quotes,integer)'::regprocedure,
  $a$  if v_places is null then return null; end if;$a$,
  $b$  if v_places is null then return null; end if;
  -- 144 : pas d'Éco pour utilitaire, caravane, camping-car.
  if secoto_private.est_lourd(v_gab) and not coalesce((secoto_private.bareme_v3_reglages() -> 'lourds' ->> 'eco')::boolean, false) then
    return null;
  end if;$b$);

-- Site vitrine : coefficient Express des véhicules lourds, puis table publique recalculée.
select secoto_private.mig074_patch(
  'secoto_private.bareme_v3_public_calcul()'::regprocedure,
  $a$    'express', jsonb_build_object('coef', coalesce((t -> 'express' ->> 'coef')::numeric, 1.30),$a$,
  $b$    'lourds', jsonb_build_object('gabarits', b -> 'lourds' -> 'gabarits',  -- 144
                                 'express_coef', coalesce((b -> 'lourds' ->> 'express_coef')::numeric, 1.20),
                                 'eco', coalesce((b -> 'lourds' ->> 'eco')::boolean, false)),
    'express', jsonb_build_object('coef', coalesce((t -> 'express' ->> 'coef')::numeric, 1.30),$b$);
select secoto_private.bareme_v3_public_rafraichir() is not null as site_recalcule;

notify pgrst, 'reload schema';
