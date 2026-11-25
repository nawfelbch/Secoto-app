-- ============================================================================
-- SECOTO 161 — Convoyage : le prix au kilomètre couvre le carburant et les péages
-- ----------------------------------------------------------------------------
-- Demande de Nawfal du 25/11/2026. Depuis la 158, carburant et péages du
-- convoyage sont à la charge de SECOTO (remboursés au convoyeur, 159), mais le
-- prix client était resté à 1,00 €/km pour toutes les catégories. Contrôle de
-- rentabilité (pire cas : carburant cher + autoroute, URSSAF 21,2 % de la
-- marge, carte 1,5 % + 0,25 € sous 500 €, Klarna 5 % dès 500 €) :
--   · UTILITAIRE à 1,00 €/km : PERTE dès 60 km (−62 € à 500 km, −124 € à
--     1 000 km) — frais ≈ 0,35 €/km (gazole ~11 L/100, péages classe 2) ;
--   · VOITURE à 1,00 €/km : 5 à 45 € nets seulement (frais ≈ 0,26 €/km) ;
--   · MOTO à 1,00 €/km : correct (frais ≈ 0,15 €/km), inchangée.
-- Nouvelle grille (rémunération des convoyeurs INCHANGÉE : 0,55 / 0,65 €/km) :
--   voiture 1,15 €/km · moto 1,00 €/km · utilitaire 1,40 €/km.
-- Pire cas obtenu : voiture +78 € à 500 km, +155 € à 1 000 km ; utilitaire
-- +86 € à 500 km, +171 € à 1 000 km. Plancher 60 € inchangé (décision 068).
-- Limites connues (non traitées ici) : trajets courts (< 150 km) toujours
-- minces (≈ 10 à 30 € nets) ; gros moteurs (V8…) plus gourmands que la moyenne :
-- prix à vérifier à la main sur les longs trajets.
-- Nouveaux devis seulement : aucune commande ni aucun devis existant ne change.
-- Migration rejouable (ne recrée pas de version si les taux sont déjà en place).
-- ============================================================================

do $grille$
declare
  v_params  jsonb;
  v_version integer;
begin
  select params into v_params
    from public.pricing_grids where mode = 'convoyage' and status = 'active';
  if v_params is null then
    raise exception 'Aucune grille convoyage active : migration impossible';
  end if;

  if (v_params #>> '{class_rates,voiture,client_eur_per_km}')::numeric = 1.15
     and (v_params #>> '{class_rates,utilitaire,client_eur_per_km}')::numeric = 1.40 then
    raise notice '161 déjà appliquée : rien à faire';
    return;
  end if;

  v_params := jsonb_set(v_params, '{class_rates,voiture,client_eur_per_km}', to_jsonb(1.15));
  v_params := jsonb_set(v_params, '{class_rates,utilitaire,client_eur_per_km}', to_jsonb(1.40));
  v_params := jsonb_set(v_params, '{class_rates,moto,client_eur_per_km}', to_jsonb(1.00));

  perform secoto_private.validate_grid_params('convoyage', v_params);

  select coalesce(max(version), 0) + 1 into v_version
    from public.pricing_grids where mode = 'convoyage';

  update public.pricing_grids set status = 'archived'
   where mode = 'convoyage' and status = 'active';

  insert into public.pricing_grids(mode, version, status, params, source_note, activated_at)
  values ('convoyage', v_version, 'active', v_params,
          '161 (25/11/2026) : carburant et péages à la charge de SECOTO (158) -> voiture 1,15 €/km, '
          || 'utilitaire 1,40 €/km, moto 1,00 €/km. Rémunération convoyeur et plancher 60 € inchangés.',
          now());
  raise notice 'Grille convoyage version % activée', v_version;
end
$grille$;

-- Contrôles bloquants (prix client / rémunération convoyeur).
do $controles$
declare
  v_conv jsonb;
  v_prix jsonb;
  v_auto jsonb := '{"class":"voiture","category":"standard","rolling":true}';
  v_util jsonb := '{"class":"utilitaire","category":"standard","rolling":true}';
  v_moto jsonb := '{"class":"moto","category":"standard","rolling":true}';
begin
  select params into v_conv from public.pricing_grids where mode = 'convoyage' and status = 'active';

  v_prix := secoto_private.price_with_grid('convoyage', v_conv, 1000, v_auto, null);
  if (v_prix ->> 'client_cents')::int <> 115000 or (v_prix ->> 'partner_cents')::int <> 55000 then
    raise exception 'Voiture 1 000 km : % / % (attendu 115000 / 55000)', v_prix ->> 'client_cents', v_prix ->> 'partner_cents';
  end if;

  v_prix := secoto_private.price_with_grid('convoyage', v_conv, 600, v_util, null);
  if (v_prix ->> 'client_cents')::int <> 84000 or (v_prix ->> 'partner_cents')::int <> 39000 then
    raise exception 'Utilitaire 600 km : % / % (attendu 84000 / 39000)', v_prix ->> 'client_cents', v_prix ->> 'partner_cents';
  end if;

  v_prix := secoto_private.price_with_grid('convoyage', v_conv, 500, v_moto, null);
  if (v_prix ->> 'client_cents')::int <> 50000 or (v_prix ->> 'partner_cents')::int <> 27500 then
    raise exception 'Moto 500 km : % / % (attendu 50000 / 27500)', v_prix ->> 'client_cents', v_prix ->> 'partner_cents';
  end if;

  -- Plancher 60 € inchangé.
  v_prix := secoto_private.price_with_grid('convoyage', v_conv, 20, v_auto, null);
  if (v_prix ->> 'client_cents')::int <> 6000 then
    raise exception 'Voiture 20 km : % (attendu 6000, plancher)', v_prix ->> 'client_cents';
  end if;

  raise notice 'OK 161 : voiture 1,15 €/km, utilitaire 1,40 €/km, moto 1,00 €/km, plancher 60 €.';
end
$controles$;

notify pgrst, 'reload schema';
