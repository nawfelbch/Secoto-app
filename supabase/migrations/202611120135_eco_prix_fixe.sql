-- ============================================================================
-- SECOTO — MIGRATION 135 : OFFRE ÉCO À PRIX FIXE
-- ----------------------------------------------------------------------------
-- Demande de Nawfal du 12/11/2026 : l'Éco n'est plus calculée au kilomètre.
--   · 650 € pour tout trajet en France ;
--   · 750 € de la France vers l'étranger, et inversement.
-- Toujours de ville à ville : le client dépose et récupère lui-même son
-- véhicule (grande ville la plus proche en France ; ville de l'adresse à
-- l'étranger). Rémunération transporteur = prix − marge (20 %, jamais sous
-- 75 €) : 520 € en France, 600 € à l'international.
-- Éco n'est affichée que si elle est moins chère que Standard. Pas d'Éco pour
-- caravane / camping-car ; moto seulement sur l'axe Île-de-France ↔ Côte d'Azur.
-- Déjà appliqué en production le 12/11/2026. Rejouable.
-- ============================================================================

update public.app_settings
   set value = jsonb_set(jsonb_set(value, '{eco,prix_france_eur}', '650'), '{eco,prix_international_eur}', '750')
 where key = 'bareme_v3';

create or replace function secoto_private.offre_eco_v3(q public.transport_quotes, p_std_client integer)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  b jsonb := secoto_private.bareme_v3_reglages();
  e jsonb := b -> 'eco';
  v_gab text := secoto_private.gabarit_vehicule(q.vehicle);
  v_fr_a boolean := secoto_private.od_pays(q.pickup) = 'FR';
  v_fr_b boolean := secoto_private.od_pays(q.delivery) = 'FR';
  v_intl boolean;
  v_dep jsonb;
  v_arr jsonb;
  v_client integer;
  v_pay integer;
begin
  -- 135 : Éco = prix fixe (650 € en France, 750 € France ↔ étranger), plus de calcul au km.
  if v_gab is null or not (coalesce(e -> 'coef', '{}'::jsonb) ? v_gab) then return null; end if;
  if not coalesce((q.vehicle ->> 'rolling')::boolean, true) then return null; end if;
  if not v_fr_a and not v_fr_b then return null; end if;
  v_intl := not (v_fr_a and v_fr_b);
  if v_gab = 'moto' and not secoto_private.plafond_applicable('moto', q.pickup, q.delivery) then return null; end if;
  v_dep := case when v_fr_a then secoto_private.ville_eco(q.pickup) else jsonb_build_object('nom', q.pickup ->> 'city') end;
  v_arr := case when v_fr_b then secoto_private.ville_eco(q.delivery) else jsonb_build_object('nom', q.delivery ->> 'city') end;
  if v_dep ->> 'nom' is null or v_arr ->> 'nom' is null or v_dep ->> 'nom' = v_arr ->> 'nom' then return null; end if;
  v_client := round(coalesce((e ->> case when v_intl then 'prix_international_eur' else 'prix_france_eur' end)::numeric,
                             case when v_intl then 750 else 650 end) * 100)::int;
  v_pay := v_client - greatest(round(coalesce((b ->> 'marge_min_eur')::numeric, 75) * 100)::int,
                               round(v_client * coalesce((e ->> 'marge_pct')::numeric, 20) / 100)::int);
  -- Éco n'a de sens que moins chère que Standard.
  if v_pay <= 0 or v_client >= coalesce(p_std_client, 0) then return null; end if;
  return jsonb_build_object(
    'cle', 'eco', 'libelle', 'Éco',
    'client_cents', v_client, 'partenaire_cents', v_pay, 'commission_cents', v_client - v_pay,
    'fenetre_h', coalesce((secoto_private.trois_offres_reglages() -> 'eco' ->> 'fenetre_h')::int, 360),
    'ville_depot', v_dep ->> 'nom', 'ville_retrait', v_arr ->> 'nom', 'international', v_intl,
    'regles', format('De ville à ville : vous déposez votre véhicule à %s et le récupérez à %s. Prise en charge sous 15 jours.',
                     v_dep ->> 'nom', v_arr ->> 'nom'),
    'recommande', false);
end;
$$;
revoke all on function secoto_private.offre_eco_v3(public.transport_quotes, integer) from public, anon, authenticated;

notify pgrst, 'reload schema';
