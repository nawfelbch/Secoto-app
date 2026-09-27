-- ============================================================================
-- SECOTO — 056 : CHIFFRER PLUSIEURS VEHICULES SUR UN MEME TRAJET
-- ----------------------------------------------------------------------------
-- Decision du 27/09/2026.
--
-- Regle commerciale :
--   A partir de 2 vehicules sur un meme trajet, en PLATEAU uniquement, SECOTO
--   rend 40 % de sa marge au client, sur CHAQUE vehicule de la commande.
--   Voiture : la marge passe de 0,20 a 0,12 EUR/km, soit 0,08 EUR/km rendus.
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
-- Trois details qui changent le resultat :
--   - le plancher de mobilisation (minimum_eur) vaut pour la COMMANDE, pas pour
--     chaque vehicule : un second vehicule sur le meme camion n'a pas a porter
--     un second forfait minimum ;
--   - le seuil de marge (min_margin_pct) est neutralise sur une commande
--     groupee : la marge descend volontairement sous le seuil, c'est le principe
--     meme de la remise. Il continue de proteger toutes les missions simples ;
--   - les plafonds moto (400 client / 300 transporteur) s'appliquent AVANT la
--     remise, sinon le plafond avalerait la remise.
--
-- Cette migration n'ajoute qu'une fonction. Aucun appel existant n'est modifie,
-- aucune grille n'est reversionnee : price_with_grid reste intacte.
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
  v_give_pct     numeric := coalesce((p ->> 'group_margin_give_pct')::numeric, 40);
  v_nb           integer;
  v_rang         integer := 0;
  v_vehicule     jsonb;
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
  v_groupe := (p_mode = 'plateau' and v_give_pct > 0);

  -- Vehicules 2 et suivants : ni plancher de mobilisation, ni seuil de marge.
  v_params_suite := p || jsonb_build_object('minimum_eur', 0, 'min_margin_pct', 0);

  for v_vehicule in select value from jsonb_array_elements(p_vehicles) loop
    v_rang := v_rang + 1;

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

    v_reduction := 0;
    if v_groupe then
      v_reduction := floor((v_unitaire ->> 'margin_cents')::numeric * v_give_pct / 100)::integer;
    end if;

    v_client  := v_client  + (v_unitaire ->> 'client_cents')::integer - v_reduction;
    v_partner := v_partner + (v_unitaire ->> 'partner_cents')::integer;
    v_remise  := v_remise  + v_reduction;

    v_detail := v_detail || jsonb_build_object(
      'rang',          v_rang,
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
  'plateau, SECOTO rend 40 % de sa marge sur chaque vehicule ; la remuneration '
  'du transporteur n''est jamais reduite. Convoyage : plein tarif.';

-- ============================================================================
-- CONTROLES BLOQUANTS — montants attendus au 27/09/2026
-- ============================================================================
do $controles$
declare
  v_plateau   jsonb;
  v_convoyage jsonb;
  v_r         jsonb;


  v_voiture jsonb := jsonb_build_object('class', 'voiture', 'category', 'standard', 'rolling', true);
  v_moto    jsonb := jsonb_build_object('class', 'moto',    'category', 'standard', 'rolling', true);
begin
  select params into v_plateau
  from public.pricing_grids where mode = 'plateau' and status = 'active';

  select params into v_convoyage
  from public.pricing_grids where mode = 'convoyage' and status = 'active';

  if v_plateau is null then
    raise exception 'Aucune grille plateau active : controle impossible';
  end if;

  -- 1. Une seule voiture : le barème ne bouge pas. 500 km -> 600 / 500.
  v_r := secoto_private.price_group_with_grid(
    'plateau', v_plateau, 500, jsonb_build_array(v_voiture), null);
  if (v_r ->> 'client_cents')::int <> 60000 or (v_r ->> 'partner_cents')::int <> 50000 then
    raise exception '1 voiture 500 km : % / % (attendu 60000 / 50000)',
      v_r ->> 'client_cents', v_r ->> 'partner_cents';
  end if;
  if (v_r ->> 'remise_groupage_cents')::int <> 0 then
    raise exception '1 voiture ne doit porter aucune remise';
  end if;

  -- 2. Deux voitures, 500 km : 1 120 € client, 1 000 € transporteur, 80 € rendus.
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

  -- 3. Trois voitures, 500 km : 1 680 / 1 500, 120 € rendus.
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

  -- 5. Deux motos, 500 km : plafonds appliques AVANT la remise -> 720 / 600.
  v_r := secoto_private.price_group_with_grid(
    'plateau', v_plateau, 500, jsonb_build_array(v_moto, v_moto), null);
  if (v_r ->> 'client_cents')::int <> 72000 or (v_r ->> 'partner_cents')::int <> 60000 then
    raise exception '2 motos 500 km : % / % (attendu 72000 / 60000)',
      v_r ->> 'client_cents', v_r ->> 'partner_cents';
  end if;

  -- 6. Une voiture et une moto, 500 km : 920 / 800.
  v_r := secoto_private.price_group_with_grid(
    'plateau', v_plateau, 500, jsonb_build_array(v_voiture, v_moto), null);
  if (v_r ->> 'client_cents')::int <> 92000 or (v_r ->> 'partner_cents')::int <> 80000 then
    raise exception '1 voiture + 1 moto 500 km : % / % (attendu 92000 / 80000)',
      v_r ->> 'client_cents', v_r ->> 'partner_cents';
  end if;

  -- 7. Convoyage : aucune remise, jamais.
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

  raise notice 'OK : barème groupage conforme (2 voitures 500 km = 1120 EUR client, 1000 EUR transporteur, 80 EUR rendus)';
end
$controles$;
