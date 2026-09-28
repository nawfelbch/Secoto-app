-- ============================================================================
-- SECOTO — 059 : COMMANDER PLUSIEURS VEHICULES EN UNE FOIS
-- ----------------------------------------------------------------------------
-- Le client declare jusqu'a 3 vehicules sur un meme trajet. Il obtient UN prix,
-- avec la remise de groupage de la migration 058, et il paie UNE fois.
--
-- Cote exploitation, un vehicule reste UNE mission : chaque vehicule a ses
-- photos, son etat des lieux, son bon de livraison et son versement au
-- transporteur. Les missions d'une meme commande sont reliees par
-- groupage_order_id et attribuees au meme transporteur, en une transaction.
--
-- Le parcours a un seul vehicule n'est pas modifie : sans 'vehicles' dans la
-- charge utile, tout se comporte exactement comme avant.
--
-- Les fonctions deployees sont patchees a partir de leur source reelle, comme
-- l'ont fait les migrations 049 et 050 : toute ancre introuvable fait echouer
-- la migration au lieu de laisser une fonction a moitie modifiee.
-- ============================================================================

-- 1. Colonnes -----------------------------------------------------------------
alter table public.transport_quotes
  add column if not exists vehicles jsonb,
  add column if not exists group_discount_cents integer not null default 0;

comment on column public.transport_quotes.vehicles is
  'Liste complete des vehicules de la commande (1 a 3). La colonne vehicle '
  'garde le premier, pour tout ce qui attend un vehicule unique.';
comment on column public.transport_quotes.group_discount_cents is
  'Part de marge SECOTO rendue au client au titre du groupage, en centimes.';

-- Les devis deja enregistres portent un seul vehicule.
update public.transport_quotes
   set vehicles = jsonb_build_array(vehicle)
 where vehicles is null;

alter table public.missions
  add column if not exists groupage_order_id uuid references public.transport_orders(id),
  add column if not exists groupage_rank integer;

create index if not exists missions_groupage_idx
  on public.missions(groupage_order_id) where groupage_order_id is not null;

comment on column public.missions.groupage_order_id is
  'Commande dont cette mission fait partie quand plusieurs vehicules ont ete '
  'commandes ensemble. Null pour une mission simple.';

-- 2. Devis : accepter une liste de vehicules ----------------------------------
-- Une ancre doit apparaitre EXACTEMENT une fois : zero, et le patch serait
-- silencieusement ignore ; deux, et replace() modifierait un endroit imprevu.
create or replace function secoto_private.compter_occurrences(p_texte text, p_ancre text)
returns integer language sql immutable set search_path = ''
as $f$
  select case when coalesce(p_ancre, '') = '' then 0
         else (length(p_texte) - length(replace(p_texte, p_ancre, ''))) / length(p_ancre) end;
$f$;

do $patch_quote_create$
declare
  v_src  text;
  v_new  text;
  v_bloc text;
begin
  select pg_get_functiondef(p.oid) into v_src
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname = 'secoto_quote_create';

  if v_src is null then
    raise exception 'secoto_quote_create absente : appliquez d''abord la migration 030.';
  end if;

  if position('price_group_with_grid' in v_src) > 0 then
    raise notice 'secoto_quote_create accepte deja plusieurs vehicules : rien a faire';
    return;
  end if;

  v_new := v_src;

  -- 2.a La liste des vehicules est constituee dans les DECLARATIONS.
  --     La version precedente inserait du code juste apres « begin », en
  --     supposant que v_constraint etait la derniere declaration. Ce n'est pas
  --     vrai de la fonction telle qu'elle est deployee : les migrations 049 et
  --     050 l'ont modifiee depuis. On s'appuie desormais sur la seule ligne
  --     dont on est certain, celle qui declare le vehicule, et rien n'est
  --     insere dans le corps.
  if secoto_private.compter_occurrences(v_new, '  v_vehicle jsonb := p_payload -> ''vehicle'';') <> 1 then
    -- Le debut reel de la fonction est joint au message : en cas d'echec, il
    -- dit immediatement a quoi ressemble la version deployee.
    raise exception 'Ancre du vehicule absente ou ambigue dans secoto_quote_create. Debut reel : %',
      left(v_new, 1200);
  end if;
  v_new := replace(v_new,
    '  v_vehicle jsonb := p_payload -> ''vehicle'';',
    '  v_vehicles jsonb := case' || chr(10) ||
    '    when jsonb_typeof(p_payload -> ''vehicles'') = ''array''' || chr(10) ||
    '      then p_payload -> ''vehicles''' || chr(10) ||
    '    else jsonb_build_array(p_payload -> ''vehicle'') end;' || chr(10) ||
    '  v_vehicule_i jsonb;' || chr(10) ||
    '  v_vehicle jsonb := v_vehicles -> 0;');

  -- 2.c Verification des vehicules supplementaires, avant le controle des notes
  --     du premier (qui sert d'ancre).
  if secoto_private.compter_occurrences(v_new, 'if length(coalesce(v_vehicle ->> ''notes'', '''')) > 500 then') <> 1 then
    raise exception 'Ancre de verification des vehicules absente ou ambigue dans secoto_quote_create.';
  end if;
  v_new := replace(v_new,
    'if length(coalesce(v_vehicle ->> ''notes'', '''')) > 500 then',
    '  if jsonb_array_length(v_vehicles) not between 1 and 3 then' || chr(10) ||
    '    raise exception ''Indiquez de 1 a 3 vehicules.'';' || chr(10) ||
    '  end if;' || chr(10) ||
    '  for v_vehicule_i in select value from jsonb_array_elements(v_vehicles) offset 1 loop' || chr(10) ||
    '    if jsonb_typeof(v_vehicule_i) <> ''object''' || chr(10) ||
    '       or length(btrim(coalesce(v_vehicule_i ->> ''model'', ''''))) not between 2 and 120 then' || chr(10) ||
    '      raise exception ''Indiquez le modele de chaque vehicule.'';' || chr(10) ||
    '    end if;' || chr(10) ||
    '    if coalesce(v_vehicule_i ->> ''class'', '''') not in (''voiture'', ''utilitaire'', ''moto'', ''autre'') then' || chr(10) ||
    '      raise exception ''Categorie de vehicule invalide.'';' || chr(10) ||
    '    end if;' || chr(10) ||
    '    if coalesce(v_vehicule_i ->> ''category'', ''standard'') not in (''standard'', ''luxury'') then' || chr(10) ||
    '      raise exception ''Gamme de vehicule invalide.'';' || chr(10) ||
    '    end if;' || chr(10) ||
    '    if jsonb_typeof(v_vehicule_i -> ''rolling'') <> ''boolean'' then' || chr(10) ||
    '      raise exception ''Precisez si chaque vehicule roule.'';' || chr(10) ||
    '    end if;' || chr(10) ||
    '    if v_mode = ''convoyage'' and not (v_vehicule_i ->> ''rolling'')::boolean then' || chr(10) ||
    '      raise exception ''Un vehicule non roulant ne peut pas etre convoye : choisissez le plateau.'';' || chr(10) ||
    '    end if;' || chr(10) ||
    '    if length(coalesce(v_vehicule_i ->> ''notes'', '''')) > 500 then' || chr(10) ||
    '      raise exception ''Precisions trop longues (500 caracteres).'';' || chr(10) ||
    '    end if;' || chr(10) ||
    '  end loop;' || chr(10) ||
    '  if length(coalesce(v_vehicle ->> ''notes'', '''')) > 500 then');

  -- 2.d Tarification groupee.
  if secoto_private.compter_occurrences(v_new, 'v_price := secoto_private.price_with_grid(v_mode, v_grid.params, v_distance, v_vehicle,') <> 1 then
    raise exception 'Ancre de tarification absente ou ambigue dans secoto_quote_create.';
  end if;
  v_new := replace(v_new,
    'v_price := secoto_private.price_with_grid(v_mode, v_grid.params, v_distance, v_vehicle,',
    'v_price := secoto_private.price_group_with_grid(v_mode, v_grid.params, v_distance, v_vehicles,');

  -- 2.e Enregistrement de la liste et de la remise.
  if secoto_private.compter_occurrences(v_new, 'vehicle, schedule, route,') <> 1
     or secoto_private.compter_occurrences(v_new, 'v_pickup, v_delivery, v_vehicle, v_schedule,') <> 1 then
    raise exception 'Ancre d''insertion absente ou ambigue dans secoto_quote_create.';
  end if;
  v_new := replace(v_new,
    'vehicle, schedule, route,',
    'vehicle, vehicles, group_discount_cents, schedule, route,');
  v_new := replace(v_new,
    'v_pickup, v_delivery, v_vehicle, v_schedule,',
    'v_pickup, v_delivery, v_vehicle, v_vehicles, ' ||
    'coalesce((v_price ->> ''remise_groupage_cents'')::int, 0), v_schedule,');

  -- 2.f Detail par vehicule dans le recapitulatif.
  if secoto_private.compter_occurrences(v_new, '''excluded'', v_price -> ''excluded'')') <> 1 then
    raise exception 'Ancre du recapitulatif absente ou ambigue dans secoto_quote_create.';
  end if;
  v_new := replace(v_new,
    '''excluded'', v_price -> ''excluded'')',
    '''excluded'', v_price -> ''excluded'', ' ||
    '''detail'', coalesce(v_price -> ''detail'', ''[]''::jsonb), ' ||
    '''remise_groupage_cents'', coalesce((v_price ->> ''remise_groupage_cents'')::int, 0))');

  execute v_new;
  raise notice 'secoto_quote_create accepte desormais jusqu a 3 vehicules';
end
$patch_quote_create$;

-- 3. Confirmation : une mission par vehicule ----------------------------------
do $patch_od_confirm$
declare
  v_src text;
  v_new text;
begin
  select pg_get_functiondef(p.oid) into v_src
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'secoto_private' and p.proname = 'od_confirm';

  if v_src is null then
    raise exception 'secoto_private.od_confirm absente : appliquez d''abord la migration 030.';
  end if;

  if position('groupage_order_id' in v_src) > 0 then
    raise notice 'od_confirm cree deja une mission par vehicule : rien a faire';
    return;
  end if;

  v_new := v_src;

  if secoto_private.compter_occurrences(v_new, '  v_mission public.missions%rowtype;') <> 1 then
    raise exception 'Ancre des declarations absente ou ambigue dans od_confirm.';
  end if;
  v_new := replace(v_new,
    '  v_mission public.missions%rowtype;',
    '  v_mission public.missions%rowtype;' || chr(10) ||
    '  v_rang integer;' || chr(10) ||
    '  v_veh jsonb;' || chr(10) ||
    '  v_ligne jsonb;');

  if secoto_private.compter_occurrences(v_new, '  returning * into v_mission;') <> 1 then
    raise exception 'Ancre de creation de mission absente ou ambigue dans od_confirm.';
  end if;
  v_new := replace(v_new,
    '  returning * into v_mission;',
    '  returning * into v_mission;' || chr(10) ||
    chr(10) ||
    '  update public.missions' || chr(10) ||
    '     set groupage_order_id = v_order.id, groupage_rank = 0' || chr(10) ||
    '   where id = v_mission.id' || chr(10) ||
    '     and jsonb_typeof(v_quote.vehicles) = ''array''' || chr(10) ||
    '     and jsonb_array_length(v_quote.vehicles) > 1;' || chr(10) ||
    chr(10) ||
    '  if jsonb_typeof(v_quote.vehicles) = ''array''' || chr(10) ||
    '     and jsonb_array_length(v_quote.vehicles) > 1 then' || chr(10) ||
    '    for v_rang in 1 .. jsonb_array_length(v_quote.vehicles) - 1 loop' || chr(10) ||
    '      v_veh := v_quote.vehicles -> v_rang;' || chr(10) ||
    '      v_ligne := coalesce(v_quote.breakdown -> ''detail'' -> v_rang, ''{}''::jsonb);' || chr(10) ||
    '      insert into public.missions(public_ref, type, status, from_city, to_city,' || chr(10) ||
    '        pickup_address, delivery_address, mission_date, vehicle, distance_km,' || chr(10) ||
    '        client_name, client_contact, client_phone, notes, created_by_role,' || chr(10) ||
    '        client_account_id, vehicle_category, manual_pricing, manual_carrier_pay,' || chr(10) ||
    '        manual_margin, payment_status, payment_method, groupage_order_id, groupage_rank)' || chr(10) ||
    '      select secoto_private.new_public_ref(''MIS''), v_order.mode, ''published'',' || chr(10) ||
    '        v_quote.pickup ->> ''city'', v_quote.delivery ->> ''city'',' || chr(10) ||
    '        v_quote.pickup ->> ''label'', v_quote.delivery ->> ''label'',' || chr(10) ||
    '        v_order.pickup_at, left(v_veh ->> ''model'', 120),' || chr(10) ||
    '        (v_quote.route ->> ''distance_km'')::numeric,' || chr(10) ||
    '        coalesce(a.company_name, a.full_name), a.email, a.phone,' || chr(10) ||
    '        left(concat_ws('' - '', ''Commande '' || v_order.public_ref,' || chr(10) ||
    '          ''Vehicule '' || (v_rang + 1) || '' sur '' || jsonb_array_length(v_quote.vehicles),' || chr(10) ||
    '          ''Creneau '' || (v_quote.schedule ->> ''slot''),' || chr(10) ||
    '          case when not coalesce((v_veh ->> ''rolling'')::boolean, true) then ''NON ROULANT'' end,' || chr(10) ||
    '          nullif(v_veh ->> ''notes'', '''')), 2000),' || chr(10) ||
    '        ''client'', v_order.account_id, coalesce(v_veh ->> ''category'', ''standard''), true,' || chr(10) ||
    '        coalesce((v_ligne ->> ''partner_cents'')::int, 0) / 100.0,' || chr(10) ||
    '        (coalesce((v_ligne ->> ''client_cents'')::int, 0)' || chr(10) ||
    '          - coalesce((v_ligne ->> ''partner_cents'')::int, 0)) / 100.0,' || chr(10) ||
    '        case when v_order.funding = ''subscription'' then ''not_required''' || chr(10) ||
    '             when (select p.status from public.payments p where p.id = v_order.payment_id) = ''paid''' || chr(10) ||
    '               then ''paid'' else ''awaiting_payment'' end,' || chr(10) ||
    '        case when v_order.funding = ''subscription'' then ''abonnement'' else ''carte'' end,' || chr(10) ||
    '        v_order.id, v_rang' || chr(10) ||
    '      from public.accounts a where a.id = v_order.account_id;' || chr(10) ||
    '    end loop;' || chr(10) ||
    chr(10) ||
    '    update public.missions' || chr(10) ||
    '       set status = ''assigned'', progress_status = ''assigned_pending'',' || chr(10) ||
    '           assigned_transporter_id = v_partner.id,' || chr(10) ||
    '           assigned_transporter_name = coalesce(v_partner.company_name, v_partner.full_name)' || chr(10) ||
    '     where groupage_order_id = v_order.id and groupage_rank > 0;' || chr(10) ||
    chr(10) ||
    '    update public.missions' || chr(10) ||
    '       set manual_carrier_pay = (v_order.partner_pay_cents - coalesce((' || chr(10) ||
    '             select sum(round(s.manual_carrier_pay * 100))::int from public.missions s' || chr(10) ||
    '              where s.groupage_order_id = v_order.id and s.groupage_rank > 0), 0)) / 100.0,' || chr(10) ||
    '           manual_margin = (v_order.client_price_cents - v_order.partner_pay_cents' || chr(10) ||
    '             - coalesce((select sum(round(s.manual_margin * 100))::int from public.missions s' || chr(10) ||
    '                 where s.groupage_order_id = v_order.id and s.groupage_rank > 0), 0)) / 100.0' || chr(10) ||
    '     where id = v_mission.id;' || chr(10) ||
    '  end if;');

  execute v_new;
  raise notice 'od_confirm cree desormais une mission par vehicule';
end
$patch_od_confirm$;

-- 3 bis. Le devis renvoye au client porte la liste et l'economie --------------
create or replace function secoto_private.quote_client_json(q public.transport_quotes)
returns jsonb language sql stable set search_path = ''
as $f$
  select jsonb_build_object(
    'id', q.id, 'mode', q.mode, 'status',
      case when q.status in ('priced', 'manual_priced') and q.valid_until <= now() then 'expired' else q.status end,
    'pickup', q.pickup, 'delivery', q.delivery, 'vehicle', q.vehicle, 'schedule', q.schedule,
    'vehicles', coalesce(q.vehicles, jsonb_build_array(q.vehicle)),
    'group_discount_cents', coalesce(q.group_discount_cents, 0),
    'distance_km', q.route -> 'distance_km', 'duration_min', q.route -> 'duration_min',
    'client_price_cents', q.client_price_cents,
    'collect_cents', q.collect_cents,
    'transport_direct_cents', q.transport_direct_cents,
    'lines', coalesce(q.breakdown -> 'lines', '[]'::jsonb),
    'included', coalesce(q.breakdown -> 'included', '[]'::jsonb),
    'excluded', coalesce(q.breakdown -> 'excluded', '[]'::jsonb),
    'grid_version', q.grid_version,
    'manual_reason', q.manual_reason,
    'valid_until', q.valid_until, 'pickup_at', q.pickup_at,
    'business_id', q.business_id, 'created_at', q.created_at);
$f$;

drop function if exists secoto_private.compter_occurrences(text, text);

-- 4. Controles bloquants ------------------------------------------------------
do $controles$
declare
  v_src text;
begin
  if not exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'transport_quotes' and column_name = 'vehicles')
  then
    raise exception 'La colonne transport_quotes.vehicles n''a pas ete creee';
  end if;

  if exists (select 1 from public.transport_quotes where vehicles is null) then
    raise exception 'Des devis existants n''ont pas ete repris avec leur vehicule';
  end if;

  if not exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'missions' and column_name = 'groupage_order_id')
  then
    raise exception 'La colonne missions.groupage_order_id n''a pas ete creee';
  end if;

  select pg_get_functiondef(p.oid) into v_src
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname = 'secoto_quote_create';
  if position('price_group_with_grid' in v_src) = 0 then
    raise exception 'secoto_quote_create ne tarife pas la liste de vehicules';
  end if;
  if position('v_vehicle jsonb := v_vehicles -> 0;' in v_src) = 0 then
    raise exception 'secoto_quote_create ne constitue pas la liste de vehicules';
  end if;

  select pg_get_functiondef(p.oid) into v_src
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'secoto_private' and p.proname = 'od_confirm';
  if position('groupage_order_id = v_order.id and groupage_rank > 0' in v_src) = 0 then
    raise exception 'od_confirm n''attribue pas les missions soeurs';
  end if;
  if position('set manual_carrier_pay = (v_order.partner_pay_cents - coalesce((' in v_src) = 0 then
    raise exception 'od_confirm ne partage pas la remuneration entre les missions d''une meme commande';
  end if;

  select pg_get_functiondef(p.oid) into v_src
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'secoto_private' and p.proname = 'quote_client_json';
  if position('group_discount_cents' in v_src) = 0 then
    raise exception 'Le devis renvoye au client ne porte pas l''economie de groupage';
  end if;

  raise notice 'OK : commande multi-vehicules en place (devis groupe, une mission par vehicule)';
end
$controles$;
