-- ============================================================================
-- SECOTO — MIGRATION 149 : NOUVELLE GRILLE (LOURDS AU KM, PRO, VOITURES, MULTI)
-- ----------------------------------------------------------------------------
-- Validé par Nawfal le 17/11/2026 : « on arrête de casser les prix ». À coller
-- APRÈS la 148.
--
-- 1. Utilitaire, caravane, camping-car (prix par véhicule) :
--    · Particulier : Standard 2,20 €/km (minimum 550 €), Express 2,40 €/km
--      (au moins Standard + 10 %) ;
--    · Pro (client_type 'pro') : Standard 2,00 €/km (minimum 500 €), Express
--      2,20 €/km (au moins Standard pro + 10 %) ;
--    · toujours au moins 75 € nets pour SECOTO après URSSAF (21,2 % de la
--      marge) et frais de paiement (5 % particulier, 1,5 % pro) ;
--    · rémunération transporteur : courbe 144 inchangée ; Express : + 10 %.
-- 2. Voitures : tranches 0,98 / 0,85 / 0,75 €/km (au lieu de 0,95 / 0,80 /
--    0,70), soit + 3 à 5 %. Minimums et motos inchangés.
-- 3. Plusieurs véhicules : chaque véhicule est calculé avec ce barème, puis
--    − 10 % à partir du 2e (client et transporteur), jamais sous la marge
--    minimale. Remplace l'ancien moteur (1,25 €/km, − 25 %). La rustine 148
--    reste en secours si un véhicule ne peut pas être tarifé.
-- Réglages : app_settings['bareme_v3'] (lourds, tranches, groupe_remise_pct).
-- ADDITIF, rejouable. Aucun devis ni commande existants modifiés.
-- ============================================================================

-- 1. Réglages.
update public.app_settings
   set value = jsonb_set(
                 jsonb_set(value, '{lourds}', coalesce(value -> 'lourds', '{}'::jsonb) || jsonb_build_object(
                   'client_eur_km', 2.20, 'client_express_eur_km', 2.40, 'client_min_eur', 550,
                   'pro_eur_km', 2.00, 'pro_express_eur_km', 2.20, 'pro_min_eur', 500,
                   'pro_frais_paiement_pct', 1.5,
                   'express_min_coef', 1.10, 'express_transporteur_coef', 1.10, 'express_coef', 1.10)),
                 '{tranches}', jsonb_build_array(
                   jsonb_build_object('eur_km', 0.98, 'jusqu_a_km', 300),
                   jsonb_build_object('eur_km', 0.85, 'jusqu_a_km', 700),
                   jsonb_build_object('eur_km', 0.75, 'jusqu_a_km', null)))
               || jsonb_build_object('groupe_remise_pct', 10)
 where key = 'bareme_v3' and not coalesce(value -> 'lourds' ? 'client_eur_km', false);

-- 2. Prix client d'un véhicule lourd (centimes), Standard ou Express, particulier ou pro.
create or replace function secoto_private.lourds_offre_cents(p_pay_cents integer, p_km numeric, p_pro boolean,
                                                            p_express boolean, p_std_cents integer default null)
returns integer language plpgsql stable security definer set search_path = '' as $$
declare
  l jsonb := secoto_private.bareme_v3_reglages() -> 'lourds';
  u numeric := coalesce((l ->> 'urssaf_pct')::numeric, 21.2) / 100;
  k numeric := case when p_pro then coalesce((l ->> 'pro_frais_paiement_pct')::numeric, 1.5)
                    else coalesce((l ->> 'frais_paiement_pct')::numeric, 5) end / 100;
  v_net numeric := coalesce((l ->> 'net_min_eur')::numeric, 75) * 100;
  v_rate numeric := coalesce((l ->> case when p_pro and p_express then 'pro_express_eur_km'
                                         when p_pro then 'pro_eur_km'
                                         when p_express then 'client_express_eur_km'
                                         else 'client_eur_km' end)::numeric,
                             case when p_pro and p_express then 2.20 when p_pro then 2.00 when p_express then 2.40 else 2.20 end);
  v_min numeric := coalesce((l ->> case when p_pro then 'pro_min_eur' else 'client_min_eur' end)::numeric,
                            case when p_pro then 500 else 550 end) * 100;
  v_plancher numeric;
  v_km numeric;
begin
  -- Plancher de rentabilité : prix - pay - k*prix - u*(prix - pay) >= net.
  v_plancher := ceil(((v_net + (1 - u) * p_pay_cents) / (1 - k - u)) / 500) * 500;
  v_km := ceil(greatest(coalesce(p_km, 0), 0) * v_rate * 100 / 500) * 500;
  if p_express then
    return greatest(v_plancher, v_km,
                    ceil(coalesce(p_std_cents, 0) * coalesce((l ->> 'express_min_coef')::numeric, 1.10) / 500) * 500)::int;
  end if;
  return greatest(v_plancher, v_km, v_min)::int;
end;
$$;
revoke all on function secoto_private.lourds_offre_cents(integer, numeric, boolean, boolean, integer) from public, anon, authenticated;

-- 3. Barème v3 : prix Standard particulier des lourds au km.
select secoto_private.mig074_patch(
  'secoto_private.bareme_v3(jsonb,jsonb,jsonb,jsonb,numeric)'::regprocedure,
  $a$    v_client := secoto_private.lourds_client_cents(v_pay_c, round((g ->> 'minimum_eur')::numeric * 100)::int);$a$,
  $b$    v_client := secoto_private.lourds_offre_cents(v_pay_c, v_km, false, false);  -- 149 : 2,20 €/km, 550 € minimum$b$);

-- 4. Plusieurs véhicules : chaque véhicule au barème v3, − 10 % dès le 2e.
create or replace function secoto_private.bareme_v3_groupe(p_price jsonb, p_vehicles jsonb, p_pickup jsonb,
                                                          p_delivery jsonb, p_km numeric)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  b jsonb := secoto_private.bareme_v3_reglages();
  v_remise numeric := coalesce((b ->> 'groupe_remise_pct')::numeric, 10) / 100;
  v_marge_min integer := round(coalesce((b ->> 'marge_min_eur')::numeric, 75) * 100)::int;
  v record;
  r jsonb;
  c integer; p integer; c2 integer; p2 integer;
  v_client integer := 0; v_pay integer := 0; v_rem integer := 0;
  v_lines jsonb := '[]'::jsonb;
  v_detail jsonb := '[]'::jsonb;
begin
  if not secoto_private.flag('bareme_v3') or jsonb_array_length(coalesce(p_vehicles, '[]'::jsonb)) < 2 then
    return p_price;
  end if;
  for v in select value as veh, ordinality as rang from jsonb_array_elements(p_vehicles) with ordinality loop
    r := secoto_private.bareme_v3('{}'::jsonb, v.veh, p_pickup, p_delivery, p_km);
    if r ? 'manual_reason' or (r ->> 'client_cents') is null then
      -- Un véhicule hors barème : devis établi par SECOTO.
      return p_price || jsonb_build_object('manual_reason', coalesce(r ->> 'manual_reason', 'sur_devis_plusieurs_vehicules'));
    end if;
    c := (r ->> 'client_cents')::int;
    p := (r ->> 'partner_cents')::int;
    c2 := c; p2 := p;
    if v.rang > 1 then
      c2 := round(c * (1 - v_remise))::int;
      p2 := round(p * (1 - v_remise))::int;
      if c2 - p2 < v_marge_min then p2 := c2 - v_marge_min; end if;
      v_rem := v_rem + (c - c2);
    end if;
    v_client := v_client + c2;
    v_pay := v_pay + p2;
    v_lines := v_lines || jsonb_build_array(jsonb_build_object(
      'label', format('Véhicule %s - %s', v.rang, coalesce(nullif(v.veh ->> 'model', ''), 'véhicule')), 'eur', round(c / 100.0, 2)));
    v_detail := v_detail || jsonb_build_array(jsonb_build_object(
      'rang', v.rang, 'gabarit', secoto_private.gabarit_vehicule(v.veh), 'client_cents', c2, 'partner_cents', p2,
      'remise_cents', c - c2, 'pricing', coalesce(r -> 'detail' -> 0 ->> 'pricing', 'bareme_secoto_v3')));
  end loop;
  if v_rem > 0 then
    v_lines := v_lines || jsonb_build_array(jsonb_build_object(
      'label', format('Remise à partir du 2e véhicule (−%s %%)', round(v_remise * 100)), 'eur', - round(v_rem / 100.0, 2)));
  end if;
  return (p_price - 'manual_reason') || jsonb_build_object(
    'client_cents', v_client, 'partner_cents', v_pay, 'margin_cents', v_client - v_pay, 'collect_cents', v_client,
    'lines', v_lines, 'detail', v_detail, 'remise_groupage_cents', v_rem, 'groupe_v3', true);
end;
$$;
revoke all on function secoto_private.bareme_v3_groupe(jsonb, jsonb, jsonb, jsonb, numeric) from public, anon, authenticated;

-- Branchement dans la création de devis (avant la rustine 148, qui reste en secours).
select secoto_private.mig074_patch(
  'public.secoto_quote_create(uuid,jsonb,jsonb)'::regprocedure,
  $a$  -- 148 : plusieurs véhicules dont un utilitaire, une caravane ou un camping-car -> devis manuel.$a$,
  $b$  -- 149 : plusieurs véhicules -> chaque véhicule au barème v3, − 10 % dès le 2e.
  if v_reason is null and v_mode = 'plateau' and jsonb_array_length(v_vehicles) > 1 then
    v_price := secoto_private.bareme_v3_groupe(v_price, v_vehicles, v_pickup, v_delivery, v_distance);
    v_reason := v_price ->> 'manual_reason';
  end if;
  -- 148 : plusieurs véhicules dont un utilitaire, une caravane ou un camping-car -> devis manuel.$b$);
select secoto_private.mig074_patch(
  'public.secoto_quote_create(uuid,jsonb,jsonb)'::regprocedure,
  $a$    v_reason := 'sur_devis_plusieurs_lourds';$a$,
  $b$    if not coalesce((v_price ->> 'groupe_v3')::boolean, false) then v_reason := 'sur_devis_plusieurs_lourds'; end if;  -- 149$b$);

-- 5. Offres : Express des lourds au km (+ 10 % transporteur), prix pro des lourds.
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
  if v_multi and v_navette is null then return null; end if;

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
  elsif not v_pro and secoto_private.flag('bareme_v3') then
    -- Éco : particuliers seulement (un pro ne la voit pas).
    v_eco := secoto_private.offre_eco_v3(q, v_std_client);
    if v_eco is not null then
      v_out := v_out || jsonb_build_array(v_eco || jsonb_build_object('transporteurs', v_n));
    end if;
  end if;
  return v_out;
end;
$$;
revoke all on function secoto_private.calculer_offres(public.transport_quotes) from public, anon, authenticated;

-- 6. Site vitrine : règles Express des lourds, puis table publique recalculée.
select secoto_private.mig074_patch(
  'secoto_private.bareme_v3_public_calcul()'::regprocedure,
  $a$'eco', coalesce((b -> 'lourds' ->> 'eco')::boolean, false)),$a$,
  $b$'eco', coalesce((b -> 'lourds' ->> 'eco')::boolean, false),
                                 'express_eur_km', coalesce((b -> 'lourds' ->> 'client_express_eur_km')::numeric, 2.40),  -- 149
                                 'express_min_coef', coalesce((b -> 'lourds' ->> 'express_min_coef')::numeric, 1.10)),$b$);
select secoto_private.bareme_v3_public_rafraichir() is not null as site_recalcule;

notify pgrst, 'reload schema';
