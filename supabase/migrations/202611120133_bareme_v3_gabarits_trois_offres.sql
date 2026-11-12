-- ============================================================================
-- SECOTO — MIGRATION 133 : NOUVEAU BARÈME PAR GABARIT + TROIS OFFRES
-- ----------------------------------------------------------------------------
-- Validé par Nawfal le 12/11/2026.
--   · Un barème par gabarit : citadine, berline/SUV compact, 4x4/grand SUV,
--     utilitaire, moto, caravane, camping-car (≤ 3,5 t). Bus, camion, poids
--     lourd et tout véhicule de plus de 3,5 t : sur devis.
--   · Rémunération transporteur = (forfait 60 € + km dégressifs) × coef.
--     Prix client = max(minimum du gabarit, transporteur + 75 €, transporteur / 0,83).
--     La marge SECOTO ne descend jamais sous 75 €.
--   · Caravane / camping-car : poids et longueur obligatoires ; +20 % au-delà
--     de 3 t, +10 % au-delà de 7 m (jamais moins cher).
--   · Voitures : −5 % sur l'axe Paris ↔ Lyon ↔ Marseille ↔ Côte d'Azur,
--     +5 % si le départ ou l'arrivée est hors des grandes zones.
--   · Trois offres toujours proposées (plus de seuil de 3 transporteurs) :
--     Express = Standard × 1,30 ; Standard = barème ; Éco = de grande ville à
--     grande ville (dépôt et retrait par le client), plafonnée par gabarit.
--     Pas d'Éco pour caravane / camping-car ; moto Éco seulement sur l'axe
--     Île-de-France ↔ Côte d'Azur.
-- Réglages modifiables sans redéploiement : app_settings['bareme_v3'].
-- Interrupteur : secoto_feature_flags['bareme_v3']. Commandes existantes
-- inchangées. ADDITIF, rejouable.
-- ============================================================================

-- Interrupteur « bareme_v3 » : ajouté à la liste autorisée sans toucher aux autres.
do $f$
declare v text;
begin
  select pg_get_constraintdef(c.oid) into v from pg_constraint c where c.conname = 'secoto_feature_flags_key_check';
  if v is not null and v not like '%bareme_v3%' then
    execute 'alter table public.secoto_feature_flags drop constraint secoto_feature_flags_key_check';
    execute 'alter table public.secoto_feature_flags add constraint secoto_feature_flags_key_check '
            || replace(v, '])', ', ''bareme_v3''::text])');
  end if;
end $f$;
insert into public.secoto_feature_flags(key, enabled) values ('bareme_v3', true)
on conflict (key) do nothing;

insert into public.app_settings(key, value) values ('bareme_v3', jsonb_build_object(
  'forfait_eur', 60,
  'marge_min_eur', 75,
  'marge_pct', 17,
  'tranches', jsonb_build_array(
    jsonb_build_object('jusqu_a_km', 300, 'eur_km', 0.95),
    jsonb_build_object('jusqu_a_km', 700, 'eur_km', 0.80),
    jsonb_build_object('jusqu_a_km', null, 'eur_km', 0.70)),
  'tranches_utilitaire', jsonb_build_array(
    jsonb_build_object('jusqu_a_km', 300, 'eur_km', 0.95),
    jsonb_build_object('jusqu_a_km', 700, 'eur_km', 0.95),
    jsonb_build_object('jusqu_a_km', null, 'eur_km', 0.90)),
  'gabarits', jsonb_build_object(
    'citadine',    jsonb_build_object('coef', 1.00, 'minimum_eur', 245, 'non_roulant_eur', 70, 'eco_plafond_eur', 500),
    'berline',     jsonb_build_object('coef', 1.10, 'minimum_eur', 265, 'non_roulant_eur', 70, 'eco_plafond_eur', 600),
    'grand',       jsonb_build_object('coef', 1.25, 'minimum_eur', 295, 'non_roulant_eur', 90, 'eco_plafond_eur', 700),
    'utilitaire',  jsonb_build_object('coef', 1.40, 'minimum_eur', 450, 'non_roulant_eur', 90, 'eco_plafond_eur', 700),
    'moto',        jsonb_build_object('coef', 0.75, 'minimum_eur', 220, 'non_roulant_eur', 50, 'eco_plafond_eur', 350),
    'caravane',    jsonb_build_object('coef', 1.40, 'minimum_eur', 450, 'non_roulant_eur', 90),
    'camping_car', jsonb_build_object('coef', 1.40, 'minimum_eur', 450, 'non_roulant_eur', 90)),
  'poids_majore_kg', 3000, 'poids_majoration_pct', 20,
  'longueur_majoree_m', 7, 'longueur_majoration_pct', 10,
  'poids_max_kg', 3500,
  'axe_departements', jsonb_build_array('75','77','78','91','92','93','94','95','69','13','83','06'),
  'axe_pct', -5,
  'grandes_zones', jsonb_build_array('75','77','78','91','92','93','94','95','69','13','83','06','33','31','44','59','67','34','35'),
  'hors_zone_pct', 5,
  'moto_plafond_couloir_eur', 382,
  'eco', jsonb_build_object(
    'eur_km', 0.45, 'transporteur_min_eur', 150, 'client_min_eur', 195, 'marge_pct', 20,
    'coef', jsonb_build_object('citadine', 1.0, 'berline', 1.0, 'grand', 1.2, 'utilitaire', 1.2, 'moto', 0.8),
    'villes', jsonb_build_array(
      jsonb_build_object('nom', 'Paris', 'cp', '75001', 'lat', 48.8566, 'lng', 2.3522),
      jsonb_build_object('nom', 'Lyon', 'cp', '69001', 'lat', 45.7640, 'lng', 4.8357),
      jsonb_build_object('nom', 'Marseille', 'cp', '13001', 'lat', 43.2965, 'lng', 5.3698),
      jsonb_build_object('nom', 'Bordeaux', 'cp', '33000', 'lat', 44.8378, 'lng', -0.5792),
      jsonb_build_object('nom', 'Toulouse', 'cp', '31000', 'lat', 43.6047, 'lng', 1.4442),
      jsonb_build_object('nom', 'Nice', 'cp', '06000', 'lat', 43.7102, 'lng', 7.2620),
      jsonb_build_object('nom', 'Nantes', 'cp', '44000', 'lat', 47.2184, 'lng', -1.5536),
      jsonb_build_object('nom', 'Lille', 'cp', '59000', 'lat', 50.6292, 'lng', 3.0573),
      jsonb_build_object('nom', 'Strasbourg', 'cp', '67000', 'lat', 48.5734, 'lng', 7.7521),
      jsonb_build_object('nom', 'Montpellier', 'cp', '34000', 'lat', 43.6108, 'lng', 3.8767),
      jsonb_build_object('nom', 'Rennes', 'cp', '35000', 'lat', 48.1173, 'lng', -1.6778)))
))
on conflict (key) do nothing;

create or replace function secoto_private.bareme_v3_reglages()
returns jsonb language sql stable security definer set search_path = '' as $$
  select coalesce((select value from public.app_settings where key = 'bareme_v3'), '{}'::jsonb);
$$;
revoke all on function secoto_private.bareme_v3_reglages() from public, anon, authenticated;

-- Gabarit du véhicule (anciens devis : déduit de la catégorie).
create or replace function secoto_private.gabarit_vehicule(p_vehicle jsonb)
returns text language sql immutable set search_path = '' as $$
  select coalesce(nullif(p_vehicle ->> 'gabarit', ''),
    case p_vehicle ->> 'class' when 'voiture' then 'berline' when 'utilitaire' then 'utilitaire' when 'moto' then 'moto' end);
$$;
revoke all on function secoto_private.gabarit_vehicule(jsonb) from public, anon, authenticated;

-- Distance à vol d'oiseau (km).
create or replace function secoto_private.km_vol(p_lat1 numeric, p_lng1 numeric, p_lat2 numeric, p_lng2 numeric)
returns numeric language sql immutable set search_path = '' as $$
  select round((2 * 6371 * asin(sqrt(
    power(sin(radians((p_lat2 - p_lat1)::float8) / 2), 2)
    + cos(radians(p_lat1::float8)) * cos(radians(p_lat2::float8)) * power(sin(radians((p_lng2 - p_lng1)::float8) / 2), 2))))::numeric, 1);
$$;
revoke all on function secoto_private.km_vol(numeric, numeric, numeric, numeric) from public, anon, authenticated;

-- Grande ville Éco la plus proche d'une adresse.
create or replace function secoto_private.ville_eco(p_place jsonb)
returns jsonb language sql stable security definer set search_path = '' as $$
  select v from jsonb_array_elements(coalesce(secoto_private.bareme_v3_reglages() -> 'eco' -> 'villes', '[]'::jsonb)) v
   where (p_place ->> 'lat') is not null and (p_place ->> 'lng') is not null
   order by secoto_private.km_vol((p_place ->> 'lat')::numeric, (p_place ->> 'lng')::numeric, (v ->> 'lat')::numeric, (v ->> 'lng')::numeric)
   limit 1;
$$;
revoke all on function secoto_private.ville_eco(jsonb) from public, anon, authenticated;

-- Prix client à partir de la rémunération : marge ≥ 75 € et ≥ 17 %.
create or replace function secoto_private.client_v3_cents(p_pay_cents integer, p_minimum_cents integer)
returns integer language sql stable security definer set search_path = '' as $$
  with r as (select secoto_private.bareme_v3_reglages() as b)
  select greatest(coalesce(p_minimum_cents, 0),
                  p_pay_cents + round(coalesce((b ->> 'marge_min_eur')::numeric, 75) * 100)::int,
                  round(p_pay_cents / (1 - coalesce((b ->> 'marge_pct')::numeric, 17) / 100))::int)
    from r;
$$;
revoke all on function secoto_private.client_v3_cents(integer, integer) from public, anon, authenticated;

create or replace function secoto_private.marge_v3_cents(p_client_cents integer)
returns integer language sql stable security definer set search_path = '' as $$
  with r as (select secoto_private.bareme_v3_reglages() as b)
  select greatest(round(coalesce((b ->> 'marge_min_eur')::numeric, 75) * 100)::int,
                  round(p_client_cents * coalesce((b ->> 'marge_pct')::numeric, 17) / 100)::int)
    from r;
$$;
revoke all on function secoto_private.marge_v3_cents(integer) from public, anon, authenticated;

-- Barème Standard d'un véhicule (devis plateau d'un seul véhicule, gamme standard).
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

  -- Forfait + kilomètres par tranches dégressives (utilitaire : presque pas dégressif).
  v_tranches := coalesce(case when v_gab = 'utilitaire' then b -> 'tranches_utilitaire' end, b -> 'tranches');
  v_pay := coalesce((b ->> 'forfait_eur')::numeric, 60);
  for t in select value from jsonb_array_elements(v_tranches) loop
    exit when v_km <= v_prev;
    v_pay := v_pay + (least(v_km, coalesce((t ->> 'jusqu_a_km')::numeric, v_km)) - v_prev) * (t ->> 'eur_km')::numeric;
    v_prev := coalesce((t ->> 'jusqu_a_km')::numeric, v_km);
  end loop;
  v_pay := v_pay * (g ->> 'coef')::numeric;

  -- Caravane / camping-car : jamais moins cher, plus cher si lourd ou long.
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
  v_client := secoto_private.client_v3_cents(v_pay_c, round((g ->> 'minimum_eur')::numeric * 100)::int);
  -- Moto : prix plafonné sur l'axe Île-de-France ↔ Côte d'Azur (promesse existante).
  if v_gab = 'moto' and secoto_private.plafond_applicable('moto', p_pickup, p_delivery) then
    v_cap := coalesce((b ->> 'moto_plafond_couloir_eur')::numeric, 382) * 100;
    v_client := least(v_client, v_cap::int);
  end if;
  v_pay_c := v_client - secoto_private.marge_v3_cents(v_client);

  return (p_price - 'manual_reason') || jsonb_build_object(
    'client_cents', v_client,
    'partner_cents', v_pay_c,
    'margin_cents', v_client - v_pay_c,
    'collect_cents', v_client,
    'lines', jsonb_build_array(jsonb_build_object(
      'label', format('Transport sur plateau · %s km', replace(trim(trailing '.' from trim(trailing '0' from to_char(v_km, 'FM999990.0'))), '.', ',')),
      'eur', round(v_client / 100.0, 2))),
    'detail', jsonb_build_array(jsonb_build_object(
      'pricing', 'bareme_secoto_v3', 'gabarit', v_gab, 'ajustement', v_ajust,
      'poids_kg', v_poids, 'longueur_m', v_long, 'partner_cents', v_pay_c)));
end;
$$;
revoke all on function secoto_private.bareme_v3(jsonb, jsonb, jsonb, jsonb, numeric) from public, anon, authenticated;

-- Devis : gabarit, poids et longueur obligatoires pour caravane / camping-car,
-- puis barème v3 à la place des tarifs déclarés par les transporteurs.
select secoto_private.mig074_patch(
  'public.secoto_quote_create(uuid,jsonb,jsonb)'::regprocedure,
  '  if jsonb_typeof(v_vehicle -> ''rolling'') <> ''boolean'' then raise exception ''Précisez si le véhicule roule.''; end if;',
  '  if jsonb_typeof(v_vehicle -> ''rolling'') <> ''boolean'' then raise exception ''Précisez si le véhicule roule.''; end if;
  -- 133 : gabarit du barème ; poids et longueur obligatoires pour caravane et camping-car.
  if coalesce(v_vehicle ->> ''gabarit'', '''') not in ('''', ''citadine'', ''berline'', ''grand'', ''utilitaire'', ''moto'', ''caravane'', ''camping_car'', ''poids_lourd'') then
    raise exception ''Type de véhicule invalide.'';
  end if;
  if v_vehicle ->> ''gabarit'' in (''caravane'', ''camping_car'') and (
       coalesce(nullif(v_vehicle ->> ''weight_kg'', '''')::numeric, 0) not between 300 and 20000
       or coalesce(nullif(v_vehicle ->> ''length_m'', '''')::numeric, 0) not between 2 and 20) then
    raise exception ''Indiquez le poids (kg) et la longueur (m) de votre caravane ou camping-car.'';
  end if;');

select secoto_private.mig074_patch(
  'public.secoto_quote_create(uuid,jsonb,jsonb)'::regprocedure,
  '      v_price := secoto_private.market_price(v_price, v_vehicle, v_pickup, v_distance, v_pickup_at, v_delivery);  -- 117',
  '      v_price := secoto_private.market_price(v_price, v_vehicle, v_pickup, v_distance, v_pickup_at, v_delivery);  -- 117
      v_price := secoto_private.bareme_v3(v_price, v_vehicle, v_pickup, v_delivery, v_distance);  -- 133
      v_reason := v_price ->> ''manual_reason'';');

-- Offre Éco d'un devis (null : pas d'Éco pour ce devis).
create or replace function secoto_private.offre_eco_v3(q public.transport_quotes, p_std_client integer)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  b jsonb := secoto_private.bareme_v3_reglages();
  e jsonb := b -> 'eco';
  v_gab text := secoto_private.gabarit_vehicule(q.vehicle);
  v_dep jsonb;
  v_arr jsonb;
  v_km numeric;
  v_pay integer;
  v_client integer;
  v_cap integer;
  v_min_marge integer := round(coalesce((b ->> 'marge_min_eur')::numeric, 75) * 100)::int;
begin
  if v_gab is null or not (coalesce(e -> 'coef', '{}'::jsonb) ? v_gab) then return null; end if;  -- caravane, camping-car…
  if not coalesce((q.vehicle ->> 'rolling')::boolean, true) then return null; end if;
  if secoto_private.od_pays(q.pickup) <> 'FR' or secoto_private.od_pays(q.delivery) <> 'FR' then return null; end if;
  if v_gab = 'moto' and not secoto_private.plafond_applicable('moto', q.pickup, q.delivery) then return null; end if;
  v_dep := secoto_private.ville_eco(q.pickup);
  v_arr := secoto_private.ville_eco(q.delivery);
  if v_dep is null or v_arr is null or v_dep ->> 'nom' = v_arr ->> 'nom' then return null; end if;
  -- Distance entre les deux grandes villes (vol d'oiseau × 1,25 ≈ route).
  v_km := round(secoto_private.km_vol((v_dep ->> 'lat')::numeric, (v_dep ->> 'lng')::numeric,
                                      (v_arr ->> 'lat')::numeric, (v_arr ->> 'lng')::numeric) * 1.25);
  v_pay := round(greatest(coalesce((e ->> 'transporteur_min_eur')::numeric, 150),
                          v_km * coalesce((e ->> 'eur_km')::numeric, 0.45) * coalesce((e -> 'coef' ->> v_gab)::numeric, 1)) * 100)::int;
  v_client := greatest(round(coalesce((e ->> 'client_min_eur')::numeric, 195) * 100)::int,
                       v_pay + v_min_marge,
                       round(v_pay / (1 - coalesce((e ->> 'marge_pct')::numeric, 20) / 100))::int);
  v_cap := round(coalesce((b -> 'gabarits' -> v_gab ->> 'eco_plafond_eur')::numeric, 600) * 100)::int;
  if v_client > v_cap then
    v_client := v_cap;
    v_pay := v_cap - v_min_marge;
  end if;
  if v_pay <= 0 or v_client >= coalesce(p_std_client, 0) then return null; end if;
  return jsonb_build_object(
    'cle', 'eco', 'libelle', 'Éco',
    'client_cents', v_client, 'partenaire_cents', v_pay, 'commission_cents', v_client - v_pay,
    'fenetre_h', coalesce((secoto_private.trois_offres_reglages() -> 'eco' ->> 'fenetre_h')::int, 360),
    'ville_depot', v_dep ->> 'nom', 'ville_retrait', v_arr ->> 'nom', 'km_villes', v_km,
    'regles', format('De ville à ville : vous déposez votre véhicule à %s et le récupérez à %s. Prise en charge sous 15 jours.',
                     v_dep ->> 'nom', v_arr ->> 'nom'),
    'recommande', false);
end;
$$;
revoke all on function secoto_private.offre_eco_v3(public.transport_quotes, integer) from public, anon, authenticated;

-- Trois offres : toujours proposées (plus de seuil de transporteurs).
create or replace function secoto_private.calculer_offres(q public.transport_quotes)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  r jsonb := secoto_private.trois_offres_reglages();
  v_km numeric := (q.route ->> 'distance_km')::numeric;
  v_coef numeric := coalesce((r -> 'express' ->> 'coef')::numeric, 1.30);
  v_std_client integer := q.client_price_cents;
  v_std_pay integer := q.partner_pay_cents;
  v_exp_client integer;
  v_n integer;
  v_eco jsonb;
  v_out jsonb := '[]'::jsonb;
begin
  if not secoto_private.flag('trois_offres') or q.mode <> 'plateau' or q.status <> 'priced'
     or v_std_client is null or v_std_pay is null or coalesce(v_km, 0) <= 0 or (q.vehicle ->> 'class') is null
     or jsonb_array_length(coalesce(q.vehicles, '[]'::jsonb)) > 1
     or coalesce(q.vehicle ->> 'category', 'standard') <> 'standard' then
    return null;
  end if;
  -- Transporteurs vérifiés qui couvrent ce trajet (affiché au client, plus bloquant).
  select count(distinct secoto_private.carrier_rate_owner(a.id)) into v_n
    from public.accounts a
   where a.role::text = 'transporter' and a.deleted_at is null
     and secoto_private.carrier_eligible_for_trip(a.id, q.vehicle, q.pickup, q.pickup_at);

  v_exp_client := round(v_std_client * v_coef)::int;
  v_out := v_out || jsonb_build_array(jsonb_build_object(
    'cle', 'express', 'libelle', 'Express',
    'client_cents', v_exp_client, 'partenaire_cents', round(v_std_pay * v_coef)::int,
    'commission_cents', v_exp_client - round(v_std_pay * v_coef)::int,
    'fenetre_h', coalesce((r -> 'express' ->> 'fenetre_h')::int, 48), 'transporteurs', v_n, 'recommande', false));
  v_out := v_out || jsonb_build_array(jsonb_build_object(
    'cle', 'standard', 'libelle', 'Standard',
    'client_cents', v_std_client, 'partenaire_cents', v_std_pay, 'commission_cents', v_std_client - v_std_pay,
    'fenetre_h', coalesce((r -> 'standard' ->> 'fenetre_h')::int, 120), 'transporteurs', v_n, 'recommande', true));
  if secoto_private.flag('bareme_v3') then
    v_eco := secoto_private.offre_eco_v3(q, v_std_client);
    if v_eco is not null then
      v_out := v_out || jsonb_build_array(v_eco || jsonb_build_object('transporteurs', v_n));
    end if;
  end if;
  return v_out;
end;
$$;
revoke all on function secoto_private.calculer_offres(public.transport_quotes) from public, anon, authenticated;

-- Éco réservée : la mission part de la grande ville de dépôt vers celle de
-- retrait ; les adresses du client restent dans le devis (adresse_client).
select secoto_private.mig074_patch(
  'public.secoto_od_book_offre(uuid,text,uuid)'::regprocedure,
  '  v_res := public.secoto_od_book_quote(p_quote_id, false, p_idempotency_key);',
  '  -- 133 : Éco = de grande ville à grande ville.
  if p_offre = ''eco'' and v_offre ? ''ville_depot'' then
    update public.transport_quotes q
       set pickup = (select jsonb_build_object(''city'', v ->> ''nom'', ''label'', ''Centre de '' || (v ->> ''nom'') || '' (lieu de dépôt à convenir)'',
                                               ''lat'', (v ->> ''lat'')::numeric, ''lng'', (v ->> ''lng'')::numeric, ''country'', ''FR'',
                                               ''postcode'', v ->> ''cp'', ''verified'', true, ''eco'', true, ''adresse_client'', q.pickup)
                       from jsonb_array_elements(secoto_private.bareme_v3_reglages() -> ''eco'' -> ''villes'') v where v ->> ''nom'' = v_offre ->> ''ville_depot''),
           delivery = (select jsonb_build_object(''city'', v ->> ''nom'', ''label'', ''Centre de '' || (v ->> ''nom'') || '' (lieu de retrait à convenir)'',
                                                 ''lat'', (v ->> ''lat'')::numeric, ''lng'', (v ->> ''lng'')::numeric, ''country'', ''FR'',
                                                 ''postcode'', v ->> ''cp'', ''verified'', true, ''eco'', true, ''adresse_client'', q.delivery)
                         from jsonb_array_elements(secoto_private.bareme_v3_reglages() -> ''eco'' -> ''villes'') v where v ->> ''nom'' = v_offre ->> ''ville_retrait'')
     where q.id = p_quote_id and not coalesce((q.pickup ->> ''eco'')::boolean, false);
  end if;
  v_res := public.secoto_od_book_quote(p_quote_id, false, p_idempotency_key);');

notify pgrst, 'reload schema';
