-- ============================================================================
-- SECOTO — MIGRATION 034 : BARÈME COMMERCIAL DU 18/09/2026
-- ----------------------------------------------------------------------------
-- Décisions Nawfal Bouchaib (SECOTO) du 18/09/2026.
--
-- PLATEAU (sous-traitance : SECOTO vend le transport, le transporteur exécute)
--   Prix client au kilomètre :
--     voiture                      1,12 €/km
--     moto                         1,00 €/km, le prix ne dépasse jamais 400 €
--     utilitaire / VL / caravane   1,25 €/km
--   Véhicule non roulant           + 80 € (treuil)
--   Plancher                       115 € (inchangé depuis la migration 009)
--   Rémunération transporteur, JAMAIS affichée au client :
--     voiture 0,97 €/km · moto 0,85 €/km · utilitaire 1,10 €/km · non roulant + 60 €
--
-- CONVOYAGE (par la route, conducteur)
--   Prix client                    1,00 €/km, tout compris, toutes catégories
--   Plancher                       115 €
--   Rémunération convoyeur         0,55 €/km · 0,65 €/km sur utilitaire
--
-- ENCAISSEMENT : SECOTO encaisse la TOTALITÉ du prix client, dans les deux
-- modes, puis reverse le transporteur. Plus aucun paiement direct au partenaire.
--
-- Plafond et plancher s'appliquent au prix client ET à la rémunération, dans la
-- même proportion : la marge ne peut jamais devenir négative sur les extrêmes.
--
-- Additive et rejouable. Les barèmes précédents sont archivés, jamais
-- supprimés : un devis déjà émis garde la version qui l'a produit.
-- ============================================================================

begin;

do $guard$
begin
  if to_regprocedure('secoto_private.price_with_grid(text,jsonb,numeric,jsonb,numeric)') is null then
    raise exception 'Migration 030 requise avant la 034.';
  end if;
end
$guard$;

-- ----------------------------------------------------------------------------
-- 1. MOTEUR DE PRIX
-- ----------------------------------------------------------------------------
-- Deux méthodes cohabitent :
--   pricing_method = 'per_class' : un tarif au km par catégorie (barèmes 034)
--   sinon                        : les paliers historiques (barème 009 archivé)
-- Les devis déjà émis conservent leurs montants : rien n'est recalculé.
create or replace function secoto_private.price_with_grid(
  p_mode text, p jsonb, p_distance_km numeric, p_vehicle jsonb, p_hours_to_pickup numeric
)
returns jsonb language plpgsql immutable set search_path = ''
as $f$
declare
  v_km numeric := round(coalesce(p_distance_km, 0), 1);
  v_class text := coalesce(p_vehicle ->> 'class', '');
  v_rolling boolean := coalesce((p_vehicle ->> 'rolling')::boolean, true);
  v_client numeric := 0;
  v_partner numeric;
  v_margin numeric;
  v_floor numeric := 0;
  v_tier jsonb;
  v_upto numeric;
  v_rate numeric;
  v_lines jsonb := '[]'::jsonb;
  v_urgent_pct numeric := coalesce((p ->> 'urgent_pct')::numeric, 0);
  v_rule jsonb;
  v_client_rate numeric;
  v_partner_rate numeric;
  v_cap numeric;
  v_minimum numeric := coalesce((p ->> 'minimum_eur')::numeric, 0);
  v_capped boolean := false;
  v_nr_client numeric;
  v_nr_partner numeric;
begin
  if v_km <= 0 then
    return jsonb_build_object('manual_reason', 'distance_indisponible');
  end if;
  if not (v_class in (select jsonb_array_elements_text(coalesce(p -> 'auto_vehicle_classes', '[]'::jsonb)))) then
    return jsonb_build_object('manual_reason', 'categorie_vehicule_hors_bareme');
  end if;
  if p ? 'auto_max_km' and v_km > (p ->> 'auto_max_km')::numeric then
    return jsonb_build_object('manual_reason', 'distance_hors_bareme_automatique');
  end if;
  if coalesce(p_vehicle ->> 'category', 'standard') = 'luxury' and not coalesce((p ->> 'luxury_auto')::boolean, false) then
    return jsonb_build_object('manual_reason', 'vehicule_prestige');
  end if;
  if jsonb_typeof(p_vehicle -> 'constraints') = 'array' and jsonb_array_length(p_vehicle -> 'constraints') > 0
     and not coalesce((p ->> 'constraints_auto')::boolean, false) then
    return jsonb_build_object('manual_reason', 'contraintes_particulieres');
  end if;
  if not v_rolling then
    if p_mode = 'convoyage' then
      return jsonb_build_object('manual_reason', 'convoyage_impossible_vehicule_non_roulant');
    elsif not coalesce((p ->> 'non_rolling_auto')::boolean, false) then
      return jsonb_build_object('manual_reason', 'vehicule_non_roulant');
    end if;
  end if;
  if p_hours_to_pickup is not null and p_hours_to_pickup < coalesce((p ->> 'min_notice_hours')::numeric, 0) then
    return jsonb_build_object('manual_reason', 'delai_trop_court');
  end if;

  -- ======== Barème par catégorie (034) ========
  if p ->> 'pricing_method' = 'per_class' then
    v_rule := p -> 'class_rates' -> v_class;
    if v_rule is null then
      return jsonb_build_object('manual_reason', 'categorie_vehicule_hors_bareme');
    end if;
    v_client_rate := (v_rule ->> 'client_eur_per_km')::numeric;
    v_partner_rate := (v_rule ->> 'partner_eur_per_km')::numeric;
    if v_client_rate is null or v_partner_rate is null or v_client_rate <= 0 or v_partner_rate < 0 then
      return jsonb_build_object('manual_reason', 'remuneration_partenaire_non_definie');
    end if;

    v_client := v_km * v_client_rate;
    v_partner := v_km * v_partner_rate;
    v_lines := v_lines || jsonb_build_object(
      'label', format('%s km × %s €/km',
        trim(trailing '.' from to_char(v_km, 'FM999990D9')), to_char(v_client_rate, 'FM990D00')),
      'eur', round(v_client, 2));

    -- Plafond : le prix client ne monte plus, et la rémunération suit la même
    -- proportion (sinon la marge s'effondre sur les longues distances).
    v_cap := (v_rule ->> 'client_cap_eur')::numeric;
    if v_cap is not null and v_client > v_cap then
      v_partner := round(v_cap * v_partner_rate / v_client_rate, 2);
      v_client := v_cap;
      v_capped := true;
      v_lines := v_lines || jsonb_build_object(
        'label', format('Prix plafonné à %s €', to_char(v_cap, 'FM999990D00')), 'eur', v_cap);
    end if;

    -- Plancher : même logique, la part transporteur suit le rapport de sa catégorie.
    if v_client < v_minimum then
      v_partner := greatest(v_partner, round(v_minimum * v_partner_rate / v_client_rate, 2));
      v_client := v_minimum;
      v_lines := v_lines || jsonb_build_object('label', 'Forfait minimum', 'eur', v_minimum);
    end if;

    -- Véhicule non roulant : supplément forfaitaire (treuil, manutention).
    if not v_rolling then
      v_nr_client := coalesce((p ->> 'non_rolling_client_eur')::numeric, 0);
      v_nr_partner := coalesce((p ->> 'non_rolling_partner_eur')::numeric, 0);
      if v_nr_partner >= v_nr_client then
        return jsonb_build_object('manual_reason', 'supplement_non_roulant_non_defini');
      end if;
      v_client := v_client + v_nr_client;
      v_partner := v_partner + v_nr_partner;
      v_lines := v_lines || jsonb_build_object(
        'label', 'Véhicule non roulant (treuil)', 'eur', v_nr_client);
    end if;

    if v_urgent_pct > 0 and p_hours_to_pickup is not null
       and p_hours_to_pickup < coalesce((p ->> 'urgent_threshold_hours')::numeric, 24) then
      v_lines := v_lines || jsonb_build_object('label', format('Urgence (+%s %%)', v_urgent_pct), 'eur', round(v_client * v_urgent_pct / 100, 2));
      v_client := v_client * (1 + v_urgent_pct / 100);
      v_partner := v_partner * (1 + v_urgent_pct / 100);
    end if;

    v_client := round(v_client, 2);
    v_partner := round(v_partner, 2);
    v_margin := round(v_client - v_partner, 2);

    if v_margin < v_client * coalesce((p ->> 'min_margin_pct')::numeric, 0) / 100 then
      return jsonb_build_object('manual_reason', 'marge_insuffisante');
    end if;

    -- SECOTO encaisse la totalité du prix client, dans les deux modes.
    return jsonb_build_object(
      'client_cents', (v_client * 100)::integer,
      'partner_cents', (v_partner * 100)::integer,
      'margin_cents', (v_margin * 100)::integer,
      'collect_cents', (v_client * 100)::integer,
      'transport_direct_cents', 0,
      'capped', v_capped,
      'lines', v_lines,
      'included', coalesce(p -> 'included', '[]'::jsonb),
      'excluded', coalesce(p -> 'excluded', '[]'::jsonb));
  end if;

  -- ======== Paliers historiques (barèmes archivés) ========
  if p ->> 'tier_method' = 'global' then
    for v_tier in select value from jsonb_array_elements(p -> 'tiers') loop
      v_upto := (v_tier ->> 'up_to_km')::numeric;
      if v_upto is null or v_km <= v_upto then
        v_rate := (v_tier ->> 'eur_per_km')::numeric;
        v_client := v_km * v_rate;
        v_lines := v_lines || jsonb_build_object('label', format('%s km × %s €/km', v_km, v_rate), 'eur', round(v_client, 2));
        exit;
      end if;
    end loop;
  else
    v_floor := 0;
    for v_tier in select value from jsonb_array_elements(p -> 'tiers') loop
      exit when v_km <= v_floor;
      v_upto := (v_tier ->> 'up_to_km')::numeric;
      v_rate := (v_tier ->> 'eur_per_km')::numeric;
      v_client := v_client + (least(v_km, coalesce(v_upto, v_km)) - v_floor) * v_rate;
      v_lines := v_lines || jsonb_build_object(
        'label', format('%s à %s km × %s €/km', v_floor, least(v_km, coalesce(v_upto, v_km)), v_rate),
        'eur', round((least(v_km, coalesce(v_upto, v_km)) - v_floor) * v_rate, 2));
      v_floor := coalesce(v_upto, v_km);
    end loop;
  end if;

  if v_client < v_minimum then
    v_lines := v_lines || jsonb_build_object('label', 'Forfait minimum', 'eur', v_minimum);
    v_client := v_minimum;
  end if;

  if v_urgent_pct > 0 and p_hours_to_pickup is not null
     and p_hours_to_pickup < coalesce((p ->> 'urgent_threshold_hours')::numeric, 24) then
    v_lines := v_lines || jsonb_build_object('label', format('Urgence (+%s %%)', v_urgent_pct), 'eur', round(v_client * v_urgent_pct / 100, 2));
    v_client := v_client * (1 + v_urgent_pct / 100);
  end if;
  v_client := round(v_client, 2);

  if p -> 'partner_eur_per_km_by_class' ? v_class then
    v_partner := v_km * (p -> 'partner_eur_per_km_by_class' ->> v_class)::numeric;
  elsif p ? 'partner_eur_per_km' then
    v_partner := v_km * (p ->> 'partner_eur_per_km')::numeric
      + v_km * coalesce((p ->> 'approach_eur_per_km')::numeric, 0)
      + coalesce((p ->> 'return_positioning_eur')::numeric, 0);
  elsif p ? 'partner_share_pct' then
    v_partner := v_client * (p ->> 'partner_share_pct')::numeric / 100;
  else
    return jsonb_build_object('manual_reason', 'remuneration_partenaire_non_definie');
  end if;
  v_partner := round(greatest(v_partner, coalesce((p ->> 'partner_minimum_eur')::numeric, 0)), 2);
  v_margin := round(v_client - v_partner, 2);

  if v_margin < v_client * coalesce((p ->> 'min_margin_pct')::numeric, 0) / 100 then
    return jsonb_build_object('manual_reason', 'marge_insuffisante');
  end if;

  return jsonb_build_object(
    'client_cents', (v_client * 100)::integer,
    'partner_cents', (v_partner * 100)::integer,
    'margin_cents', (v_margin * 100)::integer,
    'collect_cents', (v_client * 100)::integer,
    'transport_direct_cents', 0,
    'capped', false,
    'lines', v_lines,
    'included', coalesce(p -> 'included', '[]'::jsonb),
    'excluded', coalesce(p -> 'excluded', '[]'::jsonb));
end;
$f$;

-- ----------------------------------------------------------------------------
-- 2. VALIDATION DES BARÈMES — accepte les deux méthodes
-- ----------------------------------------------------------------------------
create or replace function secoto_private.validate_grid_params(p_mode text, p jsonb)
returns void language plpgsql immutable set search_path = ''
as $f$
declare v_tier jsonb; v_prev numeric := 0; v_class text; v_rule jsonb;
begin
  if coalesce((p ->> 'min_margin_pct')::numeric, -1) < 0 or (p ->> 'min_margin_pct')::numeric >= 100 then
    raise exception 'Barème invalide : min_margin_pct requis (0 à 99).';
  end if;

  if p ->> 'pricing_method' = 'per_class' then
    if jsonb_typeof(p -> 'class_rates') <> 'object' or p -> 'class_rates' = '{}'::jsonb then
      raise exception 'Barème invalide : class_rates doit décrire au moins une catégorie.';
    end if;
    for v_class in select jsonb_object_keys(p -> 'class_rates') loop
      if v_class not in ('voiture', 'utilitaire', 'moto', 'autre') then
        raise exception 'Barème invalide : catégorie inconnue %.', v_class;
      end if;
      v_rule := p -> 'class_rates' -> v_class;
      if coalesce((v_rule ->> 'client_eur_per_km')::numeric, 0) <= 0
         or (v_rule ->> 'client_eur_per_km')::numeric > 20 then
        raise exception 'Barème invalide : tarif client hors limites pour %.', v_class;
      end if;
      if (v_rule ->> 'partner_eur_per_km') is null
         or (v_rule ->> 'partner_eur_per_km')::numeric < 0
         or (v_rule ->> 'partner_eur_per_km')::numeric >= (v_rule ->> 'client_eur_per_km')::numeric then
        raise exception 'Barème invalide : rémunération transporteur absente ou supérieure au prix client pour %.', v_class;
      end if;
      if (v_rule ->> 'client_cap_eur') is not null and (v_rule ->> 'client_cap_eur')::numeric <= coalesce((p ->> 'minimum_eur')::numeric, 0) then
        raise exception 'Barème invalide : plafond inférieur au plancher pour %.', v_class;
      end if;
    end loop;
    -- Le supplément non roulant ne doit jamais coûter plus qu'il ne rapporte.
    if coalesce((p ->> 'non_rolling_auto')::boolean, false)
       and coalesce((p ->> 'non_rolling_partner_eur')::numeric, 0) >= coalesce((p ->> 'non_rolling_client_eur')::numeric, 0) then
      raise exception 'Barème invalide : supplément non roulant client supérieur à la part transporteur requis.';
    end if;
    return;
  end if;

  if jsonb_typeof(p -> 'tiers') <> 'array' or jsonb_array_length(p -> 'tiers') = 0 then
    raise exception 'Barème invalide : au moins une tranche est requise.';
  end if;
  if coalesce(p ->> 'tier_method', '') not in ('cumulative', 'global') then
    raise exception 'Barème invalide : tier_method doit valoir cumulative ou global.';
  end if;
  for v_tier in select value from jsonb_array_elements(p -> 'tiers') loop
    if (v_tier ->> 'eur_per_km') is null or (v_tier ->> 'eur_per_km')::numeric <= 0 or (v_tier ->> 'eur_per_km')::numeric > 20 then
      raise exception 'Barème invalide : tarif au km hors limites.';
    end if;
    if v_tier ->> 'up_to_km' is not null then
      if (v_tier ->> 'up_to_km')::numeric <= v_prev then raise exception 'Barème invalide : tranches non croissantes.'; end if;
      v_prev := (v_tier ->> 'up_to_km')::numeric;
    end if;
  end loop;
  if (p -> 'tiers' -> (jsonb_array_length(p -> 'tiers') - 1) ->> 'up_to_km') is not null then
    raise exception 'Barème invalide : la dernière tranche doit être ouverte (up_to_km = null).';
  end if;
end;
$f$;

-- L'activation exige une rémunération transporteur définie, quelle que soit la méthode.
create or replace function public.secoto_admin_activate_grid(p_grid_id uuid)
returns jsonb language plpgsql volatile security definer set search_path = ''
as $f$
declare v_row public.pricing_grids%rowtype;
begin
  perform secoto_private.assert_admin();
  select * into v_row from public.pricing_grids g where g.id = p_grid_id for update;
  if not found then raise exception 'Barème introuvable.'; end if;
  perform secoto_private.validate_grid_params(v_row.mode, v_row.params);
  if not (v_row.params ? 'partner_eur_per_km'
          or v_row.params ? 'partner_share_pct'
          or v_row.params ->> 'pricing_method' = 'per_class') then
    raise exception 'Activation refusée : la rémunération transporteur n''est pas définie dans ce barème.';
  end if;
  perform pg_advisory_xact_lock(hashtext('pricing_grid:' || v_row.mode));
  update public.pricing_grids set status = 'archived' where mode = v_row.mode and status = 'active' and id <> v_row.id;
  update public.pricing_grids set status = 'active', activated_at = now(), activated_by = auth.uid()
   where id = v_row.id returning * into v_row;
  perform secoto_private.audit('pricing_grid_activated', 'pricing_grid', v_row.id::text, jsonb_build_object('mode', v_row.mode, 'version', v_row.version));
  return to_jsonb(v_row);
end;
$f$;

-- ----------------------------------------------------------------------------
-- 3. BARÈME PLATEAU — ACTIF
-- ----------------------------------------------------------------------------
do $plateau$
declare v_id uuid;
begin
  if exists (select 1 from public.pricing_grids g where g.mode = 'plateau' and g.source_note like 'Barème plateau SECOTO du 18/09/2026%') then
    return;
  end if;
  -- L'index d'unicité n'autorise qu'un barème actif par mode : on archive d'abord.
  update public.pricing_grids set status = 'archived' where mode = 'plateau' and status = 'active';
  insert into public.pricing_grids(mode, version, status, params, source_note, activated_at)
  values ('plateau',
    coalesce((select max(g.version) from public.pricing_grids g where g.mode = 'plateau'), 0) + 1,
    'active',
    jsonb_build_object(
      'engine', 'secoto-pricing-2',
      'pricing_method', 'per_class',
      'class_rates', jsonb_build_object(
        'voiture',    jsonb_build_object('client_eur_per_km', 1.12, 'partner_eur_per_km', 0.97),
        'moto',       jsonb_build_object('client_eur_per_km', 1.00, 'partner_eur_per_km', 0.85, 'client_cap_eur', 400),
        'utilitaire', jsonb_build_object('client_eur_per_km', 1.25, 'partner_eur_per_km', 1.10)),
      'minimum_eur', 115,
      'non_rolling_auto', true,
      'non_rolling_client_eur', 80,
      'non_rolling_partner_eur', 60,
      'urgent_pct', 0,
      'urgent_threshold_hours', 24,
      'min_notice_hours', 12,
      'auto_vehicle_classes', jsonb_build_array('voiture', 'moto', 'utilitaire'),
      'auto_max_km', 1500,
      'luxury_auto', false,
      'constraints_auto', false,
      'min_margin_pct', 10,
      'included', jsonb_build_array(
        'Transporteur plateau vérifié et assuré',
        'Chargement, sanglage et déchargement',
        'Carburant et péages inclus',
        'État des lieux au départ et à la livraison (photos)',
        'Bon de livraison et suivi dans l''application'),
      'excluded', jsonb_build_array(
        'Véhicule de prestige ou transport en camion fermé : devis personnalisé',
        'Accès impossible au camion plateau : devis personnalisé')),
    'Barème plateau SECOTO du 18/09/2026 — voiture 1,12 €/km, moto 1,00 €/km plafonnée à 400 €, utilitaire 1,25 €/km, non roulant + 80 €, plancher 115 €. Rémunération transporteur 0,97 / 0,85 / 1,10 €/km, non roulant + 60 €.',
    now())
  returning id into v_id;
end
$plateau$;

-- ----------------------------------------------------------------------------
-- 4. BARÈME CONVOYAGE — ACTIF (forfait 1,00 €/km tout compris)
-- ----------------------------------------------------------------------------
do $convoyage$
declare v_id uuid;
begin
  if exists (select 1 from public.pricing_grids g where g.mode = 'convoyage' and g.source_note like 'Barème convoyage SECOTO du 18/09/2026%') then
    return;
  end if;
  -- L'index d'unicité n'autorise qu'un barème actif par mode : on archive d'abord.
  update public.pricing_grids set status = 'archived' where mode = 'convoyage' and status = 'active';
  insert into public.pricing_grids(mode, version, status, params, source_note, activated_at)
  values ('convoyage',
    coalesce((select max(g.version) from public.pricing_grids g where g.mode = 'convoyage'), 0) + 1,
    'active',
    jsonb_build_object(
      'engine', 'secoto-pricing-2',
      'pricing_method', 'per_class',
      'class_rates', jsonb_build_object(
        'voiture',    jsonb_build_object('client_eur_per_km', 1.00, 'partner_eur_per_km', 0.55),
        'moto',       jsonb_build_object('client_eur_per_km', 1.00, 'partner_eur_per_km', 0.55),
        'utilitaire', jsonb_build_object('client_eur_per_km', 1.00, 'partner_eur_per_km', 0.65)),
      'minimum_eur', 115,
      'non_rolling_auto', false,
      'urgent_pct', 0,
      'urgent_threshold_hours', 24,
      'min_notice_hours', 12,
      'auto_vehicle_classes', jsonb_build_array('voiture', 'moto', 'utilitaire'),
      'auto_max_km', 1500,
      'luxury_auto', false,
      'constraints_auto', false,
      'min_margin_pct', 10,
      'included', jsonb_build_array(
        'Convoyeur vérifié et assuré',
        'Carburant et péages inclus',
        'État des lieux au départ et à la livraison (photos)',
        'Bon de livraison et suivi dans l''application'),
      'excluded', jsonb_build_array(
        'Véhicule non roulant : convoyage impossible, choisissez le plateau',
        'Véhicule de prestige : devis personnalisé')),
    'Barème convoyage SECOTO du 18/09/2026 — forfait 1,00 €/km tout compris (carburant et péages inclus), plancher 115 €. Rémunération convoyeur 0,55 €/km, portée à 0,65 €/km sur utilitaire, camionnette et caravane. Remplace les paliers 1,00/0,90/0,88 de la migration 009.',
    now())
  returning id into v_id;
end
$convoyage$;

-- ----------------------------------------------------------------------------
-- 5. DEVIS MANUEL ADMIN — SECOTO encaisse aussi la totalité
-- ----------------------------------------------------------------------------
update public.transport_quotes
   set collect_cents = client_price_cents, transport_direct_cents = 0
 where status in ('priced', 'manual_priced')
   and (collect_cents is distinct from client_price_cents or transport_direct_cents <> 0);

-- ----------------------------------------------------------------------------
-- 6. CONTRÔLE : les prix annoncés sont bien ceux qui sortent du moteur
-- ----------------------------------------------------------------------------
do $verif$
declare
  p jsonb;
  v jsonb;
  v_voiture jsonb := jsonb_build_object('class', 'voiture', 'category', 'standard', 'rolling', true);
  v_moto jsonb := jsonb_build_object('class', 'moto', 'category', 'standard', 'rolling', true);
  v_util jsonb := jsonb_build_object('class', 'utilitaire', 'category', 'standard', 'rolling', true);
  v_nr jsonb := jsonb_build_object('class', 'voiture', 'category', 'standard', 'rolling', false);
begin
  select g.params into p from public.pricing_grids g where g.mode = 'plateau' and g.status = 'active';

  v := secoto_private.price_with_grid('plateau', p, 500, v_voiture, 72);
  if (v ->> 'client_cents')::int <> 56000 or (v ->> 'partner_cents')::int <> 48500 then
    raise exception 'Contrôle voiture 500 km : % au lieu de 560,00 € / 485,00 €', v;
  end if;
  if (v ->> 'collect_cents')::int <> 56000 or (v ->> 'transport_direct_cents')::int <> 0 then
    raise exception 'Contrôle encaissement : SECOTO doit encaisser la totalité — %', v;
  end if;

  v := secoto_private.price_with_grid('plateau', p, 300, v_moto, 72);
  if (v ->> 'client_cents')::int <> 30000 or (v ->> 'partner_cents')::int <> 25500 then
    raise exception 'Contrôle moto 300 km : % au lieu de 300,00 € / 255,00 €', v;
  end if;

  v := secoto_private.price_with_grid('plateau', p, 800, v_moto, 72);
  if (v ->> 'client_cents')::int <> 40000 or (v ->> 'partner_cents')::int <> 34000 then
    raise exception 'Contrôle moto 800 km (plafond) : % au lieu de 400,00 € / 340,00 €', v;
  end if;

  v := secoto_private.price_with_grid('plateau', p, 200, v_util, 72);
  if (v ->> 'client_cents')::int <> 25000 or (v ->> 'partner_cents')::int <> 22000 then
    raise exception 'Contrôle utilitaire 200 km : % au lieu de 250,00 € / 220,00 €', v;
  end if;

  v := secoto_private.price_with_grid('plateau', p, 50, v_voiture, 72);
  if (v ->> 'client_cents')::int <> 11500 or (v ->> 'partner_cents')::int <> 9960 then
    raise exception 'Contrôle plancher 50 km : % au lieu de 115,00 € / 99,60 €', v;
  end if;

  v := secoto_private.price_with_grid('plateau', p, 500, v_nr, 72);
  if (v ->> 'client_cents')::int <> 64000 or (v ->> 'partner_cents')::int <> 54500 then
    raise exception 'Contrôle non roulant 500 km : % au lieu de 640,00 € / 545,00 €', v;
  end if;

  select g.params into p from public.pricing_grids g where g.mode = 'convoyage' and g.status = 'active';

  v := secoto_private.price_with_grid('convoyage', p, 400, v_voiture, 72);
  if (v ->> 'client_cents')::int <> 40000 or (v ->> 'partner_cents')::int <> 22000 then
    raise exception 'Contrôle convoyage 400 km : % au lieu de 400,00 € / 220,00 €', v;
  end if;

  v := secoto_private.price_with_grid('convoyage', p, 400, v_util, 72);
  if (v ->> 'client_cents')::int <> 40000 or (v ->> 'partner_cents')::int <> 26000 then
    raise exception 'Contrôle convoyage utilitaire 400 km : % au lieu de 400,00 € / 260,00 €', v;
  end if;

  v := secoto_private.price_with_grid('convoyage', p, 50, v_voiture, 72);
  if (v ->> 'client_cents')::int <> 11500 or (v ->> 'partner_cents')::int <> 6325 then
    raise exception 'Contrôle plancher convoyage 50 km : % au lieu de 115,00 € / 63,25 €', v;
  end if;

  v := secoto_private.price_with_grid('convoyage', p, 400, v_nr, 72);
  if v ->> 'manual_reason' <> 'convoyage_impossible_vehicule_non_roulant' then
    raise exception 'Contrôle convoyage non roulant : le moteur doit refuser — %', v;
  end if;
end
$verif$;

notify pgrst, 'reload schema';
commit;
