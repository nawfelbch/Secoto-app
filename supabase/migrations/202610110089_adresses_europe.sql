-- ============================================================================
-- SECOTO — MIGRATION 089 : ADRESSES HORS DE FRANCE (EUROPE ET MONDE)
-- ----------------------------------------------------------------------------
-- Décision de Nawfal du 11/10/2026 : « Il faut qu'on puisse obtenir un tarif
-- partout en Europe ou dans le monde […] on en perd trop à cause de ça. »
--
--   1. Une adresse porte désormais son pays (champ « country », code ISO à
--      deux lettres). Sans pays : France, comme avant. Les adresses françaises
--      gardent exactement la même vérification (code postal à 5 chiffres).
--   2. Hors de France, le code postal est facultatif (tous les pays n'en ont
--      pas) mais il doit rester propre ; la position GPS reste obligatoire.
--   3. Prix immédiat quand les deux adresses sont dans un pays de l'Union
--      européenne relié à la France par la route (ou Monaco), avec le même
--      barème qu'en France. Ailleurs (Suisse, Royaume-Uni, îles, hors d'Europe,
--      formalités de douane) : jamais de blocage, la demande part en « devis à
--      établir » chez SECOTO, comme une moto ou un quad.
--   4. Le trajet par la route est calculé SANS ferry (côté serveur) : une
--      traversée en bateau donne « itinéraire indisponible », donc un devis
--      établi par SECOTO, jamais un prix faux.
--   5. Interrupteur « adresses_internationales » (allumé) : éteint, les
--      adresses hors de France sont refusées comme avant.
--
-- ADDITIF : un interrupteur, un réglage, trois fonctions nouvelles, deux
-- fonctions existantes complétées par remplacement de repère (sans réécriture).
-- Aucune table, colonne, policy ni donnée existante modifiée. Rejouable.
-- ============================================================================

-- 1. Interrupteur et réglage -------------------------------------------------
-- La liste des interrupteurs autorisés s'élargit d'une clé (même méthode que 084).
alter table public.secoto_feature_flags drop constraint if exists secoto_feature_flags_key_check;
alter table public.secoto_feature_flags add constraint secoto_feature_flags_key_check
  check (key in ('auto_pricing', 'od_payments', 'subscriptions', 'dispatch_notifications', 'live_tracking',
                 'direct_accept', 'connect_payouts', 'plateau_paiement_direct',
                 'conditions_v2', 'commission_client',
                 'mise_en_relation_v2', 'bareme_transporteurs',
                 'adresses_internationales'));
insert into public.secoto_feature_flags(key, enabled)
values ('adresses_internationales', true)
on conflict (key) do nothing;

insert into public.app_settings(key, value)
values ('international_policy', jsonb_build_object(
  'pays_prix_immediat', jsonb_build_array(
    'FR', 'MC', 'BE', 'LU', 'NL', 'DE', 'AT', 'IT', 'ES', 'PT',
    'DK', 'SE', 'FI', 'PL', 'CZ', 'SK', 'HU', 'SI', 'HR',
    'RO', 'BG', 'GR', 'EE', 'LV', 'LT'),
  'note', 'Pays au prix immédiat (Union européenne reliée par la route, et Monaco). Les autres pays passent en devis établi par SECOTO.'))
on conflict (key) do nothing;

-- 2. Pays d'une adresse (France par défaut) ----------------------------------
create or replace function secoto_private.od_pays(p_adresse jsonb)
returns text language sql immutable set search_path = ''
as $f$
  select upper(coalesce(nullif(btrim(p_adresse ->> 'country'), ''), 'FR'));
$f$;

-- 3. Adresse recevable --------------------------------------------------------
create or replace function secoto_private.od_adresse_ok(p_adresse jsonb)
returns boolean language sql immutable set search_path = ''
as $f$
  select case
    when secoto_private.od_pays(p_adresse) = 'FR'
      then coalesce(p_adresse ->> 'postcode', '') ~ '^[0-9]{5}$'
    else secoto_private.od_pays(p_adresse) ~ '^[A-Z]{2}$'
      and (nullif(btrim(coalesce(p_adresse ->> 'postcode', '')), '') is null
           or btrim(p_adresse ->> 'postcode') ~ '^[A-Za-z0-9][A-Za-z0-9 -]{1,11}$')
  end;
$f$;

-- 4. Trajet international hors zone de prix immédiat ? -----------------------
-- null : prix immédiat possible ; sinon, motif du devis établi par SECOTO.
create or replace function secoto_private.od_raison_internationale(p_pickup jsonb, p_delivery jsonb)
returns text language sql stable security definer set search_path = ''
as $f$
  with pays as (
    select coalesce(
      (select array_agg(upper(x)) from public.app_settings s,
              jsonb_array_elements_text(s.value -> 'pays_prix_immediat') x
        where s.key = 'international_policy'),
      array['FR', 'MC']) as liste
  )
  select case
    when secoto_private.od_pays(p_pickup) = 'FR' and secoto_private.od_pays(p_delivery) = 'FR' then null
    when secoto_private.od_pays(p_pickup) = any(pays.liste)
     and secoto_private.od_pays(p_delivery) = any(pays.liste) then null
    else 'international_hors_zone'
  end
  from pays;
$f$;

-- 5. Création du devis : pays accepté, motif international -------------------
select secoto_private.mig074_patch(
  'public.secoto_quote_create(uuid,jsonb,jsonb)'::regprocedure,
  'if coalesce(v_pickup ->> ''postcode'', '''') !~ ''^[0-9]{5}$'' or coalesce(v_delivery ->> ''postcode'', '''') !~ ''^[0-9]{5}$'' then',
  'if (secoto_private.od_pays(v_pickup) <> ''FR'' or secoto_private.od_pays(v_delivery) <> ''FR'')
     and not secoto_private.flag(''adresses_internationales'') then
    raise exception ''Transport hors de France : contactez SECOTO, nous vous établissons un devis.'';
  end if;
  -- 089 : adresse française (code postal à 5 chiffres) ou étrangère (pays ISO).
  if not secoto_private.od_adresse_ok(v_pickup) or not secoto_private.od_adresse_ok(v_delivery) then');

select secoto_private.mig074_patch(
  'public.secoto_quote_create(uuid,jsonb,jsonb)'::regprocedure,
  'v_reason := v_price ->> ''manual_reason'';',
  'v_reason := coalesce(v_price ->> ''manual_reason'', secoto_private.od_raison_internationale(v_pickup, v_delivery));');

-- 6. Forfaits professionnels : zones = départements français uniquement ------
select secoto_private.mig074_patch(
  'secoto_private.sub_reserve_for_order(uuid)'::regprocedure,
  'if not (secoto_private.department_of(v_quote.pickup ->> ''postcode'') = any(v_plan.zones))',
  'if secoto_private.od_pays(v_quote.pickup) <> ''FR'' or secoto_private.od_pays(v_quote.delivery) <> ''FR''
     or not (secoto_private.department_of(v_quote.pickup ->> ''postcode'') = any(v_plan.zones))');

-- 7. Droits -------------------------------------------------------------------
revoke all on function secoto_private.od_pays(jsonb) from public, anon, authenticated;
revoke all on function secoto_private.od_adresse_ok(jsonb) from public, anon, authenticated;
revoke all on function secoto_private.od_raison_internationale(jsonb, jsonb) from public, anon, authenticated;
