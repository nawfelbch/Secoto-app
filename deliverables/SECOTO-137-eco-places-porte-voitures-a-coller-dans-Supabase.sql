-- ============================================================================
-- SECOTO — MIGRATION 137 : ÉCO EN « PLACES » SUR LE PORTE-VOITURES
-- ----------------------------------------------------------------------------
-- Validé par Nawfal le 12/11/2026. Un porte-voitures PL compte en places :
-- un véhicule long ou haut (caravane, grand utilitaire) prend la place de deux
-- voitures. La rémunération Éco suit donc le nombre de places :
--   · 1 place   : citadine, berline, SUV compact, moto (axe IDF ↔ Côte d'Azur)
--   · 1,5 place : 4x4 / grand SUV, petit utilitaire (≤ 5 m et ≤ 2 m de haut)
--   · 2 places  : grand utilitaire, caravane, camping-car jusqu'à 8 m
--   · +0,5 place au-delà de 3 t ; plus de 8 m ou plus de 3,5 t : sur devis.
-- Prix : 1 place = 550 € (≤ 300 km) / 650 € en France, 800 € France ↔
-- étranger (transporteur 400 € / 640 €). Au-delà d'une place : transporteur =
-- places × 400 € (France) ou × 640 € (international), client = transporteur
-- / 0,80 (marge 20 %, jamais sous 75 €).
-- L'Éco part désormais à TOUS les transporteurs PL validés (la case « délais
-- longs » n'est plus exigée : aucun PL ne l'avait cochée).
-- ADDITIF, rejouable.
-- ============================================================================

update public.app_settings
   set value = jsonb_set(value, '{eco,places}', jsonb_build_object(
     'grand', 1.5, 'utilitaire_court', 1.5, 'utilitaire_long', 2, 'caravane', 2, 'camping_car', 2,
     'utilitaire_court_longueur_max_m', 5, 'utilitaire_court_hauteur_max_m', 2,
     'longueur_max_m', 8, 'poids_majore_kg', 3000, 'poids_majoration_places', 0.5, 'poids_max_kg', 3500))
 where key = 'bareme_v3';

-- Nombre de places occupées sur un porte-voitures (null : pas d'Éco, sur devis).
create or replace function secoto_private.places_eco(p_vehicle jsonb)
returns numeric language plpgsql stable security definer set search_path = '' as $$
declare
  p jsonb := secoto_private.bareme_v3_reglages() -> 'eco' -> 'places';
  v_gab text := secoto_private.gabarit_vehicule(p_vehicle);
  v_long numeric := nullif(p_vehicle ->> 'length_m', '')::numeric;
  v_haut numeric := nullif(p_vehicle ->> 'height_m', '')::numeric;
  v_poids numeric := nullif(p_vehicle ->> 'weight_kg', '')::numeric;
  v_places numeric;
begin
  if v_gab is null or v_gab = 'poids_lourd' then return null; end if;
  if v_poids > coalesce((p ->> 'poids_max_kg')::numeric, 3500) or v_long > coalesce((p ->> 'longueur_max_m')::numeric, 8) then
    return null;
  end if;
  v_places := case v_gab
    when 'citadine' then 1 when 'berline' then 1 when 'moto' then 1
    when 'grand' then coalesce((p ->> 'grand')::numeric, 1.5)
    when 'utilitaire' then case
      when v_long <= coalesce((p ->> 'utilitaire_court_longueur_max_m')::numeric, 5)
       and v_haut <= coalesce((p ->> 'utilitaire_court_hauteur_max_m')::numeric, 2)
        then coalesce((p ->> 'utilitaire_court')::numeric, 1.5)
      else coalesce((p ->> 'utilitaire_long')::numeric, 2) end   -- dimensions inconnues : 2 places
    when 'caravane' then coalesce((p ->> 'caravane')::numeric, 2)
    when 'camping_car' then coalesce((p ->> 'camping_car')::numeric, 2)
  end;
  if v_places is not null and v_poids > coalesce((p ->> 'poids_majore_kg')::numeric, 3000) then
    v_places := v_places + coalesce((p ->> 'poids_majoration_places')::numeric, 0.5);
  end if;
  return v_places;
end;
$$;
revoke all on function secoto_private.places_eco(jsonb) from public, anon, authenticated;

create or replace function secoto_private.offre_eco_v3(q public.transport_quotes, p_std_client integer)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  b jsonb := secoto_private.bareme_v3_reglages();
  e jsonb := b -> 'eco';
  v_gab text := secoto_private.gabarit_vehicule(q.vehicle);
  v_places numeric := secoto_private.places_eco(q.vehicle);
  v_fr_a boolean := secoto_private.od_pays(q.pickup) = 'FR';
  v_fr_b boolean := secoto_private.od_pays(q.delivery) = 'FR';
  v_intl boolean;
  v_dep jsonb;
  v_arr jsonb;
  v_client integer;
  v_pay integer;
  v_ref integer;
  v_min_marge integer := round(coalesce((b ->> 'marge_min_eur')::numeric, 75) * 100)::int;
begin
  -- 137 : Éco en places sur le porte-voitures (caravane, camping-car compris).
  if v_places is null then return null; end if;
  if not coalesce((q.vehicle ->> 'rolling')::boolean, true) then return null; end if;
  if not v_fr_a and not v_fr_b then return null; end if;
  v_intl := not (v_fr_a and v_fr_b);
  if v_gab = 'moto' and not secoto_private.plafond_applicable('moto', q.pickup, q.delivery) then return null; end if;
  v_dep := case when v_fr_a then secoto_private.ville_eco(q.pickup) else jsonb_build_object('nom', q.pickup ->> 'city') end;
  v_arr := case when v_fr_b then secoto_private.ville_eco(q.delivery) else jsonb_build_object('nom', q.delivery ->> 'city') end;
  if v_dep ->> 'nom' is null or v_arr ->> 'nom' is null or v_dep ->> 'nom' = v_arr ->> 'nom' then return null; end if;

  -- Rémunération de référence d'une place : 400 € en France, 640 € à l'international.
  v_ref := round(coalesce((e ->> case when v_intl then 'transporteur_international_eur' else 'transporteur_france_eur' end)::numeric,
                          case when v_intl then 640 else 400 end) * 100)::int;
  if v_places = 1 then
    -- Une place : grille fixe 550 € (≤ 300 km) / 650 € en France, 800 € à l'international.
    v_client := round(coalesce((e ->> case when v_intl then 'prix_international_eur' else 'prix_france_eur' end)::numeric,
                               case when v_intl then 800 else 650 end) * 100)::int;
    if not v_intl and coalesce((q.route ->> 'distance_km')::numeric, 0) > 0
       and (q.route ->> 'distance_km')::numeric <= coalesce((e ->> 'court_max_km')::numeric, 300) then
      v_client := round(coalesce((e ->> 'prix_court_eur')::numeric, 550) * 100)::int;
    end if;
    v_pay := least(v_client - v_min_marge, v_ref);
  else
    -- Plusieurs places : places × référence, marge 20 % (jamais sous 75 €).
    v_pay := round(v_ref * v_places)::int;
    v_client := greatest(v_pay + v_min_marge,
                         round(v_pay / (1 - coalesce((e ->> 'marge_pct')::numeric, 20) / 100))::int);
  end if;

  -- Éco n'a de sens que moins chère que Standard.
  if v_pay <= 0 or v_client >= coalesce(p_std_client, 0) then return null; end if;
  return jsonb_build_object(
    'cle', 'eco', 'libelle', 'Éco',
    'client_cents', v_client, 'partenaire_cents', v_pay, 'commission_cents', v_client - v_pay,
    'fenetre_h', coalesce((secoto_private.trois_offres_reglages() -> 'eco' ->> 'fenetre_h')::int, 360),
    'ville_depot', v_dep ->> 'nom', 'ville_retrait', v_arr ->> 'nom', 'international', v_intl, 'places', v_places,
    'regles', format('De ville à ville : vous déposez votre véhicule à %s et le récupérez à %s. Prise en charge sous 15 jours.',
                     v_dep ->> 'nom', v_arr ->> 'nom'),
    'recommande', false);
end;
$$;
revoke all on function secoto_private.offre_eco_v3(public.transport_quotes, integer) from public, anon, authenticated;

-- L'Éco part à tous les transporteurs PL validés (porte-voitures).
create or replace function secoto_private.offre_partenaire_ok(p_partner uuid, p_offre text)
returns boolean language sql stable security definer set search_path = '' as $$
  select case when coalesce(p_offre, '') <> 'eco' then true
    else exists (select 1 from public.accounts a
                  where a.id = p_partner and a.transporter_type::text = 'pl') end;  -- 137 : plus de case « délais longs »
$$;
revoke all on function secoto_private.offre_partenaire_ok(uuid, text) from public, anon, authenticated;

notify pgrst, 'reload schema';
