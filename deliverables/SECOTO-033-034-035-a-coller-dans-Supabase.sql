-- ============================================================================
-- SECOTO — À COLLER DANS SUPABASE (SQL Editor), PROJET « SECOTO CONVOYEURS »
-- ----------------------------------------------------------------------------
-- Ce fichier réunit, DANS L'ORDRE, trois migrations :
--   033  correctif des droits (rétablit l'accès des comptes)
--   034  barème commercial du 18/09/2026
--   035  parcours de commande définitif
--
-- Exécutez-le EN UNE SEULE FOIS, de haut en bas. Il est rejouable : le relancer
-- ne crée pas de doublon et ne modifie aucune commande en cours.
-- Aucun interrupteur n'est activé par ce fichier : l'application ne change pas
-- tant que vous ne les ouvrez pas vous-même (dernière section, commentée).
-- ============================================================================


-- ####################################################################
-- ## 202609180033_correctif_droits_helpers
-- ####################################################################
-- ============================================================================
-- SECOTO — CORRECTIF 033 : droits d'exécution des helpers secoto_private
-- ----------------------------------------------------------------------------
-- INCIDENT. Les migrations 030 à 032 contenaient un
--   revoke all on all functions in schema secoto_private from public, anon, authenticated;
-- qui a retiré les droits posés par les migrations 003 et 008 sur les helpers
-- appelés PAR LES POLITIQUES RLS (secoto_private.current_is_admin,
-- can_read_mission, current_role…). Ces fonctions sont évaluées avec l'identité
-- de l'utilisateur : sans droit d'exécution, PostgreSQL refuse la lecture de
-- public.accounts et de toutes les tables protégées. Symptôme observé :
-- « Session connectée, mais aucun profil SECOTO valide n'est relié à ce
-- compte » pour les clients, les transporteurs ET les administrateurs.
--
-- Ce correctif restaure EXACTEMENT les droits antérieurs à la 030, et rien de
-- plus. Il est additif, rejouable, et n'ouvre aucun nouvel accès.
-- ============================================================================

begin;

do $restore$
declare
  v_item text;
  -- fonction => rôles à qui restituer l'exécution (état d'avant la 030)
  v_grants constant text[][] := array[
    ['secoto_private.current_is_admin()', 'authenticated, public'],
    ['secoto_private."current_role"()', 'authenticated, public'],
    ['secoto_private.can_read_mission(uuid)', 'authenticated'],
    ['secoto_private.can_read_document_path(text,boolean)', 'authenticated'],
    ['secoto_private.can_write_mission_file(uuid)', 'authenticated'],
    ['secoto_private.can_upload_tracking_file(uuid)', 'authenticated, public'],
    ['secoto_private.transporter_matches_mission(uuid,uuid)', 'public'],
    ['secoto_private.current_transporter_matches_mission(uuid)', 'public'],
    ['secoto_private.claim_phone_matches(text,text)', 'public'],
    ['secoto_private.normalize_claim_email(text)', 'public'],
    ['secoto_private.normalize_claim_phone(text)', 'public'],
    ['secoto_private.safe_vehicle_category(jsonb)', 'public'],
    ['secoto_private.scan_groupages(uuid)', 'public'],
    ['secoto_private.queue_email(uuid,text,text,uuid,text)', 'public'],
    ['secoto_private.enqueue_push_outbox()', 'public'],
    ['secoto_private.prepare_notification()', 'public'],
    ['secoto_private.neutralize_removed_surcharges()', 'public'],
    ['secoto_private.trg_account_created_notify()', 'public'],
    ['secoto_private.trg_mission_delivered_notify()', 'public'],
    ['secoto_private.trg_mission_scan_groupages()', 'public'],
    -- Helper de la migration 031, appelé par les politiques Storage du bucket
    -- privé « business-private » avec l'identité de l'utilisateur.
    ['secoto_private.is_business_member(uuid,uuid)', 'authenticated']
  ];
begin
  for i in 1 .. array_length(v_grants, 1) loop
    v_item := v_grants[i][1];
    if to_regprocedure(v_item) is not null then
      execute format('grant execute on function %s to %s', v_item, v_grants[i][2]);
    else
      raise notice 'Fonction absente, ignorée : %', v_item;
    end if;
  end loop;
end
$restore$;

-- Contrôle immédiat : la lecture des comptes doit redevenir possible pour un
-- utilisateur authentifié. Si ce bloc échoue, la migration est annulée.
do $verif$
declare v_ok boolean;
begin
  select has_function_privilege('authenticated', 'secoto_private.current_is_admin()', 'execute')
     and has_function_privilege('authenticated', 'secoto_private.can_read_mission(uuid)', 'execute')
     and has_function_privilege('authenticated', 'secoto_private."current_role"()', 'execute')
    into v_ok;
  if not v_ok then
    raise exception 'Correctif 033 incomplet : les helpers RLS ne sont pas exécutables par authenticated.';
  end if;
end
$verif$;

notify pgrst, 'reload schema';
commit;


-- ####################################################################
-- ## 202609180034_bareme_secoto_2026
-- ####################################################################
-- ============================================================================
-- SECOTO — MIGRATION 034 : BARÈME COMMERCIAL DU 18/09/2026
-- ----------------------------------------------------------------------------
-- Décisions Nawfal Bouchaib (SECOTO) du 18/09/2026.
--
-- PLATEAU (sous-traitance : SECOTO vend le transport, le transporteur exécute)
--   Prix client au kilomètre :
--     voiture                      1,12 €/km
--     moto                         1,00 €/km, le prix ne dépasse jamais 400 €
--     utilitaire / VL / caravane   1,25 €/km
--   Véhicule non roulant           + 80 € (treuil)
--   Plancher                       115 € (inchangé depuis la migration 009)
--   Rémunération transporteur, JAMAIS affichée au client :
--     voiture 0,97 €/km · moto 0,85 €/km · utilitaire 1,10 €/km · non roulant + 60 €
--
-- CONVOYAGE (par la route, conducteur)
--   Prix client                    1,00 €/km, tout compris, toutes catégories
--   Plancher                       115 €
--   Rémunération convoyeur         0,55 €/km · 0,65 €/km sur utilitaire
--
-- ENCAISSEMENT : SECOTO encaisse la TOTALITÉ du prix client, dans les deux
-- modes, puis reverse le transporteur. Plus aucun paiement direct au partenaire.
--
-- Plafond et plancher s'appliquent au prix client ET à la rémunération, dans la
-- même proportion : la marge ne peut jamais devenir négative sur les extrêmes.
--
-- Additive et rejouable. Les barèmes précédents sont archivés, jamais
-- supprimés : un devis déjà émis garde la version qui l'a produit.
-- ============================================================================

begin;

do $guard$
begin
  if to_regprocedure('secoto_private.price_with_grid(text,jsonb,numeric,jsonb,numeric)') is null then
    raise exception 'Migration 030 requise avant la 034.';
  end if;
end
$guard$;

-- ----------------------------------------------------------------------------
-- 1. MOTEUR DE PRIX
-- ----------------------------------------------------------------------------
-- Deux méthodes cohabitent :
--   pricing_method = 'per_class' : un tarif au km par catégorie (barèmes 034)
--   sinon                        : les paliers historiques (barème 009 archivé)
-- Les devis déjà émis conservent leurs montants : rien n'est recalculé.
create or replace function secoto_private.price_with_grid(
  p_mode text, p jsonb, p_distance_km numeric, p_vehicle jsonb, p_hours_to_pickup numeric
)
returns jsonb language plpgsql immutable set search_path = ''
as $f$
declare
  v_km numeric := round(coalesce(p_distance_km, 0), 1);
  v_class text := coalesce(p_vehicle ->> 'class', '');
  v_rolling boolean := coalesce((p_vehicle ->> 'rolling')::boolean, true);
  v_client numeric := 0;
  v_partner numeric;
  v_margin numeric;
  v_floor numeric := 0;
  v_tier jsonb;
  v_upto numeric;
  v_rate numeric;
  v_lines jsonb := '[]'::jsonb;
  v_urgent_pct numeric := coalesce((p ->> 'urgent_pct')::numeric, 0);
  v_rule jsonb;
  v_client_rate numeric;
  v_partner_rate numeric;
  v_cap numeric;
  v_minimum numeric := coalesce((p ->> 'minimum_eur')::numeric, 0);
  v_capped boolean := false;
  v_nr_client numeric;
  v_nr_partner numeric;
begin
  if v_km <= 0 then
    return jsonb_build_object('manual_reason', 'distance_indisponible');
  end if;
  if not (v_class in (select jsonb_array_elements_text(coalesce(p -> 'auto_vehicle_classes', '[]'::jsonb)))) then
    return jsonb_build_object('manual_reason', 'categorie_vehicule_hors_bareme');
  end if;
  if p ? 'auto_max_km' and v_km > (p ->> 'auto_max_km')::numeric then
    return jsonb_build_object('manual_reason', 'distance_hors_bareme_automatique');
  end if;
  if coalesce(p_vehicle ->> 'category', 'standard') = 'luxury' and not coalesce((p ->> 'luxury_auto')::boolean, false) then
    return jsonb_build_object('manual_reason', 'vehicule_prestige');
  end if;
  if jsonb_typeof(p_vehicle -> 'constraints') = 'array' and jsonb_array_length(p_vehicle -> 'constraints') > 0
     and not coalesce((p ->> 'constraints_auto')::boolean, false) then
    return jsonb_build_object('manual_reason', 'contraintes_particulieres');
  end if;
  if not v_rolling then
    if p_mode = 'convoyage' then
      return jsonb_build_object('manual_reason', 'convoyage_impossible_vehicule_non_roulant');
    elsif not coalesce((p ->> 'non_rolling_auto')::boolean, false) then
      return jsonb_build_object('manual_reason', 'vehicule_non_roulant');
    end if;
  end if;
  if p_hours_to_pickup is not null and p_hours_to_pickup < coalesce((p ->> 'min_notice_hours')::numeric, 0) then
    return jsonb_build_object('manual_reason', 'delai_trop_court');
  end if;

  -- ======== Barème par catégorie (034) ========
  if p ->> 'pricing_method' = 'per_class' then
    v_rule := p -> 'class_rates' -> v_class;
    if v_rule is null then
      return jsonb_build_object('manual_reason', 'categorie_vehicule_hors_bareme');
    end if;
    v_client_rate := (v_rule ->> 'client_eur_per_km')::numeric;
    v_partner_rate := (v_rule ->> 'partner_eur_per_km')::numeric;
    if v_client_rate is null or v_partner_rate is null or v_client_rate <= 0 or v_partner_rate < 0 then
      return jsonb_build_object('manual_reason', 'remuneration_partenaire_non_definie');
    end if;

    v_client := v_km * v_client_rate;
    v_partner := v_km * v_partner_rate;
    v_lines := v_lines || jsonb_build_object(
      'label', format('%s km × %s €/km',
        trim(trailing '.' from to_char(v_km, 'FM999990D9')), to_char(v_client_rate, 'FM990D00')),
      'eur', round(v_client, 2));

    -- Plafond : le prix client ne monte plus, et la rémunération suit la même
    -- proportion (sinon la marge s'effondre sur les longues distances).
    v_cap := (v_rule ->> 'client_cap_eur')::numeric;
    if v_cap is not null and v_client > v_cap then
      v_partner := round(v_cap * v_partner_rate / v_client_rate, 2);
      v_client := v_cap;
      v_capped := true;
      v_lines := v_lines || jsonb_build_object(
        'label', format('Prix plafonné à %s €', to_char(v_cap, 'FM999990D00')), 'eur', v_cap);
    end if;

    -- Plancher : même logique, la part transporteur suit le rapport de sa catégorie.
    if v_client < v_minimum then
      v_partner := greatest(v_partner, round(v_minimum * v_partner_rate / v_client_rate, 2));
      v_client := v_minimum;
      v_lines := v_lines || jsonb_build_object('label', 'Forfait minimum', 'eur', v_minimum);
    end if;

    -- Véhicule non roulant : supplément forfaitaire (treuil, manutention).
    if not v_rolling then
      v_nr_client := coalesce((p ->> 'non_rolling_client_eur')::numeric, 0);
      v_nr_partner := coalesce((p ->> 'non_rolling_partner_eur')::numeric, 0);
      if v_nr_partner >= v_nr_client then
        return jsonb_build_object('manual_reason', 'supplement_non_roulant_non_defini');
      end if;
      v_client := v_client + v_nr_client;
      v_partner := v_partner + v_nr_partner;
      v_lines := v_lines || jsonb_build_object(
        'label', 'Véhicule non roulant (treuil)', 'eur', v_nr_client);
    end if;

    if v_urgent_pct > 0 and p_hours_to_pickup is not null
       and p_hours_to_pickup < coalesce((p ->> 'urgent_threshold_hours')::numeric, 24) then
      v_lines := v_lines || jsonb_build_object('label', format('Urgence (+%s %%)', v_urgent_pct), 'eur', round(v_client * v_urgent_pct / 100, 2));
      v_client := v_client * (1 + v_urgent_pct / 100);
      v_partner := v_partner * (1 + v_urgent_pct / 100);
    end if;

    v_client := round(v_client, 2);
    v_partner := round(v_partner, 2);
    v_margin := round(v_client - v_partner, 2);

    if v_margin < v_client * coalesce((p ->> 'min_margin_pct')::numeric, 0) / 100 then
      return jsonb_build_object('manual_reason', 'marge_insuffisante');
    end if;

    -- SECOTO encaisse la totalité du prix client, dans les deux modes.
    return jsonb_build_object(
      'client_cents', (v_client * 100)::integer,
      'partner_cents', (v_partner * 100)::integer,
      'margin_cents', (v_margin * 100)::integer,
      'collect_cents', (v_client * 100)::integer,
      'transport_direct_cents', 0,
      'capped', v_capped,
      'lines', v_lines,
      'included', coalesce(p -> 'included', '[]'::jsonb),
      'excluded', coalesce(p -> 'excluded', '[]'::jsonb));
  end if;

  -- ======== Paliers historiques (barèmes archivés) ========
  if p ->> 'tier_method' = 'global' then
    for v_tier in select value from jsonb_array_elements(p -> 'tiers') loop
      v_upto := (v_tier ->> 'up_to_km')::numeric;
      if v_upto is null or v_km <= v_upto then
        v_rate := (v_tier ->> 'eur_per_km')::numeric;
        v_client := v_km * v_rate;
        v_lines := v_lines || jsonb_build_object('label', format('%s km × %s €/km', v_km, v_rate), 'eur', round(v_client, 2));
        exit;
      end if;
    end loop;
  else
    v_floor := 0;
    for v_tier in select value from jsonb_array_elements(p -> 'tiers') loop
      exit when v_km <= v_floor;
      v_upto := (v_tier ->> 'up_to_km')::numeric;
      v_rate := (v_tier ->> 'eur_per_km')::numeric;
      v_client := v_client + (least(v_km, coalesce(v_upto, v_km)) - v_floor) * v_rate;
      v_lines := v_lines || jsonb_build_object(
        'label', format('%s à %s km × %s €/km', v_floor, least(v_km, coalesce(v_upto, v_km)), v_rate),
        'eur', round((least(v_km, coalesce(v_upto, v_km)) - v_floor) * v_rate, 2));
      v_floor := coalesce(v_upto, v_km);
    end loop;
  end if;

  if v_client < v_minimum then
    v_lines := v_lines || jsonb_build_object('label', 'Forfait minimum', 'eur', v_minimum);
    v_client := v_minimum;
  end if;

  if v_urgent_pct > 0 and p_hours_to_pickup is not null
     and p_hours_to_pickup < coalesce((p ->> 'urgent_threshold_hours')::numeric, 24) then
    v_lines := v_lines || jsonb_build_object('label', format('Urgence (+%s %%)', v_urgent_pct), 'eur', round(v_client * v_urgent_pct / 100, 2));
    v_client := v_client * (1 + v_urgent_pct / 100);
  end if;
  v_client := round(v_client, 2);

  if p -> 'partner_eur_per_km_by_class' ? v_class then
    v_partner := v_km * (p -> 'partner_eur_per_km_by_class' ->> v_class)::numeric;
  elsif p ? 'partner_eur_per_km' then
    v_partner := v_km * (p ->> 'partner_eur_per_km')::numeric
      + v_km * coalesce((p ->> 'approach_eur_per_km')::numeric, 0)
      + coalesce((p ->> 'return_positioning_eur')::numeric, 0);
  elsif p ? 'partner_share_pct' then
    v_partner := v_client * (p ->> 'partner_share_pct')::numeric / 100;
  else
    return jsonb_build_object('manual_reason', 'remuneration_partenaire_non_definie');
  end if;
  v_partner := round(greatest(v_partner, coalesce((p ->> 'partner_minimum_eur')::numeric, 0)), 2);
  v_margin := round(v_client - v_partner, 2);

  if v_margin < v_client * coalesce((p ->> 'min_margin_pct')::numeric, 0) / 100 then
    return jsonb_build_object('manual_reason', 'marge_insuffisante');
  end if;

  return jsonb_build_object(
    'client_cents', (v_client * 100)::integer,
    'partner_cents', (v_partner * 100)::integer,
    'margin_cents', (v_margin * 100)::integer,
    'collect_cents', (v_client * 100)::integer,
    'transport_direct_cents', 0,
    'capped', false,
    'lines', v_lines,
    'included', coalesce(p -> 'included', '[]'::jsonb),
    'excluded', coalesce(p -> 'excluded', '[]'::jsonb));
end;
$f$;

-- ----------------------------------------------------------------------------
-- 2. VALIDATION DES BARÈMES — accepte les deux méthodes
-- ----------------------------------------------------------------------------
create or replace function secoto_private.validate_grid_params(p_mode text, p jsonb)
returns void language plpgsql immutable set search_path = ''
as $f$
declare v_tier jsonb; v_prev numeric := 0; v_class text; v_rule jsonb;
begin
  if coalesce((p ->> 'min_margin_pct')::numeric, -1) < 0 or (p ->> 'min_margin_pct')::numeric >= 100 then
    raise exception 'Barème invalide : min_margin_pct requis (0 à 99).';
  end if;

  if p ->> 'pricing_method' = 'per_class' then
    if jsonb_typeof(p -> 'class_rates') <> 'object' or p -> 'class_rates' = '{}'::jsonb then
      raise exception 'Barème invalide : class_rates doit décrire au moins une catégorie.';
    end if;
    for v_class in select jsonb_object_keys(p -> 'class_rates') loop
      if v_class not in ('voiture', 'utilitaire', 'moto', 'autre') then
        raise exception 'Barème invalide : catégorie inconnue %.', v_class;
      end if;
      v_rule := p -> 'class_rates' -> v_class;
      if coalesce((v_rule ->> 'client_eur_per_km')::numeric, 0) <= 0
         or (v_rule ->> 'client_eur_per_km')::numeric > 20 then
        raise exception 'Barème invalide : tarif client hors limites pour %.', v_class;
      end if;
      if (v_rule ->> 'partner_eur_per_km') is null
         or (v_rule ->> 'partner_eur_per_km')::numeric < 0
         or (v_rule ->> 'partner_eur_per_km')::numeric >= (v_rule ->> 'client_eur_per_km')::numeric then
        raise exception 'Barème invalide : rémunération transporteur absente ou supérieure au prix client pour %.', v_class;
      end if;
      if (v_rule ->> 'client_cap_eur') is not null and (v_rule ->> 'client_cap_eur')::numeric <= coalesce((p ->> 'minimum_eur')::numeric, 0) then
        raise exception 'Barème invalide : plafond inférieur au plancher pour %.', v_class;
      end if;
    end loop;
    -- Le supplément non roulant ne doit jamais coûter plus qu'il ne rapporte.
    if coalesce((p ->> 'non_rolling_auto')::boolean, false)
       and coalesce((p ->> 'non_rolling_partner_eur')::numeric, 0) >= coalesce((p ->> 'non_rolling_client_eur')::numeric, 0) then
      raise exception 'Barème invalide : supplément non roulant client supérieur à la part transporteur requis.';
    end if;
    return;
  end if;

  if jsonb_typeof(p -> 'tiers') <> 'array' or jsonb_array_length(p -> 'tiers') = 0 then
    raise exception 'Barème invalide : au moins une tranche est requise.';
  end if;
  if coalesce(p ->> 'tier_method', '') not in ('cumulative', 'global') then
    raise exception 'Barème invalide : tier_method doit valoir cumulative ou global.';
  end if;
  for v_tier in select value from jsonb_array_elements(p -> 'tiers') loop
    if (v_tier ->> 'eur_per_km') is null or (v_tier ->> 'eur_per_km')::numeric <= 0 or (v_tier ->> 'eur_per_km')::numeric > 20 then
      raise exception 'Barème invalide : tarif au km hors limites.';
    end if;
    if v_tier ->> 'up_to_km' is not null then
      if (v_tier ->> 'up_to_km')::numeric <= v_prev then raise exception 'Barème invalide : tranches non croissantes.'; end if;
      v_prev := (v_tier ->> 'up_to_km')::numeric;
    end if;
  end loop;
  if (p -> 'tiers' -> (jsonb_array_length(p -> 'tiers') - 1) ->> 'up_to_km') is not null then
    raise exception 'Barème invalide : la dernière tranche doit être ouverte (up_to_km = null).';
  end if;
end;
$f$;

-- L'activation exige une rémunération transporteur définie, quelle que soit la méthode.
create or replace function public.secoto_admin_activate_grid(p_grid_id uuid)
returns jsonb language plpgsql volatile security definer set search_path = ''
as $f$
declare v_row public.pricing_grids%rowtype;
begin
  perform secoto_private.assert_admin();
  select * into v_row from public.pricing_grids g where g.id = p_grid_id for update;
  if not found then raise exception 'Barème introuvable.'; end if;
  perform secoto_private.validate_grid_params(v_row.mode, v_row.params);
  if not (v_row.params ? 'partner_eur_per_km'
          or v_row.params ? 'partner_share_pct'
          or v_row.params ->> 'pricing_method' = 'per_class') then
    raise exception 'Activation refusée : la rémunération transporteur n''est pas définie dans ce barème.';
  end if;
  perform pg_advisory_xact_lock(hashtext('pricing_grid:' || v_row.mode));
  update public.pricing_grids set status = 'archived' where mode = v_row.mode and status = 'active' and id <> v_row.id;
  update public.pricing_grids set status = 'active', activated_at = now(), activated_by = auth.uid()
   where id = v_row.id returning * into v_row;
  perform secoto_private.audit('pricing_grid_activated', 'pricing_grid', v_row.id::text, jsonb_build_object('mode', v_row.mode, 'version', v_row.version));
  return to_jsonb(v_row);
end;
$f$;

-- ----------------------------------------------------------------------------
-- 3. BARÈME PLATEAU — ACTIF
-- ----------------------------------------------------------------------------
do $plateau$
declare v_id uuid;
begin
  if exists (select 1 from public.pricing_grids g where g.mode = 'plateau' and g.source_note like 'Barème plateau SECOTO du 18/09/2026%') then
    return;
  end if;
  -- L'index d'unicité n'autorise qu'un barème actif par mode : on archive d'abord.
  update public.pricing_grids set status = 'archived' where mode = 'plateau' and status = 'active';
  insert into public.pricing_grids(mode, version, status, params, source_note, activated_at)
  values ('plateau',
    coalesce((select max(g.version) from public.pricing_grids g where g.mode = 'plateau'), 0) + 1,
    'active',
    jsonb_build_object(
      'engine', 'secoto-pricing-2',
      'pricing_method', 'per_class',
      'class_rates', jsonb_build_object(
        'voiture',    jsonb_build_object('client_eur_per_km', 1.12, 'partner_eur_per_km', 0.97),
        'moto',       jsonb_build_object('client_eur_per_km', 1.00, 'partner_eur_per_km', 0.85, 'client_cap_eur', 400),
        'utilitaire', jsonb_build_object('client_eur_per_km', 1.25, 'partner_eur_per_km', 1.10)),
      'minimum_eur', 115,
      'non_rolling_auto', true,
      'non_rolling_client_eur', 80,
      'non_rolling_partner_eur', 60,
      'urgent_pct', 0,
      'urgent_threshold_hours', 24,
      'min_notice_hours', 12,
      'auto_vehicle_classes', jsonb_build_array('voiture', 'moto', 'utilitaire'),
      'auto_max_km', 1500,
      'luxury_auto', false,
      'constraints_auto', false,
      'min_margin_pct', 10,
      'included', jsonb_build_array(
        'Transporteur plateau vérifié et assuré',
        'Chargement, sanglage et déchargement',
        'Carburant et péages inclus',
        'État des lieux au départ et à la livraison (photos)',
        'Bon de livraison et suivi dans l''application'),
      'excluded', jsonb_build_array(
        'Véhicule de prestige ou transport en camion fermé : devis personnalisé',
        'Accès impossible au camion plateau : devis personnalisé')),
    'Barème plateau SECOTO du 18/09/2026 — voiture 1,12 €/km, moto 1,00 €/km plafonnée à 400 €, utilitaire 1,25 €/km, non roulant + 80 €, plancher 115 €. Rémunération transporteur 0,97 / 0,85 / 1,10 €/km, non roulant + 60 €.',
    now())
  returning id into v_id;
end
$plateau$;

-- ----------------------------------------------------------------------------
-- 4. BARÈME CONVOYAGE — ACTIF (forfait 1,00 €/km tout compris)
-- ----------------------------------------------------------------------------
do $convoyage$
declare v_id uuid;
begin
  if exists (select 1 from public.pricing_grids g where g.mode = 'convoyage' and g.source_note like 'Barème convoyage SECOTO du 18/09/2026%') then
    return;
  end if;
  -- L'index d'unicité n'autorise qu'un barème actif par mode : on archive d'abord.
  update public.pricing_grids set status = 'archived' where mode = 'convoyage' and status = 'active';
  insert into public.pricing_grids(mode, version, status, params, source_note, activated_at)
  values ('convoyage',
    coalesce((select max(g.version) from public.pricing_grids g where g.mode = 'convoyage'), 0) + 1,
    'active',
    jsonb_build_object(
      'engine', 'secoto-pricing-2',
      'pricing_method', 'per_class',
      'class_rates', jsonb_build_object(
        'voiture',    jsonb_build_object('client_eur_per_km', 1.00, 'partner_eur_per_km', 0.55),
        'moto',       jsonb_build_object('client_eur_per_km', 1.00, 'partner_eur_per_km', 0.55),
        'utilitaire', jsonb_build_object('client_eur_per_km', 1.00, 'partner_eur_per_km', 0.65)),
      'minimum_eur', 115,
      'non_rolling_auto', false,
      'urgent_pct', 0,
      'urgent_threshold_hours', 24,
      'min_notice_hours', 12,
      'auto_vehicle_classes', jsonb_build_array('voiture', 'moto', 'utilitaire'),
      'auto_max_km', 1500,
      'luxury_auto', false,
      'constraints_auto', false,
      'min_margin_pct', 10,
      'included', jsonb_build_array(
        'Convoyeur vérifié et assuré',
        'Carburant et péages inclus',
        'État des lieux au départ et à la livraison (photos)',
        'Bon de livraison et suivi dans l''application'),
      'excluded', jsonb_build_array(
        'Véhicule non roulant : convoyage impossible, choisissez le plateau',
        'Véhicule de prestige : devis personnalisé')),
    'Barème convoyage SECOTO du 18/09/2026 — forfait 1,00 €/km tout compris (carburant et péages inclus), plancher 115 €. Rémunération convoyeur 0,55 €/km, portée à 0,65 €/km sur utilitaire, camionnette et caravane. Remplace les paliers 1,00/0,90/0,88 de la migration 009.',
    now())
  returning id into v_id;
end
$convoyage$;

-- ----------------------------------------------------------------------------
-- 5. DEVIS MANUEL ADMIN — SECOTO encaisse aussi la totalité
-- ----------------------------------------------------------------------------
update public.transport_quotes
   set collect_cents = client_price_cents, transport_direct_cents = 0
 where status in ('priced', 'manual_priced')
   and (collect_cents is distinct from client_price_cents or transport_direct_cents <> 0);

-- ----------------------------------------------------------------------------
-- 6. CONTRÔLE : les prix annoncés sont bien ceux qui sortent du moteur
-- ----------------------------------------------------------------------------
do $verif$
declare
  p jsonb;
  v jsonb;
  v_voiture jsonb := jsonb_build_object('class', 'voiture', 'category', 'standard', 'rolling', true);
  v_moto jsonb := jsonb_build_object('class', 'moto', 'category', 'standard', 'rolling', true);
  v_util jsonb := jsonb_build_object('class', 'utilitaire', 'category', 'standard', 'rolling', true);
  v_nr jsonb := jsonb_build_object('class', 'voiture', 'category', 'standard', 'rolling', false);
begin
  select g.params into p from public.pricing_grids g where g.mode = 'plateau' and g.status = 'active';

  v := secoto_private.price_with_grid('plateau', p, 500, v_voiture, 72);
  if (v ->> 'client_cents')::int <> 56000 or (v ->> 'partner_cents')::int <> 48500 then
    raise exception 'Contrôle voiture 500 km : % au lieu de 560,00 € / 485,00 €', v;
  end if;
  if (v ->> 'collect_cents')::int <> 56000 or (v ->> 'transport_direct_cents')::int <> 0 then
    raise exception 'Contrôle encaissement : SECOTO doit encaisser la totalité — %', v;
  end if;

  v := secoto_private.price_with_grid('plateau', p, 300, v_moto, 72);
  if (v ->> 'client_cents')::int <> 30000 or (v ->> 'partner_cents')::int <> 25500 then
    raise exception 'Contrôle moto 300 km : % au lieu de 300,00 € / 255,00 €', v;
  end if;

  v := secoto_private.price_with_grid('plateau', p, 800, v_moto, 72);
  if (v ->> 'client_cents')::int <> 40000 or (v ->> 'partner_cents')::int <> 34000 then
    raise exception 'Contrôle moto 800 km (plafond) : % au lieu de 400,00 € / 340,00 €', v;
  end if;

  v := secoto_private.price_with_grid('plateau', p, 200, v_util, 72);
  if (v ->> 'client_cents')::int <> 25000 or (v ->> 'partner_cents')::int <> 22000 then
    raise exception 'Contrôle utilitaire 200 km : % au lieu de 250,00 € / 220,00 €', v;
  end if;

  v := secoto_private.price_with_grid('plateau', p, 50, v_voiture, 72);
  if (v ->> 'client_cents')::int <> 11500 or (v ->> 'partner_cents')::int <> 9960 then
    raise exception 'Contrôle plancher 50 km : % au lieu de 115,00 € / 99,60 €', v;
  end if;

  v := secoto_private.price_with_grid('plateau', p, 500, v_nr, 72);
  if (v ->> 'client_cents')::int <> 64000 or (v ->> 'partner_cents')::int <> 54500 then
    raise exception 'Contrôle non roulant 500 km : % au lieu de 640,00 € / 545,00 €', v;
  end if;

  select g.params into p from public.pricing_grids g where g.mode = 'convoyage' and g.status = 'active';

  v := secoto_private.price_with_grid('convoyage', p, 400, v_voiture, 72);
  if (v ->> 'client_cents')::int <> 40000 or (v ->> 'partner_cents')::int <> 22000 then
    raise exception 'Contrôle convoyage 400 km : % au lieu de 400,00 € / 220,00 €', v;
  end if;

  v := secoto_private.price_with_grid('convoyage', p, 400, v_util, 72);
  if (v ->> 'client_cents')::int <> 40000 or (v ->> 'partner_cents')::int <> 26000 then
    raise exception 'Contrôle convoyage utilitaire 400 km : % au lieu de 400,00 € / 260,00 €', v;
  end if;

  v := secoto_private.price_with_grid('convoyage', p, 50, v_voiture, 72);
  if (v ->> 'client_cents')::int <> 11500 or (v ->> 'partner_cents')::int <> 6325 then
    raise exception 'Contrôle plancher convoyage 50 km : % au lieu de 115,00 € / 63,25 €', v;
  end if;

  v := secoto_private.price_with_grid('convoyage', p, 400, v_nr, 72);
  if v ->> 'manual_reason' <> 'convoyage_impossible_vehicule_non_roulant' then
    raise exception 'Contrôle convoyage non roulant : le moteur doit refuser — %', v;
  end if;
end
$verif$;

notify pgrst, 'reload schema';
commit;


-- ####################################################################
-- ## 202609180035_parcours_commande_final
-- ####################################################################
-- ============================================================================
-- SECOTO — MIGRATION 035 : PARCOURS DE COMMANDE DÉFINITIF
-- ----------------------------------------------------------------------------
-- Décisions Nawfal Bouchaib (SECOTO) du 18/09/2026 :
--
--  1. Le client commande comme une course VTC : adresses, véhicule, prix
--     affiché immédiatement, paiement (Apple Pay, Google Pay, carte).
--  2. Le paiement est ENCAISSÉ tout de suite et gardé en réserve 48 heures,
--     le temps qu'un transporteur accepte. C'est écrit à l'écran.
--  3. La demande part à TOUS les transporteurs vérifiés compatibles, sans
--     qu'ils aient à régler quoi que ce soit au préalable. Un seul tour,
--     48 heures. Ils voient : modèle, ville de départ, ville d'arrivée, état
--     roulant ou non roulant, et leur rémunération. Accepter ou refuser.
--  4. Si personne n'accepte dans les 48 heures : remboursement intégral,
--     demandé automatiquement et exécuté sous 24 heures.
--  5. Plus de candidature avec prix proposé : partout, le transporteur voit sa
--     rémunération et accepte ou refuse.
--  6. Annulation client : remboursement intégral jusqu'à 24 heures avant la
--     prise en charge, même si un transporteur a confirmé ; au-delà, 50 % sont
--     retenus.
--  7. Le transporteur est réglé dans les 48 heures suivant la livraison.
--  8. L'administrateur peut modifier toutes les conditions d'un transport à
--     tout moment, même en cours de mission.
--  9. Facture client automatique dès l'encaissement, avec récapitulatif.
-- 10. TVA non applicable, article 293 B du CGI (franchise en base).
--
-- Additive et rejouable. Aucune donnée supprimée.
-- ============================================================================

begin;

do $guard$
begin
  if to_regprocedure('public.secoto_od_book_quote(uuid,boolean,uuid)') is null then
    raise exception 'Migration 030 requise avant la 035.';
  end if;
  if to_regclass('public.pricing_grids') is null
     or not exists (select 1 from public.pricing_grids g where g.status = 'active' and g.params ->> 'pricing_method' = 'per_class') then
    raise exception 'Migration 034 requise avant la 035.';
  end if;
end
$guard$;

-- ----------------------------------------------------------------------------
-- 1. INTERRUPTEURS ET POLITIQUE OPÉRATIONNELLE
-- ----------------------------------------------------------------------------
alter table public.secoto_feature_flags drop constraint if exists secoto_feature_flags_key_check;
alter table public.secoto_feature_flags add constraint secoto_feature_flags_key_check
  check (key in ('auto_pricing', 'od_payments', 'subscriptions',
                 'dispatch_notifications', 'live_tracking', 'direct_accept'));
insert into public.secoto_feature_flags(key) values ('direct_accept') on conflict (key) do nothing;

-- Une seule source de vérité pour les délais. Modifiable sans redéploiement.
update public.app_settings
   set value = value || jsonb_build_object(
     'offer_ttl_minutes', 2880,              -- 48 h laissées aux transporteurs
     'max_rounds', 1,                        -- un seul tour, pas de relance
     'authorization_window_hours', 0,        -- encaissement immédiat systématique
     'no_partner_refund_hours', 24,          -- remboursement exécuté sous 24 h
     'payout_delay_hours', 48,               -- transporteur réglé sous 48 h
     'free_cancel_hours_before_pickup', 24,  -- annulation gratuite jusqu'à J-24 h
     'late_cancel_retained_pct', 50,         -- au-delà : 50 % retenus
     'sous_traitance_totale_since', to_char(now(), 'YYYY-MM-DD"T"HH24:MI:SSOF'))
 where key = 'dispatch_policy';

insert into public.app_settings(key, value) values ('legal_mentions', jsonb_build_object(
  'tva', 'TVA non applicable, article 293 B du CGI.',
  'entity', 'SECOTO'
)) on conflict (key) do update set value = public.app_settings.value || excluded.value;

create or replace function secoto_private.policy_text(p_key text, p_default text)
returns text language sql stable security definer set search_path = ''
as $f$
  select coalesce((select s.value ->> p_key from public.app_settings s where s.key = 'legal_mentions'), p_default);
$f$;

-- ----------------------------------------------------------------------------
-- 2. COLONNES AJOUTÉES (aucune suppression)
-- ----------------------------------------------------------------------------
alter table public.payments add column if not exists refund_requested_cents integer;
comment on column public.payments.refund_requested_cents is
  'Montant à rembourser demandé (remboursement partiel : annulation tardive). NULL = remboursement du solde intégral.';

alter table public.payments drop constraint if exists payments_purpose_check;
alter table public.payments add constraint payments_purpose_check
  check (purpose in ('commission_plateau', 'convoyage_livraison', 'od_convoyage',
                     'od_plateau_commission', 'od_plateau', 'subscription_extension'));

alter table public.missions add column if not exists vehicle_rolling boolean;
comment on column public.missions.vehicle_rolling is
  'false = véhicule non roulant (treuil nécessaire). NULL = non renseigné, traité comme roulant.';

alter table public.partner_payouts add column if not exists due_at timestamptz;
alter table public.partner_payouts add column if not exists mode text;
comment on column public.partner_payouts.due_at is 'Échéance de règlement du transporteur : livraison + 48 h.';

alter table public.transport_orders add column if not exists invoice_number text;
alter table public.transport_orders add column if not exists invoiced_at timestamptz;
alter table public.transport_orders add column if not exists refund_due_at timestamptz;
alter table public.transport_orders add column if not exists conditions_updated_at timestamptz;
comment on column public.transport_orders.refund_due_at is
  'Échéance affichée au client quand aucun transporteur n''a accepté : constat + 24 h.';

-- Refus d'une mission publiée (hors commande) : le transporteur ne la revoit plus.
create table if not exists public.mission_declines (
  mission_id uuid not null references public.missions(id) on delete cascade,
  partner_id uuid not null references public.accounts(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (mission_id, partner_id)
);
alter table public.mission_declines enable row level security;
revoke all on table public.mission_declines from public, anon, authenticated;

-- ----------------------------------------------------------------------------
-- 3. NUMÉROTATION DES FACTURES CÔTÉ SERVEUR (sans passer par un administrateur)
-- ----------------------------------------------------------------------------
create or replace function secoto_private.next_doc_number(p_prefix text)
returns text language plpgsql volatile security definer set search_path = ''
as $f$
declare v_period text := to_char(now(), 'YYYYMM'); v_num integer;
begin
  insert into public.doc_counters(prefix, period, last_num) values (p_prefix, v_period, 1)
  on conflict (prefix, period) do update set last_num = public.doc_counters.last_num + 1
  returning last_num into v_num;
  return p_prefix || '-' || v_period || '-' || lpad(v_num::text, 4, '0');
end;
$f$;

-- ----------------------------------------------------------------------------
-- 4. DIFFUSION : TOUS LES TRANSPORTEURS VÉRIFIÉS COMPATIBLES
-- ----------------------------------------------------------------------------
-- Les préférences deviennent un filtre facultatif : un transporteur qui n'a
-- rien réglé reçoit tout ce qui le concerne. Il refuse s'il ne peut pas.
create or replace function secoto_private.od_partner_eligible(p_partner uuid, p_order uuid)
returns boolean language sql stable security definer set search_path = ''
as $f$
  select exists (
    select 1
    from public.transport_orders o
    join public.transport_quotes q on q.id = o.quote_id
    join public.accounts a on a.id = p_partner
    left join public.partner_dispatch_preferences pr on pr.account_id = a.id
    where o.id = p_order
      and a.role::text = 'transporter' and a.status::text = 'active'
      and coalesce(a.is_verified, false) and a.deleted_at is null
      and coalesce(pr.available, true)
      and secoto_private.partner_documents_valid(a.id)
      and (
        (o.mode = 'convoyage' and a.transporter_type::text = 'convoyeur')
        or (o.mode = 'plateau' and a.transporter_type::text in ('vl', 'pl') and (
              (coalesce(q.vehicle ->> 'category', 'standard') = 'standard' and coalesce(a.receives_standard_plateau, true))
           or (q.vehicle ->> 'category' = 'luxury' and a.luxury_closed_transport_status = 'approved')))
      )
      -- Filtres facultatifs : ils ne s'appliquent que si le transporteur les a réglés.
      and (pr.account_id is null or cardinality(pr.zones) = 0 or secoto_private.department_of(q.pickup ->> 'postcode') = any(pr.zones))
      and (pr.account_id is null or cardinality(pr.vehicle_classes) = 0 or (q.vehicle ->> 'class') = any(pr.vehicle_classes))
      and (pr.account_id is null or cardinality(pr.weekdays) = 0 or extract(isodow from (o.pickup_at at time zone 'Europe/Paris'))::smallint = any(pr.weekdays))
      and not exists (select 1 from public.transport_offers x where x.order_id = o.id and x.partner_id = a.id and x.status = 'declined')
  );
$f$;

-- Diffusion : un tour, 48 heures, jamais au-delà de la prise en charge.
create or replace function secoto_private.od_broadcast(p_order_id uuid)
returns integer language plpgsql volatile security definer set search_path = ''
as $f$
declare
  v_order public.transport_orders%rowtype;
  v_quote public.transport_quotes%rowtype;
  v_count integer := 0;
  v_offer_id uuid;
  r record;
  v_ttl numeric := secoto_private.policy_num('offer_ttl_minutes', 2880);
  v_expire timestamptz;
  v_state text;
begin
  select * into v_order from public.transport_orders o where o.id = p_order_id for update;
  if v_order.status <> 'searching_partner' then return 0; end if;
  select * into v_quote from public.transport_quotes q where q.id = v_order.quote_id;

  update public.transport_offers set status = 'expired', responded_at = coalesce(responded_at, now())
   where order_id = p_order_id and status = 'sent';

  v_expire := least(now() + make_interval(mins => v_ttl::int), v_order.pickup_at);

  update public.transport_orders
     set dispatch_round = dispatch_round + 1,
         offers_expire_at = v_expire,
         updated_at = now()
   where id = p_order_id returning * into v_order;

  if not secoto_private.flag('dispatch_notifications') then
    perform secoto_private.notify_admins_event('new_request', 'Commande à attribuer',
      format('%s · %s → %s', v_order.public_ref, v_quote.pickup ->> 'city', v_quote.delivery ->> 'city'),
      'requests', 'order-dispatch-manual:' || v_order.id::text || ':' || v_order.dispatch_round, v_order.id);
    return 0;
  end if;

  v_state := case when coalesce((v_quote.vehicle ->> 'rolling')::boolean, true) then 'roulant' else 'NON ROULANT' end;

  for r in select a.id from public.accounts a where secoto_private.od_partner_eligible(a.id, p_order_id) loop
    insert into public.transport_offers(order_id, partner_id, round, partner_pay_cents, expires_at)
    values (p_order_id, r.id, v_order.dispatch_round, v_order.partner_pay_cents, v_order.offers_expire_at)
    on conflict (order_id, partner_id, round) do nothing
    returning id into v_offer_id;
    if v_offer_id is not null then
      v_count := v_count + 1;
      -- Modèle, villes, état du véhicule, rémunération : tout est dans le corps.
      perform secoto_private.notify_event(r.id, 'mission_offer', 'Mission disponible',
        format('%s · %s → %s · %s · %s € pour vous',
          coalesce(nullif(v_quote.vehicle ->> 'model', ''), 'Véhicule'),
          v_quote.pickup ->> 'city', v_quote.delivery ->> 'city', v_state,
          to_char(v_order.partner_pay_cents / 100.0, 'FM999990D00')),
        null, 'offre', 'offer:' || v_offer_id::text, v_offer_id);
    end if;
  end loop;

  perform secoto_private.audit('order_broadcast', 'transport_order', p_order_id::text,
    jsonb_build_object('round', v_order.dispatch_round, 'offers', v_count, 'expires_at', v_order.offers_expire_at));
  return v_count;
end;
$f$;

-- ----------------------------------------------------------------------------
-- 5. RÉSERVATION : ENCAISSEMENT IMMÉDIAT, RÉSERVE DE 48 HEURES
-- ----------------------------------------------------------------------------
create or replace function public.secoto_od_book_quote(p_quote_id uuid, p_use_subscription boolean, p_idempotency_key uuid)
returns jsonb language plpgsql volatile security definer set search_path = ''
as $f$
declare
  v_user uuid := secoto_private.assert_authenticated();
  v_existing jsonb;
  v_quote public.transport_quotes%rowtype;
  v_order public.transport_orders%rowtype;
  v_payment public.payments%rowtype;
  v_strategy text;
  v_client_type text;
begin
  v_existing := secoto_private.lock_operation('od_book_quote', p_idempotency_key);
  if v_existing is not null then return v_existing; end if;

  select * into v_quote from public.transport_quotes q where q.id = p_quote_id for update;
  if not found or not (v_quote.account_id = v_user or (v_quote.business_id is not null and secoto_private.is_business_member(v_quote.business_id, v_user))) then
    raise exception 'Devis introuvable.' using errcode = 'P0002';
  end if;

  select * into v_order from public.transport_orders o where o.quote_id = p_quote_id;
  if found then
    return secoto_private.finish_operation('od_book_quote', p_idempotency_key,
      jsonb_build_object('order', secoto_private.order_client_json(v_order), 'already_booked', true));
  end if;

  if v_quote.status not in ('priced', 'manual_priced') then raise exception 'Ce devis ne peut pas être réservé (%).', v_quote.status; end if;
  if v_quote.valid_until <= now() then
    update public.transport_quotes set status = 'expired', updated_at = now() where id = p_quote_id;
    raise exception 'Ce devis a expiré. Recalculez le prix pour obtenir un devis à jour.';
  end if;
  if v_quote.pickup_at <= now() then raise exception 'La date de prise en charge est dépassée.'; end if;

  if coalesce(p_use_subscription, false) then
    if not secoto_private.flag('subscriptions') then raise exception 'Les abonnements ne sont pas encore ouverts.'; end if;
    v_strategy := 'subscription';
  else
    if not secoto_private.flag('od_payments') then
      raise exception 'Le paiement en ligne n''est pas encore ouvert : contactez SECOTO pour confirmer ce devis.';
    end if;
    -- Décision du 18/09/2026 : on encaisse tout de suite, on garde en réserve
    -- 48 heures, et on rembourse intégralement si aucun transporteur n'accepte.
    v_strategy := 'capture_then_refund';
  end if;

  insert into public.transport_orders(public_ref, quote_id, account_id, business_id, mode, funding, status, payment_strategy,
    client_price_cents, partner_pay_cents, collect_cents, transport_direct_cents, pickup_at)
  values (secoto_private.new_order_ref(), v_quote.id, v_user, v_quote.business_id, v_quote.mode,
    case when v_strategy = 'subscription' then 'subscription' else 'card' end,
    'awaiting_payment', v_strategy, v_quote.client_price_cents, v_quote.partner_pay_cents,
    v_quote.client_price_cents, 0, v_quote.pickup_at)
  returning * into v_order;

  update public.transport_quotes set status = 'accepted', updated_at = now() where id = p_quote_id;

  if v_strategy = 'subscription' then
    perform secoto_private.sub_reserve_for_order(v_order.id);
    perform secoto_private.od_open_dispatch(v_order.id);
  else
    select case when a.client_type = 'particulier' then 'particulier' else 'pro' end into v_client_type
      from public.accounts a where a.id = v_user;
    -- SECOTO vend le transport (sous-traitance) : le consommateur renonce
    -- expressément à son délai de rétractation pour une exécution immédiate.
    insert into public.payments(mission_id, order_id, account_id, purpose, amount_cents, status, capture_method, waiver_required)
    values (null, v_order.id, v_user,
      case when v_order.mode = 'plateau' then 'od_plateau' else 'od_convoyage' end,
      v_order.collect_cents, 'pending', 'automatic',
      coalesce(v_client_type, 'pro') = 'particulier')
    returning * into v_payment;
    update public.transport_orders set payment_id = v_payment.id where id = v_order.id returning * into v_order;
  end if;

  perform secoto_private.audit('order_booked', 'transport_order', v_order.id::text,
    jsonb_build_object('quote_id', p_quote_id, 'strategy', v_strategy));

  return secoto_private.finish_operation('od_book_quote', p_idempotency_key,
    jsonb_build_object('order', secoto_private.order_client_json(v_order), 'already_booked', false));
end;
$f$;

-- ----------------------------------------------------------------------------
-- 6. FACTURE ET RÉCAPITULATIF AUTOMATIQUES À L'ENCAISSEMENT
-- ----------------------------------------------------------------------------
create or replace function secoto_private.od_issue_invoice(p_order_id uuid)
returns void language plpgsql volatile security definer set search_path = ''
as $f$
declare
  v_order public.transport_orders%rowtype;
  v_quote public.transport_quotes%rowtype;
  v_num text;
  v_body text;
  v_line jsonb;
  v_detail text := '';
begin
  select * into v_order from public.transport_orders o where o.id = p_order_id for update;
  if not found or v_order.invoice_number is not null then return; end if;
  select * into v_quote from public.transport_quotes q where q.id = v_order.quote_id;

  v_num := secoto_private.next_doc_number('FAC');
  update public.transport_orders set invoice_number = v_num, invoiced_at = now(), updated_at = now()
   where id = p_order_id;

  for v_line in select value from jsonb_array_elements(coalesce(v_quote.breakdown -> 'lines', '[]'::jsonb)) loop
    v_detail := v_detail || '  - ' || (v_line ->> 'label') || ' : ' || to_char((v_line ->> 'eur')::numeric, 'FM999990D00') || ' EUR' || E'\n';
  end loop;

  v_body :=
    'Facture ' || v_num || E'\n' ||
    'Commande ' || v_order.public_ref || E'\n\n' ||
    'Prestation : transport de vehicule (' ||
      case when v_order.mode = 'plateau' then 'camion plateau' else 'convoyage par la route' end || ')' || E'\n' ||
    'Vehicule : ' || coalesce(nullif(v_quote.vehicle ->> 'model', ''), 'non precise') ||
      case when coalesce((v_quote.vehicle ->> 'rolling')::boolean, true) then ' (roulant)' else ' (NON ROULANT)' end || E'\n' ||
    'Enlevement : ' || coalesce(v_quote.pickup ->> 'label', '') || E'\n' ||
    'Livraison : ' || coalesce(v_quote.delivery ->> 'label', '') || E'\n' ||
    'Date de prise en charge : ' || to_char(v_order.pickup_at at time zone 'Europe/Paris', 'DD/MM/YYYY') || E'\n\n' ||
    case when v_detail <> '' then 'Detail :' || E'\n' || v_detail || E'\n' else '' end ||
    'Total paye : ' || to_char(v_order.client_price_cents / 100.0, 'FM999990D00') || ' EUR' || E'\n' ||
    secoto_private.policy_text('tva', 'TVA non applicable, article 293 B du CGI.') || E'\n\n' ||
    'Votre paiement est conserve en reserve pendant 48 heures, le temps qu''un transporteur SECOTO accepte la mission. ' ||
    'Si aucun transporteur ne se rend disponible, vous etes rembourse integralement sous 24 heures.' || E'\n\n' ||
    'Annulation : remboursement integral jusqu''a 24 heures avant la prise en charge ; au-dela, 50 % sont retenus.' || E'\n\n' ||
    'SECOTO';

  perform secoto_private.queue_email(v_order.account_id,
    'SECOTO - Facture ' || v_num || ' - commande ' || v_order.public_ref,
    v_body, v_order.mission_id, 'od-invoice:' || p_order_id::text);

  perform secoto_private.notify_event(v_order.account_id, 'payment', 'Facture disponible',
    format('Commande %s : facture %s envoyée par e-mail.', v_order.public_ref, v_num),
    null, 'courses', 'od-invoice:' || p_order_id::text, p_order_id);

  perform secoto_private.audit('order_invoiced', 'transport_order', p_order_id::text,
    jsonb_build_object('invoice_number', v_num, 'amount_cents', v_order.client_price_cents));
end;
$f$;

-- ----------------------------------------------------------------------------
-- 7. ÉVÉNEMENTS DE PAIEMENT : nouveau motif, facture, libellés exacts
-- ----------------------------------------------------------------------------
create or replace function public.secoto_od_apply_payment_event(
  p_payment_id uuid, p_event_id text, p_event_type text, p_intent_id text,
  p_amount_refunded_cents integer, p_capture_before timestamptz, p_error text
)
returns jsonb language plpgsql volatile security definer set search_path = ''
as $f$
declare
  v_payment public.payments%rowtype;
  v_order public.transport_orders%rowtype;
  v_new text;
  v_effect text := 'none';
begin
  select * into v_payment from public.payments p where p.id = p_payment_id for update;
  if not found then return jsonb_build_object('skipped', true, 'reason', 'unknown_payment'); end if;
  if v_payment.purpose not in ('od_convoyage', 'od_plateau', 'od_plateau_commission', 'subscription_extension') then
    return jsonb_build_object('skipped', true, 'reason', 'legacy_purpose');
  end if;
  if p_event_id is not null and exists (select 1 from public.payment_events e where e.provider_event_id = p_event_id) then
    return jsonb_build_object('skipped', true, 'reason', 'event_already_processed');
  end if;

  v_new := v_payment.status;
  case p_event_type
    when 'payment_intent.amount_capturable_updated' then
      if v_payment.status in ('pending', 'processing', 'failed') then v_new := 'requires_capture'; end if;
    when 'payment_intent.succeeded' then
      if v_payment.status in ('pending', 'processing', 'failed', 'requires_capture', 'capture_failed') then v_new := 'paid'; end if;
    when 'payment_intent.payment_failed' then
      if v_payment.status in ('pending', 'processing') then v_new := 'failed'; end if;
    when 'payment_intent.canceled' then
      if v_payment.status in ('pending', 'processing', 'requires_capture', 'capture_failed', 'failed') then v_new := 'cancelled'; end if;
    when 'charge.refunded' then
      if coalesce(p_amount_refunded_cents, 0) >= v_payment.amount_cents then v_new := 'refunded'; end if;
    when 'charge.dispute.created' then null;
    when 'charge.dispute.closed' then null;
    else
      return jsonb_build_object('skipped', true, 'reason', 'event_type_ignored');
  end case;

  update public.payments set
    status = v_new,
    provider_intent_id = coalesce(provider_intent_id, p_intent_id),
    authorized_at = case when v_new = 'requires_capture' then coalesce(authorized_at, now()) else authorized_at end,
    capture_before = coalesce(p_capture_before, capture_before),
    captured_at = case when v_new = 'paid' then coalesce(captured_at, now()) else captured_at end,
    paid_at = case when v_new = 'paid' then coalesce(paid_at, now()) else paid_at end,
    failed_at = case when v_new = 'failed' then now() else failed_at end,
    released_at = case when v_new = 'cancelled' then coalesce(released_at, now()) else released_at end,
    refunded_amount_cents = greatest(refunded_amount_cents, coalesce(p_amount_refunded_cents, 0)),
    dispute_status = case p_event_type when 'charge.dispute.created' then 'open' when 'charge.dispute.closed' then 'closed' else dispute_status end,
    last_error = case when v_new = 'failed' then left(coalesce(p_error, ''), 500) else last_error end,
    last_event_at = now(), updated_at = now()
  where id = p_payment_id returning * into v_payment;

  insert into public.payment_events(payment_id, event_type, provider_event_id, payload)
  values (p_payment_id, p_event_type, p_event_id, jsonb_build_object('intent', p_intent_id, 'status', v_new, 'refunded', p_amount_refunded_cents, 'error', p_error))
  on conflict (provider_event_id) where provider_event_id is not null do nothing;

  if v_payment.order_id is not null then
    select * into v_order from public.transport_orders o where o.id = v_payment.order_id for update;
    if v_new = 'paid' then
      -- Facture émise dès l'encaissement, quel que soit l'état du transport.
      perform secoto_private.od_issue_invoice(v_order.id);
    end if;
    if v_new in ('requires_capture', 'paid') and v_order.status = 'awaiting_payment' then
      perform secoto_private.od_open_dispatch(v_order.id);
      v_effect := 'dispatch_opened';
      perform secoto_private.notify_event(v_order.account_id, 'payment', 'Paiement encaissé',
        format('Commande %s : paiement encaissé et gardé en réserve 48 heures, le temps qu''un transporteur accepte. Sans transporteur, remboursement intégral sous 24 heures.', v_order.public_ref),
        null, 'courses', 'od-payment-ok:' || v_order.id::text, v_order.id);
    elsif v_new = 'paid' and v_order.status = 'partner_locked' then
      perform secoto_private.od_confirm(v_order.id);
      v_effect := 'confirmed';
    elsif v_new = 'cancelled' and v_order.status in ('awaiting_payment', 'searching_partner', 'partner_locked') then
      update public.transport_offers set status = 'withdrawn', responded_at = now() where order_id = v_order.id and status = 'sent';
      update public.transport_orders set status = 'cancelled', cancelled_at = now(),
        cancel_reason = coalesce(cancel_reason, 'paiement_non_abouti'), lock_expires_at = null, updated_at = now()
       where id = v_order.id;
      v_effect := 'order_cancelled';
    elsif v_new = 'failed' then
      perform secoto_private.notify_event(v_order.account_id, 'payment_failed', 'Paiement refusé',
        format('Commande %s : le paiement n''a pas abouti. Aucune demande n''est diffusée.', v_order.public_ref),
        null, 'paiement', 'od-payment-failed:' || p_payment_id::text || ':' || coalesce(p_event_id, ''), v_order.id);
    end if;
  end if;

  if p_event_type = 'charge.dispute.created' then
    perform secoto_private.notify_admins_event('payment_failed', 'Contestation bancaire',
      format('Paiement %s contesté.', p_payment_id), 'paiement', 'dispute:' || p_payment_id::text, p_payment_id);
  end if;
  return jsonb_build_object('payment_id', p_payment_id, 'status', v_new, 'effect', v_effect);
end;
$f$;

-- ----------------------------------------------------------------------------
-- 8. ARRÊT D'UNE COMMANDE : remboursement total ou partiel
-- ----------------------------------------------------------------------------
create or replace function secoto_private.od_stop_order(p_order_id uuid, p_status text, p_reason text)
returns void language plpgsql volatile security definer set search_path = ''
as $f$
begin
  perform secoto_private.od_stop_order_amount(p_order_id, p_status, p_reason, null);
end;
$f$;

-- p_refund_cents : NULL = tout le solde. Sinon montant exact à rembourser.
create or replace function secoto_private.od_stop_order_amount(p_order_id uuid, p_status text, p_reason text, p_refund_cents integer)
returns void language plpgsql volatile security definer set search_path = ''
as $f$
declare v_order public.transport_orders%rowtype;
begin
  select * into v_order from public.transport_orders o where o.id = p_order_id for update;
  update public.transport_offers set status = 'withdrawn', responded_at = now() where order_id = p_order_id and status = 'sent';
  update public.transport_orders set status = p_status,
      cancelled_at = case when p_status = 'cancelled' then now() else cancelled_at end,
      cancel_reason = p_reason, lock_partner_id = null, lock_offer_id = null, lock_expires_at = null,
      refund_due_at = case when p_status = 'no_partner'
                           then now() + make_interval(hours => secoto_private.policy_num('no_partner_refund_hours', 24)::int)
                           else refund_due_at end,
      updated_at = now()
   where id = p_order_id;

  -- La mission éventuellement créée est annulée avec la commande.
  if v_order.mission_id is not null and p_status = 'cancelled' then
    update public.missions set status = 'cancelled', cancelled_at = now(),
      cancellation_reason = left(coalesce(p_reason, 'annulation'), 500)
     where id = v_order.mission_id and status::text not in ('completed', 'cancelled');
    update public.partner_payouts set status = 'cancelled' where order_id = p_order_id and status = 'to_pay';
  end if;

  if v_order.funding = 'subscription' then
    perform secoto_private.sub_release_for_order(p_order_id, p_reason);
  elsif v_order.payment_id is not null then
    if p_refund_cents = 0 then
      -- Rien à rembourser : la retenue couvre la totalité.
      return;
    end if;
    update public.payments set release_requested_at = coalesce(release_requested_at, now()),
      refund_reason = coalesce(refund_reason, p_reason),
      refund_requested_cents = coalesce(refund_requested_cents, p_refund_cents),
      status = case when status = 'paid' then 'refund_pending' else status end,
      refund_requested_at = case when status = 'paid' then coalesce(refund_requested_at, now()) else refund_requested_at end,
      updated_at = now()
     where id = v_order.payment_id and status in ('pending', 'processing', 'requires_capture', 'capture_failed', 'paid');
  end if;
end;
$f$;

-- ----------------------------------------------------------------------------
-- 9. ANNULATION CLIENT : gratuite jusqu'à 24 h avant, puis 50 % retenus
-- ----------------------------------------------------------------------------
create or replace function public.secoto_od_cancel_quote_preview(p_order_id uuid)
returns jsonb language plpgsql stable security definer set search_path = ''
as $f$
declare
  v_user uuid := secoto_private.assert_authenticated();
  v_order public.transport_orders%rowtype;
  v_free_h numeric := secoto_private.policy_num('free_cancel_hours_before_pickup', 24);
  v_pct numeric := secoto_private.policy_num('late_cancel_retained_pct', 50);
  v_late boolean;
begin
  select * into v_order from public.transport_orders o where o.id = p_order_id;
  if not found or not (v_order.account_id = v_user or (v_order.business_id is not null and secoto_private.is_business_member(v_order.business_id, v_user))) then
    raise exception 'Commande introuvable.' using errcode = 'P0002';
  end if;
  v_late := v_order.pickup_at - make_interval(hours => v_free_h::int) <= now();
  return jsonb_build_object(
    'cancellable', v_order.status not in ('delivered', 'cancelled', 'no_partner'),
    'late', v_late,
    'free_until', v_order.pickup_at - make_interval(hours => v_free_h::int),
    'retained_pct', case when v_late then v_pct else 0 end,
    'refund_cents', case when v_late then v_order.client_price_cents - round(v_order.client_price_cents * v_pct / 100)::int
                         else v_order.client_price_cents end);
end;
$f$;

create or replace function public.secoto_od_cancel_order(p_order_id uuid, p_idempotency_key uuid)
returns jsonb language plpgsql volatile security definer set search_path = ''
as $f$
declare
  v_user uuid := secoto_private.assert_authenticated();
  v_existing jsonb;
  v_order public.transport_orders%rowtype;
  v_free_h numeric := secoto_private.policy_num('free_cancel_hours_before_pickup', 24);
  v_pct numeric := secoto_private.policy_num('late_cancel_retained_pct', 50);
  v_late boolean;
  v_refund integer;
  v_reason text;
begin
  v_existing := secoto_private.lock_operation('od_cancel_order', p_idempotency_key);
  if v_existing is not null then return v_existing; end if;
  select * into v_order from public.transport_orders o where o.id = p_order_id for update;
  if not found or not (v_order.account_id = v_user or (v_order.business_id is not null and secoto_private.is_business_member(v_order.business_id, v_user))) then
    raise exception 'Commande introuvable.' using errcode = 'P0002';
  end if;
  if v_order.status = 'partner_locked' then
    raise exception 'Un transporteur est en cours de confirmation : réessayez dans deux minutes.';
  end if;
  if v_order.status in ('cancelled', 'delivered', 'no_partner') then
    return secoto_private.finish_operation('od_cancel_order', p_idempotency_key, secoto_private.order_client_json(v_order));
  end if;
  if v_order.status = 'picked_up' then
    raise exception 'Le véhicule est déjà pris en charge : contactez SECOTO.';
  end if;

  v_late := v_order.pickup_at - make_interval(hours => v_free_h::int) <= now();
  if v_order.funding = 'subscription' then
    v_refund := null;
  elsif v_late then
    v_refund := v_order.client_price_cents - round(v_order.client_price_cents * v_pct / 100)::int;
  else
    v_refund := v_order.client_price_cents;
  end if;
  v_reason := case when v_late then 'annulation_client_tardive' else 'annulation_client' end;

  perform secoto_private.od_stop_order_amount(p_order_id, 'cancelled', v_reason, v_refund);

  if v_order.assigned_partner_id is not null then
    perform secoto_private.notify_event(v_order.assigned_partner_id, 'cancellation', 'Mission annulée',
      format('Commande %s annulée par le client.', v_order.public_ref),
      v_order.mission_id, 'assigned', 'od-cancel-partner:' || p_order_id::text, p_order_id);
    perform secoto_private.notify_admins_event('cancellation', 'Annulation après attribution',
      format('%s · %s retenus · transporteur à arbitrer', v_order.public_ref,
        to_char(coalesce(v_order.client_price_cents - coalesce(v_refund, 0), 0) / 100.0, 'FM999990D00') || ' €'),
      'requests', 'od-cancel-admin:' || p_order_id::text, p_order_id);
  end if;

  perform secoto_private.notify_event(v_order.account_id, 'order_update', 'Commande annulée',
    case when v_late
      then format('Commande %s annulée. Annulation à moins de %s h de la prise en charge : %s %% retenus, %s € remboursés.',
             v_order.public_ref, v_free_h::int, v_pct::int, to_char(coalesce(v_refund, 0) / 100.0, 'FM999990D00'))
      else format('Commande %s annulée. Vous êtes remboursé intégralement.', v_order.public_ref) end,
    null, 'courses', 'od-cancel-client:' || p_order_id::text, p_order_id);

  perform secoto_private.audit('order_cancelled_by_client', 'transport_order', p_order_id::text,
    jsonb_build_object('late', v_late, 'refund_cents', v_refund, 'retained_pct', case when v_late then v_pct else 0 end));
  select * into v_order from public.transport_orders o where o.id = p_order_id;
  return secoto_private.finish_operation('od_cancel_order', p_idempotency_key, secoto_private.order_client_json(v_order));
end;
$f$;

-- ----------------------------------------------------------------------------
-- 10. MAINTENANCE : un seul tour, remboursement sous 24 h, versements dus
-- ----------------------------------------------------------------------------
create or replace function public.secoto_od_maintenance_tick()
returns jsonb language plpgsql volatile security definer set search_path = ''
as $f$
declare
  r record;
  v_rounds integer := secoto_private.policy_num('max_rounds', 1)::int;
  v_rebroadcast integer := 0; v_no_partner integer := 0; v_expired_quotes integer := 0;
  v_locks jsonb := '[]'::jsonb;
  v_actions jsonb;
  v_payouts integer := 0;
begin
  update public.transport_quotes set status = 'expired', updated_at = now()
   where status in ('priced', 'manual_priced') and valid_until <= now();
  get diagnostics v_expired_quotes = row_count;

  update public.transport_offers set status = 'expired' where status = 'sent' and expires_at <= now();

  for r in select o.id, o.dispatch_round, o.pickup_at, o.account_id, o.public_ref from public.transport_orders o
            where o.status = 'searching_partner' and o.offers_expire_at <= now()
            for update skip locked loop
    if r.dispatch_round >= v_rounds or r.pickup_at <= now() then
      perform secoto_private.od_stop_order(r.id, 'no_partner', 'aucun_transporteur_disponible');
      perform secoto_private.notify_event(r.account_id, 'order_update', 'Aucun transporteur disponible',
        format('Commande %s : aucun transporteur ne s''est rendu disponible dans les 48 heures. Vous êtes remboursé intégralement sous 24 heures.', r.public_ref),
        null, 'courses', 'od-no-partner:' || r.id::text, r.id);
      perform secoto_private.notify_admins_event('order_update', 'Commande sans transporteur — rembourser sous 24 h',
        r.public_ref, 'requests', 'od-no-partner-admin:' || r.id::text, r.id);
      v_no_partner := v_no_partner + 1;
    else
      perform secoto_private.od_broadcast(r.id);
      v_rebroadcast := v_rebroadcast + 1;
    end if;
  end loop;

  select coalesce(jsonb_agg(jsonb_build_object('order_id', o.id, 'payment_id', o.payment_id, 'intent_id', p.provider_intent_id, 'funding', o.funding)), '[]'::jsonb)
    into v_locks
    from public.transport_orders o left join public.payments p on p.id = o.payment_id
   where o.status = 'partner_locked' and o.lock_expires_at <= now();

  select coalesce(jsonb_agg(jsonb_build_object('payment_id', p.id, 'intent_id', p.provider_intent_id, 'status', p.status,
      'action', case when p.status = 'refund_pending' then 'refund' else 'cancel' end,
      'amount_cents', least(coalesce(p.refund_requested_cents, p.amount_cents - p.refunded_amount_cents),
                            p.amount_cents - p.refunded_amount_cents))), '[]'::jsonb)
    into v_actions
    from public.payments p
   where p.purpose in ('od_convoyage', 'od_plateau', 'od_plateau_commission', 'subscription_extension')
     and p.release_requested_at is not null and p.status in ('pending', 'processing', 'requires_capture', 'capture_failed', 'refund_pending');

  -- Versements transporteurs échus (livraison + 48 h) : rappel à l'administrateur.
  for r in select pp.id, pp.partner_id, m.public_ref, pp.amount_cents
             from public.partner_payouts pp join public.missions m on m.id = pp.mission_id
            where pp.status = 'to_pay' and pp.due_at is not null and pp.due_at <= now() loop
    perform secoto_private.notify_admins_event('payment', 'Versement transporteur à effectuer',
      format('%s · %s €', r.public_ref, to_char(r.amount_cents / 100.0, 'FM999990D00')),
      'paiement', 'payout-due:' || r.id::text, r.id);
    v_payouts := v_payouts + 1;
  end loop;

  return jsonb_build_object('expired_quotes', v_expired_quotes, 'rebroadcast', v_rebroadcast, 'no_partner', v_no_partner,
    'expired_locks', v_locks, 'payment_actions', v_actions, 'payouts_due', v_payouts);
end;
$f$;

create or replace function public.secoto_od_payment_action_result(p_payment_id uuid, p_action text, p_success boolean, p_error text)
returns void language plpgsql volatile security definer set search_path = ''
as $f$
begin
  if p_success then
    update public.payments set
      status = case
        when p_action = 'refund' and coalesce(refund_requested_cents, amount_cents) >= amount_cents - refunded_amount_cents then 'refunded'
        when p_action = 'refund' then 'paid'
        else 'cancelled' end,
      refunded_amount_cents = case when p_action = 'refund'
        then least(amount_cents, refunded_amount_cents + coalesce(refund_requested_cents, amount_cents - refunded_amount_cents))
        else refunded_amount_cents end,
      released_at = case when p_action = 'cancel' then coalesce(released_at, now()) else released_at end,
      release_requested_at = null, refund_requested_cents = null, updated_at = now()
    where id = p_payment_id and status in ('pending', 'processing', 'requires_capture', 'capture_failed', 'refund_pending');
  else
    update public.payments set last_error = left(coalesce(p_error, p_action || '_failed'), 500), updated_at = now() where id = p_payment_id;
  end if;
end;
$f$;

-- ----------------------------------------------------------------------------
-- 11. VERSEMENT TRANSPORTEUR DANS LES 48 H, DANS LES DEUX MODES
-- ----------------------------------------------------------------------------
create or replace function secoto_private.trg_od_sync_from_mission()
returns trigger language plpgsql volatile security definer set search_path = ''
as $f$
declare v_order public.transport_orders%rowtype; v_delay numeric;
begin
  select * into v_order from public.transport_orders o where o.mission_id = new.id;
  if not found then return new; end if;
  if coalesce(new.progress_status, '') in ('pickup_completed', 'in_transit', 'incident_reported', 'delivery_started')
     and v_order.status = 'partner_confirmed' then
    update public.transport_orders set status = 'picked_up', updated_at = now() where id = v_order.id;
  elsif (coalesce(new.progress_status, '') in ('delivery_completed', 'completed') or new.status::text = 'completed')
     and v_order.status in ('partner_confirmed', 'picked_up') then
    update public.transport_orders set status = 'delivered', updated_at = now() where id = v_order.id;
    perform secoto_private.sub_consume_for_order(v_order.id);
    v_delay := secoto_private.policy_num('payout_delay_hours', 48);
    -- SECOTO encaisse la totalité : le transporteur est réglé par virement,
    -- au plus tard 48 heures après la livraison, dans les deux modes.
    insert into public.partner_payouts(mission_id, order_id, partner_id, amount_cents, due_at, mode)
    values (new.id, v_order.id, v_order.assigned_partner_id, v_order.partner_pay_cents,
            now() + make_interval(hours => v_delay::int), v_order.mode)
    on conflict (mission_id) do nothing;
    perform secoto_private.notify_event(v_order.assigned_partner_id, 'payment', 'Paiement en route',
      format('Mission %s livrée : %s € vous sont versés sous 48 heures.', new.public_ref,
             to_char(v_order.partner_pay_cents / 100.0, 'FM999990D00')),
      new.id, 'paiement', 'od-payout-announced:' || v_order.id::text, v_order.id);
  end if;
  return new;
end;
$f$;

-- ----------------------------------------------------------------------------
-- 12. PILOTAGE ADMIN : modifier les conditions à tout moment
-- ----------------------------------------------------------------------------
create or replace function public.secoto_admin_od_update_conditions(p_order_id uuid, p_payload jsonb, p_note text)
returns jsonb language plpgsql volatile security definer set search_path = ''
as $f$
declare
  v_order public.transport_orders%rowtype;
  v_quote public.transport_quotes%rowtype;
  v_client integer; v_partner integer; v_pickup timestamptz;
  v_changes jsonb := '{}'::jsonb;
  v_paid boolean;
begin
  perform secoto_private.assert_admin();
  if length(btrim(coalesce(p_note, ''))) < 3 then
    raise exception 'Indiquez le motif de la modification.';
  end if;
  select * into v_order from public.transport_orders o where o.id = p_order_id for update;
  if not found then raise exception 'Commande introuvable.' using errcode = 'P0002'; end if;
  if v_order.status in ('cancelled', 'no_partner') then
    raise exception 'Commande arrêtée : plus rien à modifier.';
  end if;
  select * into v_quote from public.transport_quotes q where q.id = v_order.quote_id for update;

  v_client := coalesce((p_payload ->> 'client_price_cents')::int, v_order.client_price_cents);
  v_partner := coalesce((p_payload ->> 'partner_pay_cents')::int, v_order.partner_pay_cents);
  v_pickup := coalesce((p_payload ->> 'pickup_at')::timestamptz, v_order.pickup_at);
  if v_client <= 0 or v_partner < 0 then raise exception 'Montants invalides.'; end if;
  if v_partner > v_client then raise exception 'La rémunération transporteur ne peut pas dépasser le prix client.'; end if;

  if p_payload ? 'pickup' or p_payload ? 'delivery' or p_payload ? 'vehicle' then
    update public.transport_quotes set
      pickup = coalesce(p_payload -> 'pickup', pickup),
      delivery = coalesce(p_payload -> 'delivery', delivery),
      vehicle = coalesce(p_payload -> 'vehicle', vehicle),
      updated_at = now()
     where id = v_quote.id returning * into v_quote;
  end if;

  if v_client <> v_order.client_price_cents then v_changes := v_changes || jsonb_build_object('client_price_cents', jsonb_build_array(v_order.client_price_cents, v_client)); end if;
  if v_partner <> v_order.partner_pay_cents then v_changes := v_changes || jsonb_build_object('partner_pay_cents', jsonb_build_array(v_order.partner_pay_cents, v_partner)); end if;
  if v_pickup <> v_order.pickup_at then v_changes := v_changes || jsonb_build_object('pickup_at', jsonb_build_array(v_order.pickup_at, v_pickup)); end if;

  update public.transport_orders set
    client_price_cents = v_client, partner_pay_cents = v_partner,
    collect_cents = v_client, transport_direct_cents = 0,
    pickup_at = v_pickup, conditions_updated_at = now(), updated_at = now()
   where id = p_order_id returning * into v_order;

  -- Offres en cours : la rémunération affichée suit la décision de l'admin.
  update public.transport_offers set partner_pay_cents = v_partner where order_id = p_order_id and status = 'sent';

  if v_order.mission_id is not null then
    update public.missions set
      mission_date = v_pickup,
      pickup_address = coalesce(v_quote.pickup ->> 'label', pickup_address),
      delivery_address = coalesce(v_quote.delivery ->> 'label', delivery_address),
      from_city = coalesce(v_quote.pickup ->> 'city', from_city),
      to_city = coalesce(v_quote.delivery ->> 'city', to_city),
      vehicle = coalesce(left(v_quote.vehicle ->> 'model', 120), vehicle),
      vehicle_rolling = coalesce((v_quote.vehicle ->> 'rolling')::boolean, vehicle_rolling),
      manual_pricing = true,
      manual_carrier_pay = v_partner / 100.0,
      manual_margin = (v_client - v_partner) / 100.0
     where id = v_order.mission_id;
    update public.partner_payouts set amount_cents = v_partner
     where order_id = p_order_id and status = 'to_pay';
  end if;

  select (p.status = 'paid') into v_paid from public.payments p where p.id = v_order.payment_id;
  if coalesce(v_paid, false) and v_changes ? 'client_price_cents' then
    -- Prix changé après encaissement : aucun débit ni remboursement automatique.
    perform secoto_private.notify_admins_event('payment', 'Écart de prix à régulariser',
      format('%s : prix modifié après encaissement. Complément ou remboursement à traiter manuellement.', v_order.public_ref),
      'paiement', 'od-price-change:' || p_order_id::text || ':' || extract(epoch from now())::bigint::text, p_order_id);
  end if;

  perform secoto_private.notify_event(v_order.account_id, 'order_update', 'Conditions mises à jour',
    format('Commande %s : %s', v_order.public_ref, left(p_note, 160)),
    v_order.mission_id, 'courses', 'od-conditions:' || p_order_id::text || ':' || extract(epoch from now())::bigint::text, p_order_id);
  if v_order.assigned_partner_id is not null then
    perform secoto_private.notify_event(v_order.assigned_partner_id, 'order_update', 'Mission modifiée',
      format('Mission %s : %s', v_order.public_ref, left(p_note, 160)),
      v_order.mission_id, 'assigned', 'od-conditions-partner:' || p_order_id::text || ':' || extract(epoch from now())::bigint::text, p_order_id);
  end if;

  perform secoto_private.audit('order_conditions_updated', 'transport_order', p_order_id::text,
    jsonb_build_object('note', p_note, 'changes', v_changes));
  return secoto_private.order_client_json(v_order);
end;
$f$;

-- Devis manuel admin : SECOTO encaisse aussi la totalité.
do $price_quote$
declare v_src text;
begin
  select pg_get_functiondef(p.oid) into v_src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'secoto_admin_price_quote';
  if v_src is null then return; end if;
  v_src := replace(v_src,
    'collect_cents = case when mode = ''plateau'' then v_margin else p_client_price_cents end,',
    'collect_cents = p_client_price_cents,');
  v_src := replace(v_src,
    'transport_direct_cents = case when mode = ''plateau'' then p_partner_pay_cents else 0 end,',
    'transport_direct_cents = 0,');
  execute v_src;
end
$price_quote$;

-- ----------------------------------------------------------------------------
-- 13. SOUS-TRAITANCE TOTALE SUR LES MISSIONS MANUELLES
-- ----------------------------------------------------------------------------
-- Les missions créées AVANT la bascule gardent strictement leurs montants :
-- aucune mission en cours n'est modifiée. À partir de la bascule, le plateau
-- suit la même règle que le convoyage : SECOTO encaisse tout, puis reverse.
create or replace function public.secoto_trg_mission_amounts()
returns trigger
language plpgsql
set search_path = ''
as $function$
declare
  v_type      text    := coalesce(new.type::text, 'convoyage');
  v_manual    boolean := coalesce(new.manual_pricing, false);
  v_carrier   numeric;
  v_margin    numeric;
  v_client    numeric;
  v_transport numeric;
  v_cutover   timestamptz;
begin
  if v_manual then
    v_carrier := round(greatest(coalesce(new.manual_carrier_pay, 0), 0), 2);
    v_margin  := round(greatest(coalesce(new.manual_margin, 0), 0), 2);

    select (s.value ->> 'sous_traitance_totale_since')::timestamptz into v_cutover
      from public.app_settings s where s.key = 'dispatch_policy';

    if v_type = 'plateau'
       and (v_cutover is null or coalesce(new.created_at, now()) < v_cutover) then
      -- Ancien modèle d'intermédiation : conservé pour les missions antérieures.
      v_client    := v_margin;
      v_transport := v_carrier;
    else
      -- Sous-traitance : SECOTO encaisse la totalité, puis règle le transporteur.
      v_client    := round(v_carrier + v_margin, 2);
      v_transport := 0;
    end if;

    new.carrier_cost := v_carrier;
  else
    v_carrier := public.secoto_compute_carrier_pay(
      v_type, new.distance_km, new.carrier_cost);
    v_client := public.secoto_compute_client_price(
      v_type, new.distance_km, new.carrier_cost,
      new.surcharge_urgent, new.surcharge_weekend, new.surcharge_oversize_pct);
    v_margin := public.secoto_compute_margin(
      v_type, new.distance_km, new.carrier_cost,
      new.surcharge_urgent, new.surcharge_weekend, new.surcharge_oversize_pct);
    v_transport := public.secoto_compute_transport_amount(v_type, new.carrier_cost);
  end if;

  new.carrier_pay       := v_carrier;
  new.client_price      := v_client;
  new.margin            := v_margin;
  new.commission_amount := case when v_type = 'plateau' then round(v_client, 2) else 0 end;
  new.transport_amount  := round(coalesce(v_transport, 0), 2);
  new.client_total_due  := round(v_client + coalesce(v_transport, 0), 2);

  return new;
end;
$function$;

-- ----------------------------------------------------------------------------
-- 14. FIN DES CANDIDATURES : accepter ou refuser, partout
-- ----------------------------------------------------------------------------
-- Le tableau des missions publiées affiche désormais la rémunération et l'état
-- du véhicule. Aucune information client ni marge n'y figure.
create or replace view public.secoto_public_missions_v2
with (security_barrier = true, security_invoker = false)
as
select
  m.id, m.public_ref, m.type, m.status, m.progress_status,
  m.from_city, m.to_city, m.vehicle, m.distance_km, m.created_at,
  m.vehicle_category,
  m.capacity_units, m.window_start, m.window_end,
  m.mission_date,
  coalesce(m.vehicle_rolling, true) as vehicle_rolling,
  m.carrier_pay
  -- JAMAIS client_price, margin, commission_amount ni client_total_due ici.
from public.missions m
where public.secoto_current_transporter_matches_mission(m.id)
  and not exists (select 1 from public.mission_declines d where d.mission_id = m.id and d.partner_id = auth.uid());

grant select on table public.secoto_public_missions_v2 to authenticated;

create or replace function public.secoto_mission_accept(p_mission_id uuid, p_idempotency_key uuid)
returns jsonb language plpgsql volatile security definer set search_path = ''
as $f$
declare
  v_user uuid := secoto_private.assert_authenticated();
  v_existing jsonb;
  v_mission public.missions%rowtype;
  v_account public.accounts%rowtype;
begin
  if not secoto_private.flag('direct_accept') then
    raise exception 'L''acceptation directe n''est pas encore ouverte.';
  end if;
  v_existing := secoto_private.lock_operation('mission_accept', p_idempotency_key);
  if v_existing is not null then return v_existing; end if;

  select * into v_account from public.accounts a where a.id = v_user;
  if not secoto_private.is_verified_transporter(v_user) then
    raise exception 'Votre compte transporteur doit être vérifié par SECOTO.';
  end if;

  -- Verrou de ligne : une seule acceptation peut gagner.
  select * into v_mission from public.missions m where m.id = p_mission_id for update;
  if not found then raise exception 'Mission introuvable.' using errcode = 'P0002'; end if;
  if v_mission.assigned_transporter_id = v_user then
    return secoto_private.finish_operation('mission_accept', p_idempotency_key,
      jsonb_build_object('result', 'already_yours', 'mission_id', p_mission_id));
  end if;
  if v_mission.status::text <> 'published' or v_mission.assigned_transporter_id is not null then
    raise exception 'Mission déjà attribuée.' using errcode = 'P0002';
  end if;
  if not secoto_private.transporter_matches_mission(v_user, p_mission_id) then
    raise exception 'Cette mission ne correspond pas à votre profil de transporteur.';
  end if;

  update public.missions
     set status = 'assigned', progress_status = 'assigned_pending',
         assigned_transporter_id = v_user,
         assigned_transporter_name = coalesce(v_account.company_name, v_account.full_name)
   where id = p_mission_id returning * into v_mission;

  perform secoto_private.notify_event(v_user, 'course_assigned', 'Mission acceptée',
    format('%s → %s · %s', v_mission.from_city, v_mission.to_city, v_mission.vehicle),
    p_mission_id, 'assigned', 'mission-accept:' || p_mission_id::text, p_mission_id);
  perform secoto_private.notify_admins_event('course_assigned', 'Mission acceptée',
    format('%s · %s', v_mission.public_ref, coalesce(v_account.company_name, v_account.full_name)),
    'requests', 'mission-accept-admin:' || p_mission_id::text, p_mission_id);
  perform secoto_private.audit('mission_accepted_direct', 'mission', p_mission_id::text,
    jsonb_build_object('partner_id', v_user, 'carrier_pay', v_mission.carrier_pay));

  return secoto_private.finish_operation('mission_accept', p_idempotency_key,
    jsonb_build_object('result', 'assigned', 'mission_id', p_mission_id));
end;
$f$;

create or replace function public.secoto_mission_decline(p_mission_id uuid)
returns jsonb language plpgsql volatile security definer set search_path = ''
as $f$
declare v_user uuid := secoto_private.assert_authenticated();
begin
  insert into public.mission_declines(mission_id, partner_id) values (p_mission_id, v_user)
  on conflict do nothing;
  return jsonb_build_object('result', 'declined', 'mission_id', p_mission_id);
end;
$f$;

-- La candidature avec prix proposé est fermée dès que l'acceptation directe
-- est ouverte : un seul chemin, pas deux comportements possibles.
do $apply_guard$
declare v_src text; v_args text;
begin
  select pg_get_functiondef(p.oid), pg_get_function_identity_arguments(p.oid) into v_src, v_args
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'secoto_apply_to_mission';
  if v_src is null then return; end if;
  v_src := replace(v_src,
    'if not secoto_private.is_verified_transporter(v_user_id) then',
    'if secoto_private.flag(''direct_accept'') then' || E'\n' ||
    '    raise exception ''Les candidatures sont remplacées par l''''acceptation directe : la rémunération est affichée, vous acceptez ou vous refusez.'';' || E'\n' ||
    '  end if;' || E'\n' ||
    '  if not secoto_private.is_verified_transporter(v_user_id) then');
  execute v_src;
end
$apply_guard$;

-- ----------------------------------------------------------------------------
-- 14 bis. CE QUE VOIT LE TRANSPORTEUR SUR UNE PROPOSITION
-- ----------------------------------------------------------------------------
-- SECOTO encaisse le client puis règle le transporteur : plus aucun transport
-- n'est payé en direct sur le plateau. Le convoyage garde ses frais réels
-- remboursés sur justificatifs (barème validé, inchangé).
create or replace function secoto_private.offer_partner_json(x public.transport_offers)
returns jsonb language sql stable security definer set search_path = ''
as $f$
  select jsonb_build_object(
    'id', x.id, 'order_ref', o.public_ref, 'mode', o.mode,
    'state', case
      when o.assigned_partner_id = x.partner_id then 'confirmed'
      when o.status = 'partner_locked' and o.lock_partner_id = x.partner_id then 'pending_capture'
      when o.status in ('partner_locked', 'partner_confirmed', 'picked_up', 'delivered') then 'already_assigned'
      when o.status in ('cancelled', 'no_partner') then 'unavailable'
      when x.status = 'declined' then 'declined'
      when x.status in ('expired', 'voided', 'withdrawn', 'lost') or x.expires_at <= now() or x.round <> o.dispatch_round then 'expired'
      else 'available' end,
    'partner_pay_cents', x.partner_pay_cents,
    'expires_at', x.expires_at,
    'pickup', jsonb_build_object('label', q.pickup ->> 'label', 'city', q.pickup ->> 'city', 'postcode', q.pickup ->> 'postcode'),
    'delivery', jsonb_build_object('label', q.delivery ->> 'label', 'city', q.delivery ->> 'city', 'postcode', q.delivery ->> 'postcode'),
    'distance_km', q.route -> 'distance_km', 'duration_min', q.route -> 'duration_min',
    'vehicle', q.vehicle, 'schedule', q.schedule, 'pickup_at', o.pickup_at,
    'partner_included', case when o.mode = 'convoyage'
      then jsonb_build_array(
        'Frais réels (carburant, péages) remboursés sur justificatifs validés',
        'Rémunération versée par SECOTO sous 48 h après la livraison')
      else jsonb_build_array(
        'Péages et carburant inclus dans votre rémunération',
        'Rémunération versée par SECOTO sous 48 h après la livraison') end,
    'partner_excluded', case when o.mode = 'convoyage'
      then jsonb_build_array('Retour après livraison : à votre charge')
      else jsonb_build_array('Retour à vide après livraison : à votre charge') end,
    'mission_id', case when o.assigned_partner_id = x.partner_id then o.mission_id end)
  from public.transport_orders o join public.transport_quotes q on q.id = o.quote_id
  where o.id = x.order_id;
$f$;

-- ----------------------------------------------------------------------------
-- 15. DROITS
-- ----------------------------------------------------------------------------
grant execute on function public.secoto_od_cancel_quote_preview(uuid) to authenticated;
grant execute on function public.secoto_mission_accept(uuid, uuid) to authenticated;
grant execute on function public.secoto_mission_decline(uuid) to authenticated;
grant execute on function public.secoto_admin_od_update_conditions(uuid, jsonb, text) to authenticated;
grant execute on function secoto_private.next_doc_number(text) to service_role;
grant execute on function secoto_private.policy_text(text, text) to authenticated, service_role;

-- ----------------------------------------------------------------------------
-- 16. CONTRÔLES
-- ----------------------------------------------------------------------------
do $verif$
declare v numeric; v_txt text;
begin
  select (s.value ->> 'offer_ttl_minutes')::numeric into v from public.app_settings s where s.key = 'dispatch_policy';
  if v <> 2880 then raise exception 'Fenêtre d''offre : % minutes au lieu de 2880 (48 h)', v; end if;
  select (s.value ->> 'max_rounds')::numeric into v from public.app_settings s where s.key = 'dispatch_policy';
  if v <> 1 then raise exception 'Un seul tour de diffusion attendu, % trouvé', v; end if;
  if secoto_private.policy_num('payout_delay_hours', 0) <> 48 then raise exception 'Délai de versement transporteur incorrect.'; end if;
  if secoto_private.policy_num('free_cancel_hours_before_pickup', 0) <> 24 then raise exception 'Fenêtre d''annulation gratuite incorrecte.'; end if;
  if secoto_private.policy_num('late_cancel_retained_pct', 0) <> 50 then raise exception 'Retenue d''annulation tardive incorrecte.'; end if;
  v_txt := secoto_private.policy_text('tva', '');
  if position('293 B' in v_txt) = 0 then raise exception 'Mention de TVA absente : %', v_txt; end if;
  if not exists (select 1 from public.secoto_feature_flags f where f.key = 'direct_accept') then
    raise exception 'Interrupteur direct_accept absent.';
  end if;
  if exists (select 1 from public.secoto_feature_flags f where f.key = 'direct_accept' and f.enabled) then
    raise exception 'direct_accept ne doit pas être activé par la migration.';
  end if;
end
$verif$;

notify pgrst, 'reload schema';
commit;


-- ============================================================================
-- OUVERTURE DES INTERRUPTEURS — à exécuter SÉPARÉMENT, quand vous êtes prêt.
-- Retirez les « -- » devant les lignes voulues, puis exécutez la sélection.
-- ============================================================================
-- update public.secoto_feature_flags set enabled = true, updated_at = now()
--  where key in ('auto_pricing', 'od_payments', 'dispatch_notifications', 'live_tracking', 'direct_accept');
-- notify pgrst, 'reload schema';

-- Pour vérifier l'état à tout moment :
-- select key, enabled, updated_at from public.secoto_feature_flags order by key;
