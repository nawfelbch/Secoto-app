-- ============================================================================
-- SECOTO — MIGRATION 139 : ÉCO AUSSI POUR LES VÉHICULES NON ROULANTS
-- ----------------------------------------------------------------------------
-- Demandé par Nawfal le 12/11/2026. Un véhicule non roulant a désormais droit
-- à l'offre Éco :
--   · trajet long (plus de 300 km en France, ou France ↔ étranger) : même prix ;
--   · trajet court (300 km ou moins en France) : + 80 € (550 € → 630 €).
-- La rémunération transporteur ne change pas (400 € / 640 € par place, jamais
-- plus sans accord) : les 80 € restent à SECOTO.
-- Réglage : app_settings['bareme_v3'].eco.non_roulant_court_eur.
-- Le site vitrine suit (la table publique est recalculée par le trigger 138).
-- ADDITIF, rejouable.
-- ============================================================================

-- 1. Le site lit le supplément (table publique 138).
select secoto_private.mig074_patch(
  'secoto_private.bareme_v3_public_calcul()'::regprocedure,
  '      ''prix_court_eur'', (e ->> ''prix_court_eur'')::numeric, ''court_max_km'', (e ->> ''court_max_km'')::numeric,',
  '      ''prix_court_eur'', (e ->> ''prix_court_eur'')::numeric, ''court_max_km'', (e ->> ''court_max_km'')::numeric,
      ''non_roulant_court_eur'', coalesce((e ->> ''non_roulant_court_eur'')::numeric, 0),  -- 139');

-- 2. Offre Éco : plus d'exclusion des non roulants, + 80 € sur trajet court.
create or replace function secoto_private.offre_eco_v3(q public.transport_quotes, p_std_client integer)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  b jsonb := secoto_private.bareme_v3_reglages();
  e jsonb := b -> 'eco';
  v_gab text := secoto_private.gabarit_vehicule(q.vehicle);
  v_places numeric := secoto_private.places_eco(q.vehicle);
  v_fr_a boolean := secoto_private.od_pays(q.pickup) = 'FR';
  v_fr_b boolean := secoto_private.od_pays(q.delivery) = 'FR';
  v_roulant boolean := coalesce((q.vehicle ->> 'rolling')::boolean, true);
  v_km numeric := coalesce((q.route ->> 'distance_km')::numeric, 0);
  v_court boolean;
  v_intl boolean;
  v_dep jsonb;
  v_arr jsonb;
  v_client integer;
  v_pay integer;
  v_ref integer;
  v_min_marge integer := round(coalesce((b ->> 'marge_min_eur')::numeric, 75) * 100)::int;
begin
  -- 137 : Éco en places sur le porte-voitures. 139 : non roulants acceptés.
  if v_places is null then return null; end if;
  if not v_fr_a and not v_fr_b then return null; end if;
  v_intl := not (v_fr_a and v_fr_b);
  v_court := not v_intl and v_km > 0 and v_km <= coalesce((e ->> 'court_max_km')::numeric, 300);
  if v_gab = 'moto' and not secoto_private.plafond_applicable('moto', q.pickup, q.delivery) then return null; end if;
  v_dep := case when v_fr_a then secoto_private.ville_eco(q.pickup) else jsonb_build_object('nom', q.pickup ->> 'city') end;
  v_arr := case when v_fr_b then secoto_private.ville_eco(q.delivery) else jsonb_build_object('nom', q.delivery ->> 'city') end;
  if v_dep ->> 'nom' is null or v_arr ->> 'nom' is null or v_dep ->> 'nom' = v_arr ->> 'nom' then return null; end if;

  -- Rémunération de référence d'une place : 400 € en France, 640 € à l'international.
  v_ref := round(coalesce((e ->> case when v_intl then 'transporteur_international_eur' else 'transporteur_france_eur' end)::numeric,
                          case when v_intl then 640 else 400 end) * 100)::int;
  if v_places = 1 then
    -- Une place : 550 € (≤ 300 km) / 650 € en France, 800 € à l'international.
    v_client := round(coalesce((e ->> case when v_intl then 'prix_international_eur' else 'prix_france_eur' end)::numeric,
                               case when v_intl then 800 else 650 end) * 100)::int;
    if v_court then
      v_client := round(coalesce((e ->> 'prix_court_eur')::numeric, 550) * 100)::int;
    end if;
    v_pay := least(v_client - v_min_marge, v_ref);
  else
    -- Plusieurs places : places × référence, marge 20 % (jamais sous 75 €).
    v_pay := round(v_ref * v_places)::int;
    v_client := greatest(v_pay + v_min_marge,
                         round(v_pay / (1 - coalesce((e ->> 'marge_pct')::numeric, 20) / 100))::int);
  end if;
  -- 139 : non roulant sur trajet court, supplément client (rémunération inchangée).
  if not v_roulant and v_court then
    v_client := v_client + round(coalesce((e ->> 'non_roulant_court_eur')::numeric, 80) * 100)::int;
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

-- 3. Réglage (déclenche aussi le recalcul de la table publique du site).
update public.app_settings
   set value = jsonb_set(value, '{eco,non_roulant_court_eur}', '80')
 where key = 'bareme_v3';

notify pgrst, 'reload schema';
