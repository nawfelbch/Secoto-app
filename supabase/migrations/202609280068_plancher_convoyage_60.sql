-- ============================================================================
-- SECOTO — 068 : PREMIER PRIX DU CONVOYAGE RAMENE A 60 EUR
-- ----------------------------------------------------------------------------
-- Decision du 28/09/2026, prise sur un retour terrain : deux societes de VTC
-- ont demande le tarif minimum et l'ont toutes deux trouve trop cher. Le
-- premier prix en convoyage passe de 115 EUR a 60 EUR.
--
-- UN SEUL TARIF, POUR TOUT LE MONDE
--   Le tarif n'est pas reserve aux professionnels. Tres peu de particuliers
--   choisissent le convoyage, et encore moins sur de courtes distances : un
--   tarif reserve aurait complique le bareme sans rien proteger, et il aurait
--   laisse le simulateur afficher 115 EUR a une societe qui decouvre
--   l'application — exactement le prix qui vient de lui faire dire non.
--
-- CE QUI NE CHANGE PAS
--   - le PLATEAU, dans tous les cas : plancher 115 EUR et tarifs inchanges ;
--   - le tarif au kilometre en convoyage : 1,00 EUR/km. Seul le PLANCHER
--     change, ce qui revient exactement a « moins de 60 km = 60 EUR ».
--
-- LA REMUNERATION DU CONVOYEUR
--   La part du convoyeur suit le plancher proportionnellement : un plancher a
--   60 EUR lui donnerait 33 EUR meme pour 5 km. Un plancher qui lui est propre
--   est donc introduit, a 12 EUR. Au-dela de 22 km c'est le kilometrage qui le
--   paie et ce plancher ne sert plus.
--
-- ATTENTION, PIEGE RENCONTRE A LA PREMIERE TENTATIVE
--   Le nom « partner_minimum_eur » existe DEJA dans price_with_grid, mais dans
--   la branche historique des paliers, inutilisee par les grilles actuelles.
--   Un garde qui se contente de chercher ce nom conclut donc a tort que la
--   fonction est deja patchee, et la saute en silence : le prix client baisse,
--   la remuneration non. Le garde porte donc sur l'expression complete, et le
--   patch est VERIFIE en appelant reellement la fonction juste apres.
--
-- CE QUE CELA DONNE EN CONVOYAGE
--   10 km : client 60,00  convoyeur 12,00  marge 48,00  (80 %)
--   40 km : client 60,00  convoyeur 22,00  marge 38,00  (63 %)
--   60 km : client 60,00  convoyeur 33,00  marge 27,00  (45 %, taux habituel)
--   80 km : client 80,00  convoyeur 44,00  marge 36,00  (45 %)
-- ============================================================================

create or replace function secoto_private.compter_occurrences(p_texte text, p_ancre text)
returns integer language sql immutable set search_path = ''
as $f$
  select case when coalesce(p_ancre, '') = '' then 0
         else (length(p_texte) - length(replace(p_texte, p_ancre, ''))) / length(p_ancre) end;
$f$;

-- 1. Un plancher de remuneration propre au convoyeur --------------------------
do $patch_plancher$
declare
  v_src   text;
  v_new   text;
  v_essai jsonb;
  v_ancre constant text :=
    'v_partner := greatest(v_partner, round(v_minimum * v_partner_rate / v_client_rate, 2));';
  v_patch constant text :=
    'v_partner := greatest(v_partner, coalesce((p ->> ''partner_minimum_eur'')::numeric, round(v_minimum * v_partner_rate / v_client_rate, 2)));';
begin
  select pg_get_functiondef(p.oid) into v_src
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'secoto_private' and p.proname = 'price_with_grid';

  if v_src is null then
    raise exception 'secoto_private.price_with_grid absente : appliquez d''abord la migration 034.';
  end if;

  -- Le garde porte sur l'expression patchee, pas sur le seul nom du parametre.
  if position(v_patch in v_src) = 0 then
    if secoto_private.compter_occurrences(v_src, v_ancre) <> 1 then
      raise exception 'Ancre du plancher absente ou ambigue dans price_with_grid. Source reelle : %',
        left(v_src, 1500);
    end if;
    v_new := replace(v_src, v_ancre, v_patch);
    execute v_new;
  end if;

  -- Verification immediate : une grille d'essai, et la fonction doit rendre
  -- 12 EUR. Sans ce controle, un patch saute passerait inapercu.
  v_essai := secoto_private.price_with_grid(
    'convoyage',
    jsonb_build_object(
      'pricing_method', 'per_class',
      'class_rates', jsonb_build_object(
        'voiture', jsonb_build_object('client_eur_per_km', 1.00, 'partner_eur_per_km', 0.55)),
      'minimum_eur', 60,
      'partner_minimum_eur', 12,
      'auto_vehicle_classes', jsonb_build_array('voiture'),
      'min_margin_pct', 0),
    10,
    jsonb_build_object('class', 'voiture', 'category', 'standard', 'rolling', true),
    null);

  if (v_essai ->> 'partner_cents')::int <> 1200 then
    raise exception 'price_with_grid ignore le plancher de remuneration : % centimes au lieu de 1200',
      coalesce(v_essai ->> 'partner_cents', v_essai ->> 'manual_reason');
  end if;

  raise notice 'price_with_grid honore le plancher de remuneration du convoyeur';
end
$patch_plancher$;

drop function if exists secoto_private.compter_occurrences(text, text);

-- 2. Le nouveau plancher, dans la grille convoyage ----------------------------
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

  if (v_params ->> 'minimum_eur')::numeric = 60
     and (v_params ->> 'partner_minimum_eur')::numeric = 12 then
    raise notice 'Le plancher est deja a 60 EUR : rien a faire';
    return;
  end if;

  v_params := v_params || jsonb_build_object('minimum_eur', 60, 'partner_minimum_eur', 12);

  perform secoto_private.validate_grid_params('convoyage', v_params);

  select coalesce(max(version), 0) + 1 into v_version
  from public.pricing_grids where mode = 'convoyage';

  update public.pricing_grids
     set status = 'archived'
   where mode = 'convoyage' and status = 'active';

  insert into public.pricing_grids(mode, version, status, params, source_note, activated_at)
  values (
    'convoyage', v_version, 'active', v_params,
    'Premier prix du convoyage ramene de 115 a 60 EUR le 28/09/2026, pour tous '
    'les clients. Plancher de remuneration du convoyeur pose a 12 EUR. Tarif au '
    'kilometre et plateau inchanges.',
    now());

  raise notice 'Grille convoyage version % activee', v_version;
end
$grille$;

-- 3. Controles bloquants ------------------------------------------------------
do $controles$
declare
  v_conv jsonb;
  v_plat jsonb;
  v_prix jsonb;
  v_auto jsonb := jsonb_build_object('class', 'voiture', 'category', 'standard', 'rolling', true);
  v_util jsonb := jsonb_build_object('class', 'utilitaire', 'category', 'standard', 'rolling', true);
begin
  select params into v_conv
  from public.pricing_grids where mode = 'convoyage' and status = 'active';

  if (v_conv ->> 'minimum_eur')::numeric <> 60
     or (v_conv ->> 'partner_minimum_eur')::numeric <> 12 then
    raise exception 'La grille convoyage ne porte pas le nouveau plancher';
  end if;

  v_prix := secoto_private.price_with_grid('convoyage', v_conv, 10, v_auto, null);
  if (v_prix ->> 'client_cents')::int <> 6000 or (v_prix ->> 'partner_cents')::int <> 1200 then
    raise exception 'Convoyage 10 km : % / % (attendu 6000 / 1200)',
      v_prix ->> 'client_cents', v_prix ->> 'partner_cents';
  end if;

  v_prix := secoto_private.price_with_grid('convoyage', v_conv, 40, v_auto, null);
  if (v_prix ->> 'client_cents')::int <> 6000 or (v_prix ->> 'partner_cents')::int <> 2200 then
    raise exception 'Convoyage 40 km : % / % (attendu 6000 / 2200)',
      v_prix ->> 'client_cents', v_prix ->> 'partner_cents';
  end if;

  -- A 60 km, fin du forfait : le taux habituel reprend, marge a 45 %.
  v_prix := secoto_private.price_with_grid('convoyage', v_conv, 60, v_auto, null);
  if (v_prix ->> 'client_cents')::int <> 6000 or (v_prix ->> 'partner_cents')::int <> 3300 then
    raise exception 'Convoyage 60 km : % / % (attendu 6000 / 3300)',
      v_prix ->> 'client_cents', v_prix ->> 'partner_cents';
  end if;

  v_prix := secoto_private.price_with_grid('convoyage', v_conv, 80, v_auto, null);
  if (v_prix ->> 'client_cents')::int <> 8000 or (v_prix ->> 'partner_cents')::int <> 4400 then
    raise exception 'Convoyage 80 km : % / % (attendu 8000 / 4400)',
      v_prix ->> 'client_cents', v_prix ->> 'partner_cents';
  end if;

  v_prix := secoto_private.price_with_grid('convoyage', v_conv, 20, v_util, null);
  if (v_prix ->> 'client_cents')::int <> 6000 or (v_prix ->> 'partner_cents')::int <> 1300 then
    raise exception 'Convoyage utilitaire 20 km : % / % (attendu 6000 / 1300)',
      v_prix ->> 'client_cents', v_prix ->> 'partner_cents';
  end if;

  -- LE PLATEAU NE BOUGE PAS.
  select params into v_plat
  from public.pricing_grids where mode = 'plateau' and status = 'active';
  if (v_plat ->> 'minimum_eur')::numeric <> 115 then
    raise exception 'Le plancher plateau a ete modifie alors qu''il ne devait pas l''etre';
  end if;
  if (v_plat ->> 'partner_minimum_eur') is not null then
    raise exception 'Un plancher de remuneration a ete pose sur le plateau par erreur';
  end if;

  v_prix := secoto_private.price_with_grid('plateau', v_plat, 500, v_auto, null);
  if (v_prix ->> 'client_cents')::int <> 60000 or (v_prix ->> 'partner_cents')::int <> 50000 then
    raise exception 'Plateau voiture 500 km : % / % (attendu 60000 / 50000)',
      v_prix ->> 'client_cents', v_prix ->> 'partner_cents';
  end if;

  raise notice 'OK : convoyage a 60 EUR sous 60 km pour tous, convoyeur au plancher de 12 EUR. Plateau inchange.';
end
$controles$;
