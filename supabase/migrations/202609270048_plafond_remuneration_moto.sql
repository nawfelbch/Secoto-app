-- ============================================================================
-- SECOTO — MIGRATION 048 : PLAFOND DE REMUNERATION PAR CATEGORIE
-- ----------------------------------------------------------------------------
-- Decision de Nawfal du 27/09/2026 : sur une moto, la remuneration du
-- transporteur s'arrete a 300 €.
--
-- Le prix client etait deja plafonne a 400 €, et la part transporteur suivait
-- la meme proportion : au plafond, le transporteur touchait 340 € et il ne
-- restait que 60 € a SECOTO, quelle que soit la distance. Une moto Lille-Nice
-- rapportait autant qu'une moto Paris-Rouen, pour un risque et un suivi bien
-- superieurs.
--
-- Le barème gagne donc un second plafond, cote transporteur. Au-dela de
-- 353 km, une moto laisse desormais au moins 100 € a SECOTO.
-- ============================================================================

-- 1. Le calcul respecte un plafond de remuneration ----------------------------
-- Le repere est structurel (le bloc « urgence » qui suit le plancher), pas un
-- commentaire : un texte accentue ou reindente ailleurs ne doit pas empecher
-- le correctif de s'appliquer.
do $patch$
declare
  v_src text;
  v_neuf text;
  v_bloc text;
begin
  select pg_get_functiondef(p.oid) into v_src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'secoto_private' and p.proname = 'price_with_grid';

  if v_src is null then
    raise exception 'secoto_private.price_with_grid absente : appliquez d''abord la migration 034.';
  end if;
  if position('partner_cap_eur' in v_src) > 0 then
    raise notice 'Plafond de remuneration deja pris en compte.';
    return;
  end if;

  v_bloc :=
    '    -- Plafond de remuneration : au-dela, la distance ne paie plus davantage' || chr(10) ||
    '    -- le transporteur. Pose apres le plancher, pour borner aussi les montants' || chr(10) ||
    '    -- releves par le forfait minimum.' || chr(10) ||
    '    if (v_rule ->> ''partner_cap_eur'') is not null' || chr(10) ||
    '       and v_partner > (v_rule ->> ''partner_cap_eur'')::numeric then' || chr(10) ||
    '      v_partner := (v_rule ->> ''partner_cap_eur'')::numeric;' || chr(10) ||
    '    end if;' || chr(10);

  -- Premiere occurrence seulement : celle de la branche « per_class ».
  v_neuf := regexp_replace(v_src, '(\n[ \t]*if v_urgent_pct > 0)', chr(10) || v_bloc || '\1');
  if v_neuf = v_src then
    raise exception 'Point d''insertion introuvable dans price_with_grid : correctif non applique.';
  end if;

  execute v_neuf;
  raise notice 'Plafond de remuneration pris en compte.';
end;
$patch$;

-- 1 bis. Un plafond incoherent est refuse a l'ecriture --------------------------
-- Confort, pas securite : si le point d'insertion bouge, on previent sans
-- bloquer le plafond lui-meme, qui est la vraie decision.
do $garde$
declare
  v_src text;
  v_neuf text;
  v_bloc text;
begin
  select pg_get_functiondef(p.oid) into v_src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'secoto_private' and p.proname = 'validate_grid_params';

  if v_src is null then
    raise notice 'validate_grid_params absente : controle non pose.';
    return;
  end if;
  if position('partner_cap_eur' in v_src) > 0 then
    raise notice 'Controle du plafond de remuneration deja en place.';
    return;
  end if;

  v_bloc :=
    '      if (v_rule ->> ''partner_cap_eur'') is not null' || chr(10) ||
    '         and ((v_rule ->> ''partner_cap_eur'')::numeric <= 0' || chr(10) ||
    '              or ((v_rule ->> ''client_cap_eur'') is not null' || chr(10) ||
    '                  and (v_rule ->> ''partner_cap_eur'')::numeric >= (v_rule ->> ''client_cap_eur'')::numeric)) then' || chr(10) ||
    '        raise exception ''Bareme invalide : plafond de remuneration absurde pour %.'', v_class;' || chr(10) ||
    '      end if;';

  -- On se pose juste avant la fin de la boucle qui parcourt les categories.
  v_neuf := regexp_replace(v_src, '(\n[ \t]*end loop;)', chr(10) || v_bloc || '\1');
  if v_neuf = v_src then
    raise notice 'Boucle des categories introuvable : controle non pose, le plafond reste applique.';
    return;
  end if;

  execute v_neuf;
  raise notice 'Controle du plafond de remuneration pose.';
exception when others then
  raise notice 'Controle du plafond non pose (%) : le plafond reste applique.', sqlerrm;
end;
$garde$;

-- 2. La moto plafonne a 300 € pour le transporteur -----------------------------
do $grille$
declare v_params jsonb; v_version integer;
begin
  select params into v_params from public.pricing_grids where mode = 'plateau' and status = 'active';
  if v_params is null
     or (v_params -> 'class_rates' -> 'moto' ->> 'partner_cap_eur')::numeric = 300 then
    raise notice 'Grille plateau deja a jour.';
    return;
  end if;

  v_params := jsonb_set(v_params, '{class_rates,moto}',
    (v_params -> 'class_rates' -> 'moto') || jsonb_build_object('partner_cap_eur', 300));

  perform secoto_private.validate_grid_params('plateau', v_params);
  select coalesce(max(version), 0) + 1 into v_version from public.pricing_grids where mode = 'plateau';
  update public.pricing_grids set status = 'archived' where mode = 'plateau' and status = 'active';
  insert into public.pricing_grids(mode, version, status, params, source_note, activated_at)
  values ('plateau', v_version, 'active', v_params,
    'Barème plateau du 27/09/2026 — moto : remuneration transporteur plafonnee a 300 €. Prix client inchange (1,00 €/km, plafond 400 €). Voiture et utilitaire inchangees.',
    now());
  raise notice 'Grille plateau v% activee.', v_version;
end
$grille$;

-- 3. Controle -------------------------------------------------------------------
-- Une moto de 800 km doit donner : client 400 €, transporteur 300 €, marge 100 €.
with calcul as (
  select secoto_private.price_with_grid(
    'plateau',
    (select params from public.pricing_grids where mode = 'plateau' and status = 'active'),
    800,
    jsonb_build_object('class', 'moto', 'category', 'standard', 'rolling', true),
    null) as r
)
select (r ->> 'client_cents')::int / 100.0  as client_eur,
       (r ->> 'partner_cents')::int / 100.0 as transporteur_eur,
       (r ->> 'margin_cents')::int / 100.0  as marge_eur
  from calcul;

notify pgrst, 'reload schema';
