-- ============================================================================
-- SECOTO — MIGRATION 150 : L'ÉCO N'EST PLUS PROPOSÉE QU'EN GROUPAGE
-- ----------------------------------------------------------------------------
-- Décidé par Nawfal le 17/11/2026. À coller APRÈS la 149.
-- L'offre Éco (ville à ville, barèmes Éco inchangés) n'est plus proposée à
-- chaque devis. Elle se débloque seulement :
--   1. pour une demande à PLUSIEURS véhicules (Éco = somme des Éco de chaque
--      véhicule, proposée si moins chère que le Standard du groupe) ;
--   2. quand des véhicules partent déjà sur le MÊME AXE à des DATES PROCHES :
--      ex. trois clients Paris → Lyon / Marseille (A6/A7) la même semaine :
--      1er Standard, 2e Standard, le 3e voit l'Éco (débloquée à partir de
--      2 commandes réservées sur l'axe, à ± 3 jours).
-- « Même axe » : départ et arrivée (villes Éco) sur un même couloir, dans le
-- même sens, avec des trajets qui se chevauchent. Couloirs, seuil et écart de
-- dates modifiables : app_settings['bareme_v3'].eco.groupage.
-- Commandes comptées : en recherche de transporteur ou confirmées (pas les
-- demandes « paiement à valider »). Les pros ne voient toujours pas l'Éco.
-- ADDITIF, rejouable. Aucun devis ni commande existants modifiés.
-- ============================================================================

update public.app_settings
   set value = jsonb_set(value, '{eco,groupage}', jsonb_build_object(
     'actif', true,
     'debloquer_apres', 2,
     'ecart_jours', 3,
     'statuts', jsonb_build_array('searching_partner', 'partner_locked', 'partner_confirmed', 'picked_up'),
     'couloirs', jsonb_build_array(
       jsonb_build_object('nom', 'A6 / A7 / A8', 'villes', jsonb_build_array('Paris', 'Lyon', 'Marseille', 'Nice')),
       jsonb_build_object('nom', 'A6 / A7 / A9', 'villes', jsonb_build_array('Paris', 'Lyon', 'Montpellier', 'Toulouse')),
       jsonb_build_object('nom', 'A10 / A62', 'villes', jsonb_build_array('Paris', 'Bordeaux', 'Toulouse')),
       jsonb_build_object('nom', 'A11', 'villes', jsonb_build_array('Paris', 'Rennes')),
       jsonb_build_object('nom', 'A11 / A83', 'villes', jsonb_build_array('Paris', 'Nantes')),
       jsonb_build_object('nom', 'A1', 'villes', jsonb_build_array('Paris', 'Lille')),
       jsonb_build_object('nom', 'A4', 'villes', jsonb_build_array('Paris', 'Strasbourg')),
       jsonb_build_object('nom', 'Arc méditerranéen', 'villes', jsonb_build_array('Bordeaux', 'Toulouse', 'Montpellier', 'Marseille', 'Nice')))))
 where key = 'bareme_v3' and not coalesce(value -> 'eco' ? 'groupage', false);

-- Deux trajets (villes Éco) sont-ils sur le même axe, dans le même sens, et se chevauchent-ils ?
create or replace function secoto_private.eco_meme_axe(p_dep text, p_arr text, p_dep2 text, p_arr2 text)
returns boolean language sql stable security definer set search_path = '' as $$
  with c as (
    select c.value -> 'villes' as v
      from jsonb_array_elements(coalesce(secoto_private.bareme_v3_reglages() -> 'eco' -> 'groupage' -> 'couloirs', '[]'::jsonb)) c
  ), i as (
    select (select o - 1 from jsonb_array_elements_text(c.v) with ordinality x(n, o) where n = p_dep) as a,
           (select o - 1 from jsonb_array_elements_text(c.v) with ordinality x(n, o) where n = p_arr) as b,
           (select o - 1 from jsonb_array_elements_text(c.v) with ordinality x(n, o) where n = p_dep2) as a2,
           (select o - 1 from jsonb_array_elements_text(c.v) with ordinality x(n, o) where n = p_arr2) as b2
      from c
  )
  select coalesce(bool_or(
           a is not null and b is not null and a2 is not null and b2 is not null and a <> b and a2 <> b2
           and sign(b - a) = sign(b2 - a2)
           and greatest(least(a, b), least(a2, b2)) < least(greatest(a, b), greatest(a2, b2))), false)
    from i;
$$;
revoke all on function secoto_private.eco_meme_axe(text, text, text, text) from public, anon, authenticated;

-- L'Éco est-elle débloquée pour ce devis ?
create or replace function secoto_private.eco_debloquee(q public.transport_quotes)
returns boolean language plpgsql stable security definer set search_path = '' as $$
declare
  g jsonb := secoto_private.bareme_v3_reglages() -> 'eco' -> 'groupage';
  v_dep text;
  v_arr text;
  v_n integer;
begin
  if g is null or not coalesce((g ->> 'actif')::boolean, false) then return true; end if;  -- règle éteinte : comme avant
  if jsonb_array_length(coalesce(q.vehicles, '[]'::jsonb)) > 1 then return true; end if;
  v_dep := secoto_private.ville_eco(q.pickup) ->> 'nom';
  v_arr := secoto_private.ville_eco(q.delivery) ->> 'nom';
  if v_dep is null or v_arr is null or v_dep = v_arr or q.pickup_at is null then return false; end if;
  select count(*) into v_n
    from public.transport_orders o
    join public.transport_quotes oq on oq.id = o.quote_id
   where o.mode = 'plateau' and not coalesce(o.is_test, false)
     and o.status in (select jsonb_array_elements_text(g -> 'statuts'))
     and o.pickup_at between q.pickup_at - make_interval(days => coalesce((g ->> 'ecart_jours')::int, 3))
                         and q.pickup_at + make_interval(days => coalesce((g ->> 'ecart_jours')::int, 3))
     and secoto_private.eco_meme_axe(v_dep, v_arr,
           secoto_private.ville_eco(oq.pickup) ->> 'nom', secoto_private.ville_eco(oq.delivery) ->> 'nom');
  return v_n >= coalesce((g ->> 'debloquer_apres')::int, 2);
end;
$$;
revoke all on function secoto_private.eco_debloquee(public.transport_quotes) from public, anon, authenticated;

-- Éco d'une demande à plusieurs véhicules : somme des Éco de chaque véhicule (barèmes Éco inchangés).
create or replace function secoto_private.offre_eco_groupe(q public.transport_quotes, p_std_client integer)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v jsonb;
  s public.transport_quotes;
  e jsonb;
  v_first jsonb;
  v_client integer := 0;
  v_pay integer := 0;
  v_places numeric := 0;
begin
  for v in select value from jsonb_array_elements(coalesce(q.vehicles, '[]'::jsonb)) loop
    s := q;
    s.vehicle := v;
    s.vehicles := '[]'::jsonb;
    e := secoto_private.offre_eco_v3(s, 2147483647);
    if e is null then return null; end if;
    v_first := coalesce(v_first, e);
    v_client := v_client + (e ->> 'client_cents')::int;
    v_pay := v_pay + (e ->> 'partenaire_cents')::int;
    v_places := v_places + coalesce((e ->> 'places')::numeric, 1);
  end loop;
  if v_first is null or v_client >= coalesce(p_std_client, 0) then return null; end if;
  return v_first || jsonb_build_object('client_cents', v_client, 'partenaire_cents', v_pay,
                                       'commission_cents', v_client - v_pay, 'places', v_places,
                                       'vehicules', jsonb_array_length(q.vehicles));
end;
$$;
revoke all on function secoto_private.offre_eco_groupe(public.transport_quotes, integer) from public, anon, authenticated;

-- Offres : Éco seulement en groupage (plusieurs véhicules, ou même axe à dates proches).
create or replace function secoto_private.calculer_offres(q public.transport_quotes)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  r jsonb := secoto_private.trois_offres_reglages();
  l jsonb := secoto_private.bareme_v3_reglages() -> 'lourds';
  v_km numeric := (q.route ->> 'distance_km')::numeric;
  v_multi boolean := jsonb_array_length(coalesce(q.vehicles, '[]'::jsonb)) > 1;
  v_lourd boolean := not (jsonb_array_length(coalesce(q.vehicles, '[]'::jsonb)) > 1)
                     and secoto_private.est_lourd(secoto_private.gabarit_vehicule(q.vehicle));
  v_coef numeric := coalesce((r -> 'express' ->> 'coef')::numeric, 1.30);
  v_std_client integer := q.client_price_cents;
  v_std_pay integer := q.partner_pay_cents;
  v_exp_client integer;
  v_exp_pay integer;
  v_n integer;
  v_eco jsonb;
  v_navette jsonb;
  v_pro boolean;
  v_out jsonb := '[]'::jsonb;
begin
  if not secoto_private.flag('trois_offres') or q.mode <> 'plateau' or q.status <> 'priced'
     or v_std_client is null or v_std_pay is null or coalesce(v_km, 0) <= 0 or (q.vehicle ->> 'class') is null
     or coalesce(q.vehicle ->> 'category', 'standard') <> 'standard' then
    return null;
  end if;
  -- 145 : Navette Pro (comptes pros, sur les axes), y compris à plusieurs véhicules.
  v_pro := secoto_private.devis_compte_pro(q);
  v_navette := case when v_pro then secoto_private.offre_navette_pro(q, v_std_client) end;
  -- 150 : Éco seulement en groupage, jamais pour un pro.
  if v_navette is null and not v_pro and secoto_private.flag('bareme_v3') and secoto_private.eco_debloquee(q) then
    v_eco := case when v_multi then secoto_private.offre_eco_groupe(q, v_std_client)
                  else secoto_private.offre_eco_v3(q, v_std_client) end;
    if v_eco is not null then
      v_eco := v_eco || jsonb_build_object('regles', coalesce(v_eco ->> 'regles', '') || case when v_multi
        then ' Tarif groupé pour vos véhicules.'
        else ' Offre débloquée : d''autres véhicules partent sur cet axe à ces dates.' end);
    end if;
  end if;
  if v_multi and v_navette is null and v_eco is null then return null; end if;

  -- Transporteurs vérifiés qui couvrent ce trajet (affiché au client, plus bloquant).
  select count(distinct secoto_private.carrier_rate_owner(a.id)) into v_n
    from public.accounts a
   where a.role::text = 'transporter' and a.deleted_at is null
     and secoto_private.carrier_eligible_for_trip(a.id, q.vehicle, q.pickup, q.pickup_at);

  if v_lourd then
    -- 149 : utilitaire, caravane, camping-car — prix au km (particulier ou pro), Express + 10 % transporteur.
    if v_pro then v_std_client := secoto_private.lourds_offre_cents(v_std_pay, v_km, true, false); end if;
    v_exp_pay := round(v_std_pay * coalesce((l ->> 'express_transporteur_coef')::numeric, 1.10))::int;
    v_exp_client := secoto_private.lourds_offre_cents(v_exp_pay, v_km, v_pro, true, v_std_client);
  else
    v_exp_client := round(v_std_client * v_coef)::int;
    v_exp_pay := round(v_std_pay * v_coef)::int;
  end if;

  v_out := v_out || jsonb_build_array(jsonb_build_object(
    'cle', 'express', 'libelle', 'Express',
    'client_cents', v_exp_client, 'partenaire_cents', v_exp_pay, 'commission_cents', v_exp_client - v_exp_pay,
    'fenetre_h', coalesce((r -> 'express' ->> 'fenetre_h')::int, 48), 'transporteurs', v_n, 'recommande', false));
  v_out := v_out || jsonb_build_array(jsonb_build_object(
    'cle', 'standard', 'libelle', 'Standard',
    'client_cents', v_std_client, 'partenaire_cents', v_std_pay, 'commission_cents', v_std_client - v_std_pay,
    'fenetre_h', coalesce((r -> 'standard' ->> 'fenetre_h')::int, 120), 'transporteurs', v_n,
    'recommande', v_navette is null));
  if v_navette is not null then
    v_out := v_out || jsonb_build_array(v_navette || jsonb_build_object('transporteurs', v_n));
  elsif v_eco is not null then
    v_out := v_out || jsonb_build_array(v_eco || jsonb_build_object('transporteurs', v_n));
  end if;
  return v_out;
end;
$$;
revoke all on function secoto_private.calculer_offres(public.transport_quotes) from public, anon, authenticated;

-- Site vitrine : l'Éco n'est plus affichée au simulateur (proposée dans l'app en groupage).
select secoto_private.mig074_patch(
  'secoto_private.bareme_v3_public_calcul()'::regprocedure,
  $a$      'delai_h', coalesce((t -> 'eco' ->> 'fenetre_h')::int, 360),$a$,
  $b$      'delai_h', coalesce((t -> 'eco' ->> 'fenetre_h')::int, 360),
      'sur_groupage', coalesce((e -> 'groupage' ->> 'actif')::boolean, false),  -- 150$b$);
select secoto_private.bareme_v3_public_rafraichir() is not null as site_recalcule;

notify pgrst, 'reload schema';
