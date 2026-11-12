-- ============================================================================
-- SECOTO — MIGRATION 138 : BARÈME v3 PUBLIC POUR LE SITE VITRINE
-- ----------------------------------------------------------------------------
-- Le site secoto-transport.fr lit ses prix au moment de sa construction (une
-- seule source de vérité : l'app). Le barème v3 dépend du gabarit, du trajet
-- (axe, zones) et de l'état du véhicule : on publie donc une TABLE DE PRIX
-- CLIENT calculée par secoto_private.bareme_v3 lui-même (aucune formule
-- recopiée), plus les règles Express / Éco que le client lit déjà dans l'app.
-- Jamais la rémunération des transporteurs ni la marge.
--
-- Le calcul (~2 s) est mis en cache dans app_settings['bareme_v3_public'] et
-- refait automatiquement dès que 'bareme_v3' ou 'trois_offres' change.
-- Rafraîchir à la main : select secoto_private.bareme_v3_public_rafraichir();
--
-- ADDITIF, rejouable. secoto_bareme_public (convoyage, ancien format) reste.
-- ============================================================================

create or replace function secoto_private.bareme_v3_public_calcul()
returns jsonb language plpgsql stable security definer set search_path = '' as $f$
declare
  b jsonb := secoto_private.bareme_v3_reglages();
  t jsonb := secoto_private.trois_offres_reglages();
  e jsonb := b -> 'eco';
  v_km int[] := array(select generate_series(0, 1000, 10) union select generate_series(1050, 2500, 50) order by 1);
  -- Trajets types (codes postaux) : seul le département compte pour le barème.
  v_cas jsonb := jsonb_build_object(
    'normal',    jsonb_build_array('75001', '33000'),
    'axe',       jsonb_build_array('75001', '69001'),
    'hors_zone', jsonb_build_array('75001', '18000'));
  v_gab text;
  v_c text;
  v_r boolean;
  v_serie jsonb;
  v_prix jsonb;
  v_tables jsonb := '{}'::jsonb;
  k int;
begin
  if not secoto_private.flag('bareme_v3') then return jsonb_build_object('actif', false); end if;
  foreach v_gab in array array['citadine', 'berline', 'grand', 'utilitaire', 'moto', 'caravane', 'camping_car'] loop
    v_serie := '{}'::jsonb;
    for v_c in select jsonb_object_keys(v_cas) loop
      continue when v_c <> 'normal' and v_gab not in ('citadine', 'berline', 'grand');
      foreach v_r in array array[true, false] loop
        v_prix := '[]'::jsonb;
        foreach k in array v_km loop
          v_prix := v_prix || to_jsonb(round(((secoto_private.bareme_v3('{}'::jsonb,
                        jsonb_build_object('gabarit', v_gab, 'rolling', v_r, 'category', 'standard'),
                        jsonb_build_object('postcode', v_cas -> v_c ->> 0),
                        jsonb_build_object('postcode', v_cas -> v_c ->> 1),
                        greatest(k, 1)) ->> 'client_cents')::numeric) / 100.0));
        end loop;
        v_serie := v_serie || jsonb_build_object(v_c || case when v_r then '' else '_non_roulant' end, v_prix);
      end loop;
    end loop;
    v_tables := v_tables || jsonb_build_object(v_gab, v_serie);
  end loop;

  -- Uniquement ce que le client voit dans l'app : prix client, jamais la rémunération ni la marge.
  return jsonb_build_object(
    'actif', true,
    'km', to_jsonb(v_km),
    'prix', v_tables,
    'minimums', (select jsonb_object_agg(g, (v ->> 'minimum_eur')::numeric) from jsonb_each(b -> 'gabarits') as x(g, v)),
    'axe_departements', b -> 'axe_departements',
    'grandes_zones', b -> 'grandes_zones',
    'moto_couloir', jsonb_build_object(
      'plafond_eur', (b ->> 'moto_plafond_couloir_eur')::numeric,
      'zone_a', secoto_private.bareme_transporteurs() -> 'couloir_plafond' -> 'moto' -> 'zone_a',
      'zone_b', secoto_private.bareme_transporteurs() -> 'couloir_plafond' -> 'moto' -> 'zone_b'),
    'caravane', jsonb_build_object(
      'poids_majore_kg', (b ->> 'poids_majore_kg')::numeric, 'poids_majoration_pct', (b ->> 'poids_majoration_pct')::numeric,
      'longueur_majoree_m', (b ->> 'longueur_majoree_m')::numeric, 'longueur_majoration_pct', (b ->> 'longueur_majoration_pct')::numeric,
      'poids_max_kg', (b ->> 'poids_max_kg')::numeric),
    'express', jsonb_build_object('coef', coalesce((t -> 'express' ->> 'coef')::numeric, 1.30),
                                  'delai_h', coalesce((t -> 'express' ->> 'fenetre_h')::int, 48)),
    'standard', jsonb_build_object('delai_h', coalesce((t -> 'standard' ->> 'fenetre_h')::int, 120)),
    'eco', jsonb_build_object(
      'prix_court_eur', (e ->> 'prix_court_eur')::numeric, 'court_max_km', (e ->> 'court_max_km')::numeric,
      'prix_france_eur', (e ->> 'prix_france_eur')::numeric, 'prix_international_eur', (e ->> 'prix_international_eur')::numeric,
      -- Au-delà d'une place, le prix client par place (rémunération / (1 - marge)).
      'prix_place_france_eur', round((e ->> 'transporteur_france_eur')::numeric / (1 - (e ->> 'marge_pct')::numeric / 100)),
      'prix_place_international_eur', round((e ->> 'transporteur_international_eur')::numeric / (1 - (e ->> 'marge_pct')::numeric / 100)),
      'delai_h', coalesce((t -> 'eco' ->> 'fenetre_h')::int, 360),
      'places', e -> 'places',
      'villes', (select jsonb_agg(jsonb_build_object('nom', v ->> 'nom', 'lat', (v ->> 'lat')::numeric, 'lng', (v ->> 'lng')::numeric)) from jsonb_array_elements(e -> 'villes') v)));
end;
$f$;
revoke all on function secoto_private.bareme_v3_public_calcul() from public, anon, authenticated;

create or replace function secoto_private.bareme_v3_public_rafraichir()
returns jsonb language plpgsql volatile security definer set search_path = '' as $f$
declare
  v jsonb := secoto_private.bareme_v3_public_calcul() || jsonb_build_object('calcule_le', now());
begin
  insert into public.app_settings(key, value, updated_at) values ('bareme_v3_public', v, now())
  on conflict (key) do update set value = excluded.value, updated_at = excluded.updated_at;
  return v;
end;
$f$;
revoke all on function secoto_private.bareme_v3_public_rafraichir() from public, anon, authenticated;

create or replace function secoto_private.bareme_v3_public_trigger()
returns trigger language plpgsql security definer set search_path = '' as $f$
begin
  perform secoto_private.bareme_v3_public_rafraichir();
  return null;
end;
$f$;
revoke all on function secoto_private.bareme_v3_public_trigger() from public, anon, authenticated;

drop trigger if exists bareme_v3_public_cache on public.app_settings;
create trigger bareme_v3_public_cache
  after insert or update of value on public.app_settings
  for each row when (new.key in ('bareme_v3', 'trois_offres'))
  execute function secoto_private.bareme_v3_public_trigger();

-- Lu par le site (clé publique « anon »). Barème v3 coupé : { actif: false }.
create or replace function public.secoto_bareme_v3_public()
returns jsonb language sql stable security definer set search_path = '' as $f$
  select case when not secoto_private.flag('bareme_v3') then jsonb_build_object('actif', false)
    else coalesce((select value from public.app_settings where key = 'bareme_v3_public'), jsonb_build_object('actif', false)) end;
$f$;
revoke all on function public.secoto_bareme_v3_public() from public;
grant execute on function public.secoto_bareme_v3_public() to anon, authenticated, service_role;

select secoto_private.bareme_v3_public_rafraichir() is not null as cache_calcule;

notify pgrst, 'reload schema';
