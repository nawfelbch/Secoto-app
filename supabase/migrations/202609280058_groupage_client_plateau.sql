-- ============================================================================
-- SECOTO — 058 : CHIFFRER PLUSIEURS VEHICULES SUR UN MEME TRAJET
-- ----------------------------------------------------------------------------
-- REGLE COMMERCIALE (27-28/09/2026)
--   A partir de 2 vehicules sur un meme trajet, en PLATEAU uniquement, SECOTO
--   rend une part de sa marge au client, sur CHAQUE vehicule de la commande :
--     - voiture et moto : 40 % de la marge rendue
--     - utilitaire      : 20 % seulement, sa marge de depart n'etant que de
--                         0,15 EUR/km contre 0,20 pour la voiture. A 20 % il
--                         garde 0,12 EUR/km, exactement comme la voiture apres
--                         remise : aucune categorie ne descend sous ce plancher
--                         de marge.
--
--   La remuneration du transporteur n'est JAMAIS touchee : il percoit son plein
--   tarif par vehicule. Un transporteur dont la paie serait amputee refuserait,
--   et il n'y aurait plus de groupage du tout. La remise sort donc entierement
--   de la marge SECOTO, ce qui la rend imperdable par construction : elle ne
--   peut pas depasser ce que SECOTO gagne.
--
--   Le CONVOYAGE est exclu : deux vehicules y imposent deux convoyeurs qui
--   roulent chacun tout le trajet. Il n'y a aucune economie a partager, donc
--   aucune remise. Le groupage y reste possible, au plein tarif.
--
-- TROIS DETAILS QUI CHANGENT LE RESULTAT
--   - le plancher de mobilisation (minimum_eur) vaut pour la COMMANDE, pas pour
--     chaque vehicule : un second vehicule sur le meme camion n'a pas a porter
--     un second forfait minimum ;
--   - le seuil de marge (min_margin_pct) est neutralise sur une commande
--     groupee : la marge descend volontairement, c'est le principe meme de la
--     remise. Il continue de proteger toutes les missions simples ;
--   - les plafonds moto (382 client / 300 transporteur) s'appliquent AVANT la
--     remise, sinon le plafond avalerait la remise.
--
-- Les pourcentages sont surchargeables par la grille tarifaire
-- (group_margin_give_by_class, group_margin_give_pct, group_max_vehicles) sans
-- retoucher cette fonction.
--
-- price_with_grid n'est pas modifiee : aucun appel existant n'est touche.
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
  v_nb           integer;
  v_rang         integer := 0;
  v_vehicule     jsonb;
  v_classe       text;
  v_give_pct     numeric;
  v_params_suite jsonb;
  v_unitaire     jsonb;
  v_client       integer := 0;
  v_partner      integer := 0;
  v_remise       integer := 0;
  v_reduction    integer;
  v_groupe       boolean;
  v_detail       jsonb := '[]'::jsonb;
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

  -- Un seul vehicule : rien ne change, on delegue tel quel.
  if v_nb = 1 then
    v_unitaire := secoto_private.price_with_grid(
      p_mode, p, p_distance_km, p_vehicles -> 0, p_hours_to_pickup);
    if v_unitaire ? 'manual_reason' then
      return v_unitaire;
    end if;
    return v_unitaire
      || jsonb_build_object('vehicules', 1, 'remise_groupage_cents', 0);
  end if;

  -- La remise ne vaut qu'en plateau.
  v_groupe := (p_mode = 'plateau');

  -- Vehicules 2 et suivants : ni plancher de mobilisation, ni seuil de marge.
  v_params_suite := p || jsonb_build_object('minimum_eur', 0, 'min_margin_pct', 0);

  for v_vehicule in select value from jsonb_array_elements(p_vehicles) loop
    v_rang := v_rang + 1;
    v_classe := coalesce(v_vehicule ->> 'class', '');

    v_unitaire := secoto_private.price_with_grid(
      p_mode,
      case when v_rang = 1 and not v_groupe then p
           when v_rang = 1 then p || jsonb_build_object('min_margin_pct', 0)
           else v_params_suite end,
      p_distance_km,
      v_vehicule,
      p_hours_to_pickup);

    if v_unitaire ? 'manual_reason' then
      return v_unitaire;
    end if;

    -- Part de marge rendue, par categorie.
    v_give_pct := coalesce(
      (p -> 'group_margin_give_by_class' ->> v_classe)::numeric,
      (p ->> 'group_margin_give_pct')::numeric,
      case when v_classe = 'utilitaire' then 20 else 40 end);

    v_reduction := 0;
    if v_groupe and v_give_pct > 0 then
      v_reduction := floor((v_unitaire ->> 'margin_cents')::numeric * v_give_pct / 100)::integer;
    end if;

    v_client  := v_client  + (v_unitaire ->> 'client_cents')::integer - v_reduction;
    v_partner := v_partner + (v_unitaire ->> 'partner_cents')::integer;
    v_remise  := v_remise  + v_reduction;

    v_detail := v_detail || jsonb_build_object(
      'rang',          v_rang,
      'class',         v_classe,
      'client_cents',  (v_unitaire ->> 'client_cents')::integer - v_reduction,
      'partner_cents', (v_unitaire ->> 'partner_cents')::integer,
      'remise_cents',  v_reduction,
      'capped',        coalesce((v_unitaire ->> 'capped')::boolean, false),
      'lines',         v_unitaire -> 'lines');
  end loop;

  -- Garde-fou absolu : une commande ne peut jamais couter plus qu'elle ne
  -- rapporte, quelle que soit la grille en vigueur.
  if v_client < v_partner then
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
    'capped',                 exists (
      select 1 from jsonb_array_elements(v_detail) d
      where coalesce((d.value ->> 'capped')::boolean, false)),
    'detail',                 v_detail,
    'included',               coalesce(p -> 'included', '[]'::jsonb),
    'excluded',               coalesce(p -> 'excluded', '[]'::jsonb));
end;
$f$;

comment on function secoto_private.price_group_with_grid(text, jsonb, numeric, jsonb, numeric) is
  'Tarife plusieurs vehicules sur un meme trajet. A partir de 2 vehicules en '
  'plateau, SECOTO rend 40 % de sa marge par vehicule (20 % sur utilitaire) ; '
  'la remuneration du transporteur n''est jamais reduite. Convoyage : plein tarif.';

-- ============================================================================
-- CONTROLES BLOQUANTS — montants attendus au 28/09/2026
-- (plateau : voiture 1,20 / 1,00 · moto 1,00 / 0,85 plafonnee 382 / 300 ·
--  utilitaire 1,25 / 1,10)
-- ============================================================================
do $controles$
declare
  v_plateau   jsonb;
  v_convoyage jsonb;
  v_r         jsonb;

  v_voiture    jsonb := jsonb_build_object('class', 'voiture',    'category', 'standard', 'rolling', true);
  v_moto       jsonb := jsonb_build_object('class', 'moto',       'category', 'standard', 'rolling', true);
  v_utilitaire jsonb := jsonb_build_object('class', 'utilitaire', 'category', 'standard', 'rolling', true);
begin
  select params into v_plateau
  from public.pricing_grids where mode = 'plateau' and status = 'active';

  select params into v_convoyage
  from public.pricing_grids where mode = 'convoyage' and status = 'active';

  if v_plateau is null then
    raise exception 'Aucune grille plateau active : controle impossible';
  end if;

  if (v_plateau -> 'class_rates' -> 'moto' ->> 'client_cap_eur')::numeric <> 382 then
    raise exception 'Plafond client moto attendu a 382 EUR, trouve % : appliquez d''abord la migration 057',
      v_plateau -> 'class_rates' -> 'moto' ->> 'client_cap_eur';
  end if;

  -- 1. Une seule voiture : le bareme ne bouge pas. 500 km -> 600 / 500.
  v_r := secoto_private.price_group_with_grid(
    'plateau', v_plateau, 500, jsonb_build_array(v_voiture), null);
  if (v_r ->> 'client_cents')::int <> 60000 or (v_r ->> 'partner_cents')::int <> 50000 then
    raise exception '1 voiture 500 km : % / % (attendu 60000 / 50000)',
      v_r ->> 'client_cents', v_r ->> 'partner_cents';
  end if;
  if (v_r ->> 'remise_groupage_cents')::int <> 0 then
    raise exception '1 voiture ne doit porter aucune remise';
  end if;

  -- 2. Deux voitures, 500 km : 1 120 EUR client, 1 000 EUR transporteur, 80 rendus.
  v_r := secoto_private.price_group_with_grid(
    'plateau', v_plateau, 500, jsonb_build_array(v_voiture, v_voiture), null);
  if (v_r ->> 'client_cents')::int <> 112000 then
    raise exception '2 voitures 500 km : client % (attendu 112000)', v_r ->> 'client_cents';
  end if;
  if (v_r ->> 'partner_cents')::int <> 100000 then
    raise exception '2 voitures 500 km : transporteur % (attendu 100000 — sa paie ne doit jamais bouger)',
      v_r ->> 'partner_cents';
  end if;
  if (v_r ->> 'remise_groupage_cents')::int <> 8000 then
    raise exception '2 voitures 500 km : remise % (attendu 8000)', v_r ->> 'remise_groupage_cents';
  end if;

  -- 3. Trois voitures, 500 km : 1 680 / 1 500.
  v_r := secoto_private.price_group_with_grid(
    'plateau', v_plateau, 500, jsonb_build_array(v_voiture, v_voiture, v_voiture), null);
  if (v_r ->> 'client_cents')::int <> 168000 or (v_r ->> 'partner_cents')::int <> 150000 then
    raise exception '3 voitures 500 km : % / % (attendu 168000 / 150000)',
      v_r ->> 'client_cents', v_r ->> 'partner_cents';
  end if;

  -- 4. Quatre vehicules : refuse.
  v_r := secoto_private.price_group_with_grid(
    'plateau', v_plateau, 500,
    jsonb_build_array(v_voiture, v_voiture, v_voiture, v_voiture), null);
  if v_r ->> 'manual_reason' <> 'trop_de_vehicules' then
    raise exception '4 vehicules devraient etre refuses, obtenu %', coalesce(v_r ->> 'manual_reason', 'un prix');
  end if;

  -- 5. Deux motos, 500 km : plafonds appliques AVANT la remise.
  --    382 - 32,80 = 349,20 par moto -> 698,40 client, 600 transporteur.
  v_r := secoto_private.price_group_with_grid(
    'plateau', v_plateau, 500, jsonb_build_array(v_moto, v_moto), null);
  if (v_r ->> 'client_cents')::int <> 69840 or (v_r ->> 'partner_cents')::int <> 60000 then
    raise exception '2 motos 500 km : % / % (attendu 69840 / 60000)',
      v_r ->> 'client_cents', v_r ->> 'partner_cents';
  end if;

  -- 6. Une voiture et une moto, 500 km : 560 + 349,20 = 909,20 / 800.
  v_r := secoto_private.price_group_with_grid(
    'plateau', v_plateau, 500, jsonb_build_array(v_voiture, v_moto), null);
  if (v_r ->> 'client_cents')::int <> 90920 or (v_r ->> 'partner_cents')::int <> 80000 then
    raise exception '1 voiture + 1 moto 500 km : % / % (attendu 90920 / 80000)',
      v_r ->> 'client_cents', v_r ->> 'partner_cents';
  end if;

  -- 7. Deux utilitaires, 500 km : remise de 20 % seulement.
  --    625 - 15 = 610 par vehicule -> 1 220 client, 1 100 transporteur.
  v_r := secoto_private.price_group_with_grid(
    'plateau', v_plateau, 500, jsonb_build_array(v_utilitaire, v_utilitaire), null);
  if (v_r ->> 'client_cents')::int <> 122000 or (v_r ->> 'partner_cents')::int <> 110000 then
    raise exception '2 utilitaires 500 km : % / % (attendu 122000 / 110000)',
      v_r ->> 'client_cents', v_r ->> 'partner_cents';
  end if;
  if (v_r ->> 'remise_groupage_cents')::int <> 3000 then
    raise exception '2 utilitaires 500 km : remise % (attendu 3000)', v_r ->> 'remise_groupage_cents';
  end if;

  -- 8. Convoyage : aucune remise, jamais.
  if v_convoyage is not null then
    v_r := secoto_private.price_group_with_grid(
      'convoyage', v_convoyage, 500, jsonb_build_array(v_voiture, v_voiture), null);
    if v_r ? 'manual_reason' then
      raise notice 'Convoyage 2 vehicules refuse par la grille (%), controle ignore',
        v_r ->> 'manual_reason';
    elsif (v_r ->> 'remise_groupage_cents')::int <> 0 then
      raise exception 'Convoyage : remise % alors qu''aucune remise n''y est prevue',
        v_r ->> 'remise_groupage_cents';
    end if;
  end if;

  raise notice 'OK : bareme groupage conforme. 2 voitures 500 km = 1120 EUR client / 1000 EUR transporteur / 80 EUR rendus.';
end
$controles$;
