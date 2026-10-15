-- ============================================================================
-- SECOTO — MIGRATION 092 : 2e VÉHICULE SUR LE MÊME PLATEAU À −25 %
-- ----------------------------------------------------------------------------
-- Décision de Nawfal du 15/10/2026 (remplace la règle de groupage de 058).
--
-- Constat : un client qui transporte 2 véhicules payait presque le double
-- (Benissa → Saint-Germain-lès-Arpajon : 3 424,60 € pour un Expert + un Q5),
-- car le transporteur était payé plein tarif pour chaque véhicule alors qu'il
-- ne fait qu'un trajet. Le marché pratique −20 à −30 % en groupage.
--
-- NOUVELLE RÈGLE, en PLATEAU, à partir de 2 véhicules :
--   - le véhicule le plus cher est au plein tarif (forfait minimum compris) ;
--   - chaque véhicule en plus : −25 % pour le client ET −25 % pour le
--     transporteur, sur la part transport (km, plafond moto compris). Le
--     supplément non roulant (treuil) reste entier : c'est un vrai travail en
--     plus, véhicule par véhicule ;
--   - SECOTO gagne TOUJOURS : chaque véhicule en plus garde au moins la marge
--     minimale du barème (min_margin_pct, 10 % par défaut). Si une grille
--     réglait des pourcentages qui la feraient passer dessous, le prix client
--     de ce véhicule est relevé juste ce qu'il faut ;
--   - le transporteur reste gagnant : pour un seul trajet il touche le plein
--     tarif du 1er véhicule plus 75 % de chaque véhicule en plus.
--
-- Le CONVOYAGE ne change pas : un convoyeur par véhicule, aucune remise.
-- Réglable dans la grille plateau, sans retoucher cette fonction :
--   group_extra_client_pct (25), group_extra_partner_pct (25),
--   group_max_vehicles (3).
--
-- Sortie identique à 058 (mêmes clés) : la création des missions par véhicule
-- (059) et l'écran client continuent de fonctionner sans changement.
-- Aucun devis déjà émis n'est recalculé. Aucune policy touchée. Rejouable.
-- ============================================================================

create or replace function secoto_private.price_group_with_grid(
  p_mode text,
  p jsonb,
  p_distance_km numeric,
  p_vehicles jsonb,
  p_hours_to_pickup numeric
)
returns jsonb language plpgsql immutable set search_path = ''
as $f$
declare
  v_max          integer := coalesce((p ->> 'group_max_vehicles')::integer, 3);
  v_pct_client   numeric := coalesce((p ->> 'group_extra_client_pct')::numeric, 25);
  v_pct_partner  numeric := coalesce((p ->> 'group_extra_partner_pct')::numeric, 25);
  v_marge_min    numeric := greatest(coalesce((p ->> 'min_margin_pct')::numeric, 10), 0);
  v_nb           integer;
  v_rang         integer;
  v_principal    integer := 1;
  v_meilleur     integer := -1;
  v_vehicule     jsonb;
  v_groupe       boolean;
  v_params_tete  jsonb;
  v_params_suite jsonb;
  v_unitaire     jsonb;
  v_roulant      jsonb;
  v_cli          integer;
  v_par          integer;
  v_red_cli      integer;
  v_red_par      integer;
  v_client       integer := 0;
  v_partner      integer := 0;
  v_remise       integer := 0;
  v_detail       jsonb := '[]'::jsonb;
  v_lignes       jsonb := '[]'::jsonb;
begin
  if jsonb_typeof(p_vehicles) <> 'array' then
    return jsonb_build_object('manual_reason', 'liste_vehicules_invalide');
  end if;

  v_nb := jsonb_array_length(p_vehicles);
  if v_nb < 1 then
    return jsonb_build_object('manual_reason', 'aucun_vehicule');
  end if;
  if v_nb > v_max then
    return jsonb_build_object('manual_reason', 'trop_de_vehicules');
  end if;

  -- Un seul véhicule : rien ne change, on délègue tel quel.
  if v_nb = 1 then
    v_unitaire := secoto_private.price_with_grid(p_mode, p, p_distance_km, p_vehicles -> 0, p_hours_to_pickup);
    if v_unitaire ? 'manual_reason' then
      return v_unitaire;
    end if;
    return v_unitaire || jsonb_build_object('vehicules', 1, 'remise_groupage_cents', 0);
  end if;

  if v_pct_client < 0 or v_pct_client >= 100 or v_pct_partner < 0 or v_pct_partner >= 100 or v_marge_min >= 100 then
    return jsonb_build_object('manual_reason', 'reglage_groupage_invalide');
  end if;

  v_groupe := (p_mode = 'plateau');
  -- Le véhicule de tête porte le forfait minimum ; le seuil de marge est contrôlé
  -- plus bas, véhicule par véhicule, après la remise.
  v_params_tete := case when v_groupe then p || jsonb_build_object('min_margin_pct', 0) else p end;
  -- Véhicules suivants : pas de second forfait minimum sur le même camion.
  v_params_suite := p || jsonb_build_object('minimum_eur', 0, 'min_margin_pct', 0);

  -- Plateau : le véhicule le plus cher est la tête (plein tarif). Convoyage : le
  -- premier, comme avant.
  if v_groupe then
    v_rang := 0;
    for v_vehicule in select value from jsonb_array_elements(p_vehicles) loop
      v_rang := v_rang + 1;
      v_unitaire := secoto_private.price_with_grid(p_mode, v_params_tete, p_distance_km, v_vehicule, p_hours_to_pickup);
      if v_unitaire ? 'manual_reason' then
        return v_unitaire;
      end if;
      if (v_unitaire ->> 'client_cents')::integer > v_meilleur then
        v_meilleur := (v_unitaire ->> 'client_cents')::integer;
        v_principal := v_rang;
      end if;
    end loop;
  end if;

  v_rang := 0;
  for v_vehicule in select value from jsonb_array_elements(p_vehicles) loop
    v_rang := v_rang + 1;
    v_unitaire := secoto_private.price_with_grid(
      p_mode,
      case when v_rang = v_principal then v_params_tete else v_params_suite end,
      p_distance_km, v_vehicule, p_hours_to_pickup);
    if v_unitaire ? 'manual_reason' then
      return v_unitaire;
    end if;

    v_cli := (v_unitaire ->> 'client_cents')::integer;
    v_par := (v_unitaire ->> 'partner_cents')::integer;
    v_red_cli := 0;
    v_red_par := 0;

    if v_groupe and v_rang <> v_principal then
      -- La remise porte sur la part transport : même véhicule, supposé roulant
      -- (le supplément non roulant reste entier).
      v_roulant := secoto_private.price_with_grid(
        p_mode, v_params_suite, p_distance_km,
        v_vehicule || jsonb_build_object('rolling', true), p_hours_to_pickup);
      if v_roulant ? 'manual_reason' then
        return v_roulant;
      end if;
      v_red_cli := round((v_roulant ->> 'client_cents')::numeric * v_pct_client / 100)::integer;
      v_red_par := round((v_roulant ->> 'partner_cents')::numeric * v_pct_partner / 100)::integer;

      -- SECOTO gagne toujours : la marge de ce véhicule ne descend jamais sous le
      -- seuil du barème. Si besoin, la remise client est réduite.
      if (v_cli - v_red_cli) - (v_par - v_red_par) < ceil((v_cli - v_red_cli) * v_marge_min / 100) then
        v_red_cli := greatest(0, v_cli - ceil((v_par - v_red_par) / (1 - v_marge_min / 100))::integer);
      end if;
    end if;

    v_client  := v_client  + v_cli - v_red_cli;
    v_partner := v_partner + v_par - v_red_par;
    v_remise  := v_remise  + v_red_cli;

    v_lignes := v_lignes || jsonb_build_object(
      'label', format('Véhicule %s%s', v_rang,
        case when coalesce(v_vehicule ->> 'model', '') = '' then ''
             else ' - ' || left(v_vehicule ->> 'model', 60) end),
      'eur', round(v_cli / 100.0, 2));

    v_detail := v_detail || jsonb_build_object(
      'rang',          v_rang,
      'class',         coalesce(v_vehicule ->> 'class', ''),
      'principal',     v_rang = v_principal,
      'client_cents',  v_cli - v_red_cli,
      'partner_cents', v_par - v_red_par,
      'remise_cents',  v_red_cli,
      'remise_transporteur_cents', v_red_par,
      'capped',        coalesce((v_unitaire ->> 'capped')::boolean, false),
      'lines',         v_unitaire -> 'lines');
  end loop;

  if v_remise > 0 then
    v_lignes := v_lignes || jsonb_build_object(
      'label', case when v_nb = 2
                    then format('Remise 2e véhicule sur le même plateau (−%s %%)', trim(trailing '.' from trim(trailing '0' from v_pct_client::text)))
                    else format('Remise véhicules supplémentaires (−%s %%)', trim(trailing '.' from trim(trailing '0' from v_pct_client::text))) end,
      'eur', -round(v_remise / 100.0, 2));
  end if;

  -- Garde-fou absolu : une commande ne peut jamais coûter plus qu'elle ne rapporte.
  if v_client <= v_partner then
    return jsonb_build_object('manual_reason', 'marge_negative_groupage');
  end if;

  return jsonb_build_object(
    'vehicules',              v_nb,
    'client_cents',           v_client,
    'partner_cents',          v_partner,
    'margin_cents',           v_client - v_partner,
    'collect_cents',          v_client,
    'transport_direct_cents', 0,
    'remise_groupage_cents',  v_remise,
    'lines',                  v_lignes,
    'capped',                 exists (
      select 1 from jsonb_array_elements(v_detail) d
      where coalesce((d.value ->> 'capped')::boolean, false)),
    'detail',                 v_detail,
    'included',               coalesce(p -> 'included', '[]'::jsonb),
    'excluded',               coalesce(p -> 'excluded', '[]'::jsonb));
end;
$f$;

comment on function secoto_private.price_group_with_grid(text, jsonb, numeric, jsonb, numeric) is
  'Tarife plusieurs véhicules sur un même trajet (092). Plateau : le véhicule le plus cher '
  'au plein tarif, chaque véhicule en plus −25 % client et −25 % transporteur sur la part '
  'transport (non roulant entier), marge minimale garantie par véhicule. Convoyage : plein tarif.';

revoke all on function secoto_private.price_group_with_grid(text, jsonb, numeric, jsonb, numeric) from public, anon, authenticated;

-- ============================================================================
-- CONTRÔLES BLOQUANTS — sur la grille plateau ACTIVE (voiture 1,20 / 1,00,
-- moto 1,00 / 0,85 plafonnée 382 / 300, utilitaire 1,25 / 1,10, non roulant
-- 80 / 60). Si un montant diffère, RIEN n'est appliqué.
-- ============================================================================
do $controles$
declare
  v_p   jsonb;
  v_c   jsonb;
  v_r   jsonb;
  v_vt  jsonb := jsonb_build_object('class', 'voiture', 'category', 'standard', 'rolling', true, 'constraints', '[]'::jsonb);
  v_mo  jsonb := jsonb_build_object('class', 'moto', 'category', 'standard', 'rolling', true, 'constraints', '[]'::jsonb);
  v_ut  jsonb := jsonb_build_object('class', 'utilitaire', 'category', 'standard', 'rolling', true, 'constraints', '[]'::jsonb);
  v_nr  jsonb := jsonb_build_object('class', 'voiture', 'category', 'standard', 'rolling', false, 'constraints', '[]'::jsonb);
  v_bareme_ok boolean;
begin
  select params into v_p from public.pricing_grids where mode = 'plateau' and status = 'active';
  select params into v_c from public.pricing_grids where mode = 'convoyage' and status = 'active';
  if v_p is null or v_c is null then
    raise notice '092 : pas de grille active, contrôles chiffrés ignorés (base vide).';
    return;
  end if;
  v_bareme_ok := (v_p -> 'class_rates' -> 'voiture' ->> 'client_eur_per_km')::numeric = 1.20
              and (v_p -> 'class_rates' -> 'voiture' ->> 'partner_eur_per_km')::numeric = 1.00
              and (v_p -> 'class_rates' -> 'utilitaire' ->> 'client_eur_per_km')::numeric = 1.25
              and (v_p -> 'class_rates' -> 'utilitaire' ->> 'partner_eur_per_km')::numeric = 1.10
              and (v_p ->> 'non_rolling_client_eur')::numeric = 80
              and (v_p ->> 'non_rolling_partner_eur')::numeric = 60;
  if not v_bareme_ok then
    raise notice '092 : la grille active diffère du barème du 15/10 ; contrôles chiffrés ignorés.';
    return;
  end if;

  -- 1. Un véhicule : inchangé.
  v_r := secoto_private.price_group_with_grid('plateau', v_p, 500, jsonb_build_array(v_vt), 72);
  if (v_r ->> 'client_cents')::int <> 60000 or (v_r ->> 'partner_cents')::int <> 50000 then
    raise exception '092 : 1 voiture 500 km = % / % (attendu 60000 / 50000)', v_r ->> 'client_cents', v_r ->> 'partner_cents';
  end if;

  -- 2. Deux voitures 500 km : 600 + 450 client, 500 + 375 transporteur.
  v_r := secoto_private.price_group_with_grid('plateau', v_p, 500, jsonb_build_array(v_vt, v_vt), 72);
  if (v_r ->> 'client_cents')::int <> 105000 or (v_r ->> 'partner_cents')::int <> 87500
     or (v_r ->> 'remise_groupage_cents')::int <> 15000 then
    raise exception '092 : 2 voitures 500 km = % / % remise % (attendu 105000 / 87500 / 15000)',
      v_r ->> 'client_cents', v_r ->> 'partner_cents', v_r ->> 'remise_groupage_cents';
  end if;

  -- 3. Benissa : Expert (utilitaire, le plus cher, plein tarif) + Q5, 1463,5 km.
  v_r := secoto_private.price_group_with_grid('plateau', v_p, 1463.5, jsonb_build_array(v_ut, v_vt), 72);
  if (v_r ->> 'client_cents')::int <> 314653 or (v_r ->> 'partner_cents')::int <> 270747 then
    raise exception '092 : Benissa = % / % (attendu 314653 / 270747)', v_r ->> 'client_cents', v_r ->> 'partner_cents';
  end if;

  -- 4. Ordre inversé : même prix (le plus cher reste la tête).
  v_r := secoto_private.price_group_with_grid('plateau', v_p, 1463.5, jsonb_build_array(v_vt, v_ut), 72);
  if (v_r ->> 'client_cents')::int <> 314653 or (v_r -> 'detail' -> 1 ->> 'principal')::boolean is not true then
    raise exception '092 : ordre inversé = % (attendu 314653, utilitaire en tête)', v_r ->> 'client_cents';
  end if;

  -- 5. Voiture + voiture non roulante : la non roulante (680) est en tête, la
  --    roulante à −25 % (450) : 1130 € client, 560 + 375 = 935 € transporteur.
  v_r := secoto_private.price_group_with_grid('plateau', v_p, 500, jsonb_build_array(v_vt, v_nr), 72);
  if (v_r ->> 'client_cents')::int <> 113000 or (v_r ->> 'partner_cents')::int <> 93500 then
    raise exception '092 : voiture + non roulant = % / % (attendu 113000 / 93500)', v_r ->> 'client_cents', v_r ->> 'partner_cents';
  end if;
  --    Deux non roulantes : le treuil reste entier sur la seconde (680 + 450 + 80).
  v_r := secoto_private.price_group_with_grid('plateau', v_p, 500, jsonb_build_array(v_nr, v_nr), 72);
  if (v_r ->> 'client_cents')::int <> 121000 or (v_r ->> 'partner_cents')::int <> 99500 then
    raise exception '092 : 2 non roulantes = % / % (attendu 121000 / 99500)', v_r ->> 'client_cents', v_r ->> 'partner_cents';
  end if;

  -- 6. Deux motos 500 km : plafond 382 / 300 avant la remise.
  v_r := secoto_private.price_group_with_grid('plateau', v_p, 500, jsonb_build_array(v_mo, v_mo), 72);
  if (v_r ->> 'client_cents')::int <> 66850 or (v_r ->> 'partner_cents')::int <> 52500 then
    raise exception '092 : 2 motos 500 km = % / % (attendu 66850 / 52500)', v_r ->> 'client_cents', v_r ->> 'partner_cents';
  end if;

  -- 7. Marge toujours positive et au moins 10 % sur chaque véhicule.
  for v_r in select secoto_private.price_group_with_grid('plateau', v_p, km, jsonb_build_array(a, b, c), 72)
               from unnest(array[5, 40, 120, 500, 1500, 2900]::numeric[]) km,
                    (values (v_vt), (v_mo), (v_ut), (v_nr)) x(a), (values (v_vt), (v_ut)) y(b), (values (v_mo), (v_nr)) z(c)
              where km <= coalesce((v_p ->> 'auto_max_km')::numeric, 100000) loop
    if v_r ? 'manual_reason' then
      raise exception '092 : un groupage standard part en devis manuel (%)', v_r ->> 'manual_reason';
    end if;
    if exists (select 1 from jsonb_array_elements(v_r -> 'detail') d
                where (d.value ->> 'client_cents')::int - (d.value ->> 'partner_cents')::int
                      < ceil((d.value ->> 'client_cents')::int * 0.10)) then
      raise exception '092 : un véhicule passe sous 10 %% de marge : %', v_r -> 'detail';
    end if;
  end loop;

  -- 8. Convoyage : aucune remise, jamais.
  v_r := secoto_private.price_group_with_grid('convoyage', v_c, 400, jsonb_build_array(v_vt, v_vt), 72);
  if (v_r ->> 'remise_groupage_cents')::int <> 0 or (v_r ->> 'client_cents')::int <> 80000 then
    raise exception '092 : convoyage 2 voitures = % remise % (attendu 80000 / 0)', v_r ->> 'client_cents', v_r ->> 'remise_groupage_cents';
  end if;

  raise notice '092 OK : 2 voitures 500 km = 1050 € client / 875 € transporteur ; Benissa = 3146,53 € / 2707,47 €.';
end
$controles$;
