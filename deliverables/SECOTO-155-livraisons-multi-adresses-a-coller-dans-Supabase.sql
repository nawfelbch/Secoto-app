-- ============================================================================
-- SECOTO 155 — Plusieurs adresses de livraison dans une même commande (plateau)
-- ----------------------------------------------------------------------------
-- Demande de Nawfal du 19/11/2026 (cas réel : 2 voitures Modane → Juvisy + Lisses).
--   · Le véhicule 1 va à l'adresse de livraison principale ; chaque véhicule
--     suivant peut avoir sa propre adresse (`vehicles[i].livraison`), 2 adresses
--     supplémentaires au plus.
--   · L'itinéraire est calculé par le serveur (netlify/lib/arrets.js) :
--     départ → livraison principale → autres adresses ; `route.distance_km`
--     = trajet complet, `route.arrets` = arrêts et distances des tronçons.
--   · Prix : barème habituel sur le trajet complet (− 10 % dès le 2e véhicule),
--     + forfait par arrêt supplémentaire : 40 € client, dont 30 € pour le
--     transporteur (réglages app_settings['arrets']).
--   · Pas d'Éco (dépôt en ville) ni de Navette Pro avec plusieurs adresses.
--   · Missions : chaque véhicule a SA mission avec SA bonne adresse ; la
--     mission 1 rappelle toutes les adresses dans ses notes.
-- Migration ADDITIVE et rejouable.
-- ============================================================================

insert into public.app_settings(key, value)
values ('arrets', jsonb_build_object('client_eur', 40, 'transporteur_eur', 30, 'max', 2))
on conflict (key) do nothing;

-- 1. Forfait par arrêt, ajouté au prix et à la ligne du véhicule livré à cet arrêt.
create or replace function secoto_private.ajouter_arrets(p_price jsonb, p_arrets jsonb)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  s jsonb := coalesce((select value from public.app_settings where key = 'arrets'), '{}'::jsonb);
  v_client integer := round(coalesce((s ->> 'client_eur')::numeric, 40) * 100)::int;
  v_pay integer := round(coalesce((s ->> 'transporteur_eur')::numeric, 30) * 100)::int;
  a jsonb;
  v_rang integer;
  v_n integer := 0;
  v_out jsonb := p_price;
begin
  if p_price is null or jsonb_typeof(p_arrets) <> 'array' then return p_price; end if;
  for a in select e from jsonb_array_elements(p_arrets) e loop
    v_n := v_n + 1;
    v_out := v_out || jsonb_build_object('lines', coalesce(v_out -> 'lines', '[]'::jsonb) || jsonb_build_array(jsonb_build_object(
      'label', format('Livraison supplémentaire à %s', coalesce(nullif(a ->> 'city', ''), a ->> 'label')),
      'eur', v_client / 100.0)));
    -- La mission du véhicule livré à cet arrêt porte le forfait.
    v_rang := nullif(a ->> 'vehicule', '')::int;
    if v_rang is not null and jsonb_typeof(v_out -> 'detail') = 'array' and jsonb_array_length(v_out -> 'detail') > v_rang then
      v_out := jsonb_set(v_out, array['detail', v_rang::text],
        (v_out -> 'detail' -> v_rang) || jsonb_build_object(
          'client_cents', coalesce((v_out -> 'detail' -> v_rang ->> 'client_cents')::int, 0) + v_client,
          'partner_cents', coalesce((v_out -> 'detail' -> v_rang ->> 'partner_cents')::int, 0) + v_pay));
    end if;
  end loop;
  if v_n = 0 then return p_price; end if;
  return v_out || jsonb_build_object(
    'client_cents', (v_out ->> 'client_cents')::int + v_n * v_client,
    'partner_cents', (v_out ->> 'partner_cents')::int + v_n * v_pay,
    'margin_cents', coalesce((v_out ->> 'margin_cents')::int, (v_out ->> 'client_cents')::int - (v_out ->> 'partner_cents')::int) + v_n * (v_client - v_pay),
    'collect_cents', coalesce((v_out ->> 'collect_cents')::int, (v_out ->> 'client_cents')::int) + v_n * v_client,
    'arrets_supplementaires', v_n);
end;
$$;
revoke all on function secoto_private.ajouter_arrets(jsonb, jsonb) from public, anon, authenticated;

-- 2. Devis : forfait d'arrêt + arrêts conservés dans l'itinéraire enregistré.
select secoto_private.mig074_patch(
  'public.secoto_quote_create(uuid, jsonb, jsonb)'::regprocedure,
  $a$  v_validity := least($a$,
  $b$  -- 155 : livraisons à plusieurs adresses (plateau) -> forfait par arrêt.
  if v_reason is null and v_mode = 'plateau' and jsonb_typeof(p_route -> 'arrets') = 'array'
     and jsonb_array_length(p_route -> 'arrets') > 0 then
    v_price := secoto_private.ajouter_arrets(v_price, p_route -> 'arrets');
  end if;
  v_validity := least($b$);

select secoto_private.mig074_patch(
  'public.secoto_quote_create(uuid, jsonb, jsonb)'::regprocedure,
  $a$      'provider', left(coalesce(p_route ->> 'provider', 'inconnu'), 40), 'computed_at', now()) end,$a$,
  $b$      'provider', left(coalesce(p_route ->> 'provider', 'inconnu'), 40), 'computed_at', now())
      || case when v_mode = 'plateau' and jsonb_typeof(p_route -> 'arrets') = 'array' and jsonb_array_length(p_route -> 'arrets') > 0
              then jsonb_build_object('arrets', p_route -> 'arrets', 'distance_principale_km', nullif(p_route ->> 'distance_principale_km', '')::numeric)
              else '{}'::jsonb end end,  -- 155$b$);

-- 3. Offres : avec plusieurs adresses, ni Éco (dépôt en ville) ni Navette Pro.
create or replace function secoto_private.offres_selon_arrets(p_offres jsonb, q public.transport_quotes)
returns jsonb language sql stable security definer set search_path = '' as $$
  select case
    when p_offres is null or jsonb_typeof(p_offres) <> 'array'
         or coalesce(jsonb_array_length(q.route -> 'arrets'), 0) = 0 then p_offres
    else nullif((select coalesce(jsonb_agg(e), '[]'::jsonb) from jsonb_array_elements(p_offres) e
                  where e ->> 'cle' in ('express', 'standard')), '[]'::jsonb) end;
$$;
revoke all on function secoto_private.offres_selon_arrets(jsonb, public.transport_quotes) from public, anon, authenticated;

select secoto_private.mig074_patch(
  'secoto_private.trg_quote_offres()'::regprocedure,
  $a$      new.offres := secoto_private.appliquer_avantages(secoto_private.calculer_offres(new), new);  -- 153 + 154$a$,
  $b$      new.offres := secoto_private.appliquer_avantages(secoto_private.offres_selon_arrets(secoto_private.calculer_offres(new), new), new);  -- 153 + 154 + 155$b$);

-- 4. Missions : chaque véhicule suivant part vers SA propre adresse.
select secoto_private.mig074_patch(
  'secoto_private.od_confirm(uuid)'::regprocedure,
  $a$        v_quote.pickup ->> 'city', v_quote.delivery ->> 'city',$a$,
  $b$        v_quote.pickup ->> 'city', coalesce(v_veh -> 'livraison', v_quote.delivery) ->> 'city',  -- 155$b$);
select secoto_private.mig074_patch(
  'secoto_private.od_confirm(uuid)'::regprocedure,
  $a$        v_quote.pickup ->> 'label', v_quote.delivery ->> 'label',$a$,
  $b$        v_quote.pickup ->> 'label', coalesce(v_veh -> 'livraison', v_quote.delivery) ->> 'label',  -- 155$b$);
-- Mission 1 : toutes les adresses de la tournée dans les notes.
select secoto_private.mig074_patch(
  'secoto_private.od_confirm(uuid)'::regprocedure,
  $a$      nullif(v_quote.vehicle ->> 'notes', '')), 2000),$a$,
  $b$      case when coalesce(jsonb_array_length(v_quote.route -> 'arrets'), 0) > 0
           then 'TOURNÉE : autre(s) livraison(s) ' || (select string_agg(x ->> 'label', ' puis ') from jsonb_array_elements(v_quote.route -> 'arrets') x) end,  -- 155
      nullif(v_quote.vehicle ->> 'notes', '')), 2000),$b$);

notify pgrst, 'reload schema';
