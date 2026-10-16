-- SECOTO 098 — Barème client public, lu par le site vitrine au moment de sa
-- construction (une seule source de vérité : les grilles actives de l'app).
-- ----------------------------------------------------------------------------
-- Ne renvoie QUE ce que le client voit déjà dans le simulateur : prix au km par
-- catégorie, minimum, supplément non roulant, plafond. Jamais la rémunération
-- des transporteurs ni les marges.
--
-- Additif : une fonction en lecture seule. Rien n'est modifié.

create or replace function public.secoto_bareme_public()
returns jsonb language sql stable security definer set search_path = ''
as $f$
  with g as (
    select mode, version, params from public.pricing_grids where status = 'active'
  ),
  c as (select * from g where mode = 'convoyage' limit 1),
  p as (select * from g where mode = 'plateau' limit 1)
  select jsonb_build_object(
    'source', 'pricing_grids',
    'versions', jsonb_build_object('convoyage', (select version from c), 'plateau', (select version from p)),
    'convoyage', jsonb_build_object(
      'minimum', ((select params from c) ->> 'minimum_eur')::numeric,
      'eur_per_km', (select jsonb_object_agg(k, (v ->> 'client_eur_per_km')::numeric)
                       from c, jsonb_each(c.params -> 'class_rates') as e(k, v))),
    'plateau', jsonb_build_object(
      'minimum', ((select params from p) ->> 'minimum_eur')::numeric,
      'non_roulant', ((select params from p) ->> 'non_rolling_client_eur')::numeric,
      'eur_per_km', (select jsonb_object_agg(k, (v ->> 'client_eur_per_km')::numeric)
                       from p, jsonb_each(p.params -> 'class_rates') as e(k, v)),
      'plafond', coalesce((select jsonb_object_agg(k, (v ->> 'client_cap_eur')::numeric)
                       from p, jsonb_each(p.params -> 'class_rates') as e(k, v)
                      where v ? 'client_cap_eur'), '{}'::jsonb))
  );
$f$;

revoke all on function public.secoto_bareme_public() from public;
grant execute on function public.secoto_bareme_public() to anon, authenticated, service_role;
