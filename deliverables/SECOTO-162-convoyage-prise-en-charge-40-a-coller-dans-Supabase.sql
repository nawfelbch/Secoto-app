-- ============================================================================
-- SECOTO 162 — Convoyage : forfait de prise en charge de 40 €
-- ----------------------------------------------------------------------------
-- Décision de Nawfal du 25/11/2026. Après la 161 (voiture 1,15 €/km,
-- utilitaire 1,40 €/km), les convoyages de 50 à 150 km ne laissaient encore
-- que 10 à 20 € nets dans le pire cas (URSSAF 21,2 % de la marge, carburant
-- et péages à la charge de SECOTO, carte 1,5 % + 0,25 €).
-- Règle : prix client = 40 € de prise en charge + km × tarif de la catégorie,
-- jamais sous le plancher de 60 € (inchangé). Le forfait revient entièrement à
-- SECOTO : la rémunération du convoyeur NE CHANGE PAS.
--   Voiture : 10 km 60 € · 20 km 63 € · 60 km 109 € · 100 km 155 € ·
--             500 km 615 € · 1 000 km 1 190 €.
--   Pire cas net : ≈ +34 € à 20 km, +42 € à 60 km, +50 € à 100 km, +110 € à 500 km.
-- Les petites courses (VTC, < 20 km) restent à 60–63 € (décision 068 préservée).
-- Le devis affiche une ligne « Prise en charge : 40 € ».
-- 1. price_with_grid lit un nouveau paramètre de grille, prise_en_charge_eur
--    (absent = 0 : le plateau n'est pas concerné).
-- 2. secoto_bareme_public expose convoyage.prise_en_charge (site vitrine).
-- 3. Nouvelle version de la grille convoyage avec prise_en_charge_eur = 40.
-- Nouveaux devis seulement. Migration rejouable.
-- ============================================================================

-- 1. Calcul du prix ------------------------------------------------------------
do $$
begin
  if position('prise_en_charge_eur' in pg_get_functiondef(
       'secoto_private.price_with_grid(text,jsonb,numeric,jsonb,numeric)'::regprocedure)) = 0 then
    perform secoto_private.mig074_patch(
      'secoto_private.price_with_grid(text,jsonb,numeric,jsonb,numeric)'::regprocedure,
      $a$    -- Plafond : le prix client ne monte plus, et la rémunération suit la même$a$,
      $b$    -- 162 : forfait de prise en charge (convoyage). Il revient à SECOTO :
    -- la rémunération du transporteur ne change pas.
    if coalesce((p ->> 'prise_en_charge_eur')::numeric, 0) > 0 then
      v_client := v_client + (p ->> 'prise_en_charge_eur')::numeric;
      -- Le plancher du convoyeur (12 €) reste dû même quand le forfait
      -- fait dépasser le minimum client : sa rémunération ne baisse jamais.
      v_partner := greatest(v_partner, coalesce((p ->> 'partner_minimum_eur')::numeric, 0));
      v_lines := v_lines || jsonb_build_object('label', 'Prise en charge',
        'eur', round((p ->> 'prise_en_charge_eur')::numeric, 2));
    end if;

    -- Plafond : le prix client ne monte plus, et la rémunération suit la même$b$);
  end if;
end $$;

-- 2. Barème public (site vitrine) ---------------------------------------------
do $$
begin
  if position('prise_en_charge' in pg_get_functiondef('public.secoto_bareme_public()'::regprocedure)) = 0 then
    perform secoto_private.mig074_patch(
      'public.secoto_bareme_public()'::regprocedure,
      $a$      'minimum', ((select params from c) ->> 'minimum_eur')::numeric,$a$,
      $b$      'minimum', ((select params from c) ->> 'minimum_eur')::numeric,
      'prise_en_charge', coalesce(((select params from c) ->> 'prise_en_charge_eur')::numeric, 0),  -- 162$b$);
  end if;
end $$;

-- 3. Grille convoyage ----------------------------------------------------------
do $grille$
declare
  v_params  jsonb;
  v_version integer;
begin
  select params into v_params from public.pricing_grids where mode = 'convoyage' and status = 'active';
  if v_params is null then
    raise exception 'Aucune grille convoyage active : migration impossible';
  end if;
  if (v_params ->> 'prise_en_charge_eur')::numeric = 40 then
    raise notice '162 déjà appliquée : rien à faire';
    return;
  end if;

  v_params := v_params || jsonb_build_object('prise_en_charge_eur', 40);
  perform secoto_private.validate_grid_params('convoyage', v_params);

  select coalesce(max(version), 0) + 1 into v_version from public.pricing_grids where mode = 'convoyage';
  update public.pricing_grids set status = 'archived' where mode = 'convoyage' and status = 'active';
  insert into public.pricing_grids(mode, version, status, params, source_note, activated_at)
  values ('convoyage', v_version, 'active', v_params,
          '162 (25/11/2026) : forfait de prise en charge 40 € (pour SECOTO), plancher 60 €, '
          || 'tarifs au km de la 161 et rémunération convoyeur inchangés.',
          now());
  raise notice 'Grille convoyage version % activée', v_version;
end
$grille$;

-- 4. Contrôles bloquants ------------------------------------------------------
do $controles$
declare
  v_conv jsonb;
  v_plat jsonb;
  v_prix jsonb;
  v_auto jsonb := '{"class":"voiture","category":"standard","rolling":true}';
  v_util jsonb := '{"class":"utilitaire","category":"standard","rolling":true}';
  v_moto jsonb := '{"class":"moto","category":"standard","rolling":true}';
begin
  select params into v_conv from public.pricing_grids where mode = 'convoyage' and status = 'active';

  v_prix := secoto_private.price_with_grid('convoyage', v_conv, 10, v_auto, null);
  if (v_prix ->> 'client_cents')::int <> 6000 or (v_prix ->> 'partner_cents')::int <> 1200 then
    raise exception 'Voiture 10 km : % / % (attendu 6000 / 1200)', v_prix ->> 'client_cents', v_prix ->> 'partner_cents';
  end if;
  v_prix := secoto_private.price_with_grid('convoyage', v_conv, 20, v_auto, null);
  if (v_prix ->> 'client_cents')::int <> 6300 or (v_prix ->> 'partner_cents')::int <> 1200 then
    raise exception 'Voiture 20 km : % / % (attendu 6300 / 1200)', v_prix ->> 'client_cents', v_prix ->> 'partner_cents';
  end if;
  v_prix := secoto_private.price_with_grid('convoyage', v_conv, 100, v_auto, null);
  if (v_prix ->> 'client_cents')::int <> 15500 or (v_prix ->> 'partner_cents')::int <> 5500 then
    raise exception 'Voiture 100 km : % / % (attendu 15500 / 5500)', v_prix ->> 'client_cents', v_prix ->> 'partner_cents';
  end if;
  v_prix := secoto_private.price_with_grid('convoyage', v_conv, 1000, v_auto, null);
  if (v_prix ->> 'client_cents')::int <> 119000 or (v_prix ->> 'partner_cents')::int <> 55000 then
    raise exception 'Voiture 1 000 km : % / % (attendu 119000 / 55000)', v_prix ->> 'client_cents', v_prix ->> 'partner_cents';
  end if;
  v_prix := secoto_private.price_with_grid('convoyage', v_conv, 600, v_util, null);
  if (v_prix ->> 'client_cents')::int <> 88000 or (v_prix ->> 'partner_cents')::int <> 39000 then
    raise exception 'Utilitaire 600 km : % / % (attendu 88000 / 39000)', v_prix ->> 'client_cents', v_prix ->> 'partner_cents';
  end if;
  v_prix := secoto_private.price_with_grid('convoyage', v_conv, 500, v_moto, null);
  if (v_prix ->> 'client_cents')::int <> 54000 or (v_prix ->> 'partner_cents')::int <> 27500 then
    raise exception 'Moto 500 km : % / % (attendu 54000 / 27500)', v_prix ->> 'client_cents', v_prix ->> 'partner_cents';
  end if;
  if not (v_prix -> 'lines') @> '[{"label":"Prise en charge"}]' then
    raise exception 'La ligne « Prise en charge » manque au devis : %', v_prix -> 'lines';
  end if;

  -- Le plateau n'est pas concerné.
  select params into v_plat from public.pricing_grids where mode = 'plateau' and status = 'active';
  if v_plat ? 'prise_en_charge_eur' then
    raise exception 'Forfait de prise en charge posé sur le plateau par erreur';
  end if;

  if (public.secoto_bareme_public() #>> '{convoyage,prise_en_charge}')::numeric <> 40 then
    raise exception 'Le barème public n''expose pas la prise en charge';
  end if;

  raise notice 'OK 162 : prise en charge 40 €, plancher 60 €, rémunération convoyeur inchangée, plateau inchangé.';
end
$controles$;

notify pgrst, 'reload schema';
