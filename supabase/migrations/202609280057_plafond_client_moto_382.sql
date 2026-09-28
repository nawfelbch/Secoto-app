-- ============================================================================
-- SECOTO — 057 : PLAFOND CLIENT MOTO RAMENE DE 400 A 382 EUR
-- ----------------------------------------------------------------------------
-- Decision du 28/09/2026, deja appliquee en production le jour meme. Cette
-- migration la rend reproductible.
--
-- Seul le prix client change. La remuneration du transporteur reste plafonnee
-- a 300 EUR : 382 x 0,85 = 324,70 EUR depasse encore ce plafond, donc le
-- transporteur percoit 300 EUR comme avant, a toutes les distances.
-- Marge SECOTO au plafond : 82 EUR au lieu de 100 EUR.
-- ============================================================================

do $plafond_moto$
declare
  v_params  jsonb;
  v_version integer;
begin
  select params into v_params
  from public.pricing_grids
  where mode = 'plateau' and status = 'active';

  if v_params is null then
    raise exception 'Aucune grille plateau active : migration impossible';
  end if;

  if (v_params -> 'class_rates' -> 'moto' ->> 'client_cap_eur')::numeric = 382 then
    raise notice 'Plafond client moto deja a 382 EUR : rien a faire';
    return;
  end if;

  v_params := jsonb_set(
    v_params, '{class_rates,moto,client_cap_eur}', to_jsonb(382::numeric));

  -- Refuse une grille incoherente avant de la rendre active.
  perform secoto_private.validate_grid_params('plateau', v_params);

  select coalesce(max(version), 0) + 1 into v_version
  from public.pricing_grids where mode = 'plateau';

  update public.pricing_grids
     set status = 'archived'
   where mode = 'plateau' and status = 'active';

  insert into public.pricing_grids(mode, version, status, params, source_note, activated_at)
  values (
    'plateau', v_version, 'active', v_params,
    'Plafond client moto ramene de 400 a 382 EUR le 28/09/2026. '
    'Remuneration transporteur inchangee : plafond partenaire maintenu a 300 EUR.',
    now());

  raise notice 'Grille plateau version % activee', v_version;
end
$plafond_moto$;

-- ============================================================================
-- CONTROLES BLOQUANTS
-- ============================================================================
do $controle$
declare
  v_params jsonb;
  v_prix   jsonb;
  v_moto   jsonb := jsonb_build_object('class', 'moto',    'category', 'standard', 'rolling', true);
  v_auto   jsonb := jsonb_build_object('class', 'voiture', 'category', 'standard', 'rolling', true);
begin
  select params into v_params
  from public.pricing_grids where mode = 'plateau' and status = 'active';

  -- 1. Moto longue distance : plafond client a 382, transporteur toujours 300.
  v_prix := secoto_private.price_with_grid('plateau', v_params, 500, v_moto, null);
  if (v_prix ->> 'client_cents')::int <> 38200 then
    raise exception 'Moto 500 km : client % (attendu 38200)', v_prix ->> 'client_cents';
  end if;
  if (v_prix ->> 'partner_cents')::int <> 30000 then
    raise exception 'Moto 500 km : transporteur % (attendu 30000, il ne doit pas bouger)',
      v_prix ->> 'partner_cents';
  end if;

  -- 2. Moto sous le plafond : rien ne change.
  v_prix := secoto_private.price_with_grid('plateau', v_params, 300, v_moto, null);
  if (v_prix ->> 'client_cents')::int <> 30000
     or (v_prix ->> 'partner_cents')::int <> 25500 then
    raise exception 'Moto 300 km : % / % (attendu 30000 / 25500)',
      v_prix ->> 'client_cents', v_prix ->> 'partner_cents';
  end if;

  -- 3. La voiture n'est pas touchee.
  v_prix := secoto_private.price_with_grid('plateau', v_params, 500, v_auto, null);
  if (v_prix ->> 'client_cents')::int <> 60000
     or (v_prix ->> 'partner_cents')::int <> 50000 then
    raise exception 'Voiture 500 km : % / % (attendu 60000 / 50000)',
      v_prix ->> 'client_cents', v_prix ->> 'partner_cents';
  end if;

  raise notice 'OK : plafond client moto 382 EUR, remuneration transporteur inchangee a 300 EUR';
end
$controle$;
