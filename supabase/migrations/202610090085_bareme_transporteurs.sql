-- ============================================================================
-- SECOTO 085 — Chaque transporteur fixe son prix (barème transporteur)
-- ----------------------------------------------------------------------------
-- Derrière l'interrupteur « bareme_transporteurs » (éteint par défaut).
--
-- 1. Chaque transporteur plateau (indépendant ou gérant) reçoit le barème de
--    départ SECOTO, déjà rempli. Il le valide d'un clic ou le modifie, à tout
--    moment. Chaque validation est conservée (preuve que le prix est le sien).
-- 2. Prix client d'un transport plateau (1 véhicule) : il part des prix des
--    transporteurs disponibles pour ce trajet, auxquels s'ajoute la commission
--    SECOTO (+20 % voiture et moto, utilitaire inchangé 1,25 / 1,10). Le prix
--    retenu est celui qui permet à plusieurs transporteurs (3 par défaut) de
--    prendre la course : jamais un seul.
-- 3. Diffusion : tous les transporteurs dont le prix est au plus 5 % au-dessus
--    de la rémunération proposée reçoivent la mission EN MÊME TEMPS. Le premier
--    qui accepte est attribué, sans nouvelle question au client.
--
-- La moto garde son plafond client de 382 € (rémunération ~318 € au plafond).
-- Les commandes de plusieurs véhicules et le convoyage gardent le barème SECOTO.
-- Migration additive et rejouable. Interrupteur éteint : rien ne change.
-- ============================================================================

-- 1. RÉGLAGES ------------------------------------------------------------------
insert into public.app_settings(key, value) values ('bareme_transporteurs', jsonb_build_object(
  'classes', jsonb_build_array('voiture', 'moto', 'utilitaire'),
  -- Prix client = prix du transporteur × coefficient (commission SECOTO comprise).
  'client_factor', jsonb_build_object('voiture', 1.20, 'moto', 1.20, 'utilitaire', round(1.25 / 1.10, 6)),
  -- Barème de départ proposé aux transporteurs (= rémunérations SECOTO actuelles).
  'defaults', jsonb_build_object(
    'voiture',    jsonb_build_object('eur_per_km', 1.00, 'minimum_eur', 95.83, 'non_rolling_eur', 66.67),
    'moto',       jsonb_build_object('eur_per_km', 0.85, 'minimum_eur', 95.83, 'non_rolling_eur', 66.67),
    'utilitaire', jsonb_build_object('eur_per_km', 1.10, 'minimum_eur', 101.20, 'non_rolling_eur', 70.40)),
  -- Plafond client (moto : 382 €) ; la part distance du transporteur suit.
  'client_cap_eur', jsonb_build_object('moto', 382),
  'tolerance_pct', 5,
  'min_carriers', 3,
  'limits', jsonb_build_object('eur_per_km_min', 0.30, 'eur_per_km_max', 4.00, 'minimum_eur_max', 600, 'non_rolling_eur_max', 400)))
on conflict (key) do nothing;

create or replace function secoto_private.bareme_transporteurs()
returns jsonb language sql stable security definer set search_path = '' as $$
  select coalesce((select value from public.app_settings where key = 'bareme_transporteurs'), '{}'::jsonb);
$$;

-- 2. BARÈMES DÉCLARÉS ------------------------------------------------------------
create table if not exists public.carrier_rates (
  account_id uuid not null references public.accounts(id) on delete cascade,
  vehicle_class text not null check (vehicle_class in ('voiture', 'moto', 'utilitaire')),
  eur_per_km numeric(6,2) not null check (eur_per_km > 0 and eur_per_km <= 10),
  minimum_eur numeric(8,2) not null check (minimum_eur >= 0 and minimum_eur <= 2000),
  non_rolling_eur numeric(8,2) not null check (non_rolling_eur >= 0 and non_rolling_eur <= 2000),
  updated_at timestamptz not null default now(),
  primary key (account_id, vehicle_class)
);

-- Preuve : chaque validation du barème (de départ ou modifié) est conservée.
create table if not exists public.carrier_rates_confirmations (
  id uuid primary key default gen_random_uuid(),
  account_id uuid not null references public.accounts(id) on delete cascade,
  rates jsonb not null,
  source text not null check (source in ('defaut', 'modifie')),
  platform text,
  confirmed_at timestamptz not null default now()
);
create index if not exists carrier_rates_confirmations_account_idx on public.carrier_rates_confirmations(account_id, confirmed_at desc);

alter table public.carrier_rates enable row level security;
alter table public.carrier_rates_confirmations enable row level security;
revoke all on public.carrier_rates from public, anon, authenticated;
revoke all on public.carrier_rates_confirmations from public, anon, authenticated;
grant select on public.carrier_rates to authenticated;
grant select on public.carrier_rates_confirmations to authenticated;
drop policy if exists carrier_rates_read on public.carrier_rates;
create policy carrier_rates_read on public.carrier_rates for select to authenticated
  using (account_id = auth.uid() or secoto_private.current_is_admin());
drop policy if exists carrier_rates_confirmations_read on public.carrier_rates_confirmations;
create policy carrier_rates_confirmations_read on public.carrier_rates_confirmations for select to authenticated
  using (account_id = auth.uid() or secoto_private.current_is_admin());

-- Qui fixe le prix : le transporteur indépendant, ou le gérant pour ses chauffeurs.
create or replace function secoto_private.carrier_rate_owner(p_account uuid)
returns uuid language sql stable security definer set search_path = '' as $$
  select coalesce(
    (select bm.account_id from public.business_members bm
      where bm.business_id = secoto_private.carrier_of(p_account) and bm.role = 'owner'
        and not secoto_private.is_carrier_owner(secoto_private.carrier_of(p_account), p_account)
      order by bm.created_at limit 1),
    p_account);
$$;

-- Barème effectif d'un transporteur pour une catégorie (déclaré, sinon départ).
create or replace function secoto_private.carrier_rate(p_account uuid, p_class text)
returns jsonb language sql stable security definer set search_path = '' as $$
  select coalesce(
    (select jsonb_build_object('eur_per_km', r.eur_per_km, 'minimum_eur', r.minimum_eur, 'non_rolling_eur', r.non_rolling_eur, 'declared', true)
       from public.carrier_rates r
      where r.account_id = secoto_private.carrier_rate_owner(p_account) and r.vehicle_class = p_class),
    (secoto_private.bareme_transporteurs() -> 'defaults' -> p_class) || jsonb_build_object('declared', false));
$$;

-- Prix d'un transporteur pour un trajet, en centimes.
create or replace function secoto_private.carrier_trip_price_cents(p_account uuid, p_class text, p_km numeric, p_rolling boolean)
returns integer language plpgsql stable security definer set search_path = '' as $$
declare
  v_rate jsonb := secoto_private.carrier_rate(p_account, p_class);
  v_b jsonb := secoto_private.bareme_transporteurs();
  v_base numeric;
  v_cap numeric;
begin
  if v_rate is null or (v_rate ->> 'eur_per_km') is null or coalesce(p_km, 0) <= 0 then return null; end if;
  v_base := greatest(round(p_km, 1) * (v_rate ->> 'eur_per_km')::numeric, coalesce((v_rate ->> 'minimum_eur')::numeric, 0));
  -- Plafond client (moto) : la part distance du transporteur s'arrête au même point.
  v_cap := (v_b -> 'client_cap_eur' ->> p_class)::numeric;
  if v_cap is not null then
    v_base := least(v_base, round(v_cap / (v_b -> 'client_factor' ->> p_class)::numeric, 2));
  end if;
  if not coalesce(p_rolling, true) then
    v_base := v_base + coalesce((v_rate ->> 'non_rolling_eur')::numeric, 0);
  end if;
  return round(v_base * 100)::integer;
end;
$$;

create or replace function secoto_private.client_from_carrier_cents(p_class text, p_carrier_cents integer)
returns integer language sql stable security definer set search_path = '' as $$
  select round(p_carrier_cents * coalesce((secoto_private.bareme_transporteurs() -> 'client_factor' ->> p_class)::numeric, 1.20))::integer;
$$;

-- Transporteur susceptible de prendre ce trajet (mêmes règles que la diffusion).
create or replace function secoto_private.carrier_eligible_for_trip(p_partner uuid, p_vehicle jsonb, p_pickup jsonb, p_pickup_at timestamptz)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (
    select 1
    from public.accounts a
    left join public.partner_dispatch_preferences pr on pr.account_id = a.id
    where a.id = p_partner
      and a.role::text = 'transporter' and a.status::text = 'active'
      and coalesce(a.is_verified, false) and a.deleted_at is null
      and coalesce(pr.available, true)
      and secoto_private.partner_documents_valid(a.id)
      and a.transporter_type::text in ('vl', 'pl')
      and coalesce(p_vehicle ->> 'category', 'standard') = 'standard' and coalesce(a.receives_standard_plateau, true)
      and (pr.account_id is null or cardinality(pr.zones) = 0 or secoto_private.department_of(p_pickup ->> 'postcode') = any(pr.zones))
      and (pr.account_id is null or cardinality(pr.vehicle_classes) = 0 or (p_vehicle ->> 'class') = any(pr.vehicle_classes))
      and (pr.account_id is null or cardinality(pr.weekdays) = 0 or extract(isodow from (p_pickup_at at time zone 'Europe/Paris'))::smallint = any(pr.weekdays))
      and (not secoto_private.flag('plateau_paiement_direct') or secoto_private.partner_direct_ready(a.id))
  );
$$;

-- Prix « marché » d'un trajet plateau d'un véhicule : on part du prix calculé
-- par le barème SECOTO (p_price) et on le remplace par celui des transporteurs.
create or replace function secoto_private.market_price(p_price jsonb, p_vehicle jsonb, p_pickup jsonb, p_km numeric, p_pickup_at timestamptz)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_b jsonb := secoto_private.bareme_transporteurs();
  v_class text := p_vehicle ->> 'class';
  v_rolling boolean := coalesce((p_vehicle ->> 'rolling')::boolean, true);
  v_prices integer[];
  v_n integer;
  v_k integer;
  v_pay integer;
  v_client integer;
  v_source text;
begin
  if p_price ? 'manual_reason' or v_class is null or not (v_b -> 'client_factor' ? v_class) then
    return p_price;
  end if;

  -- Un prix par transporteur (une entreprise et ses chauffeurs comptent pour un).
  select array_agg(x.c order by x.c) into v_prices from (
    select min(secoto_private.carrier_trip_price_cents(a.id, v_class, p_km, v_rolling)) as c
      from public.accounts a
     where a.role::text = 'transporter' and a.deleted_at is null
       and secoto_private.carrier_eligible_for_trip(a.id, p_vehicle, p_pickup, p_pickup_at)
     group by secoto_private.carrier_rate_owner(a.id)) x
   where x.c is not null;
  v_n := coalesce(array_length(v_prices, 1), 0);

  if v_n = 0 then
    -- Aucun transporteur encore inscrit sur ce trajet : barème de départ.
    v_pay := secoto_private.carrier_trip_price_cents(null, v_class, p_km, v_rolling);
    v_source := 'bareme_depart';
  else
    -- Le prix qui permet à plusieurs transporteurs de prendre la course.
    v_k := greatest(coalesce((v_b ->> 'min_carriers')::int, 3), 1);
    if v_n >= v_k then
      v_pay := v_prices[v_k];
    else
      -- Trop peu de transporteurs : aucun ne peut à lui seul faire monter le
      -- prix au-dessus du barème de départ.
      v_pay := least(v_prices[v_n], secoto_private.carrier_trip_price_cents(null, v_class, p_km, v_rolling));
    end if;
    v_source := 'prix_transporteurs';
  end if;
  if v_pay is null then return p_price; end if;
  v_client := secoto_private.client_from_carrier_cents(v_class, v_pay);

  return p_price || jsonb_build_object(
    'client_cents', v_client,
    'partner_cents', v_pay,
    'margin_cents', v_client - v_pay,
    'collect_cents', v_client,
    'capped', (v_b -> 'client_cap_eur' ->> v_class) is not null and v_client >= ((v_b -> 'client_cap_eur' ->> v_class)::numeric * 100)::int,
    'lines', jsonb_build_array(jsonb_build_object(
      'label', format('Transport sur plateau · %s km', replace(trim(trailing '.' from trim(trailing '0' from to_char(round(p_km, 1), 'FM999990.0'))), '.', ',')),
      'eur', round(v_client / 100.0, 2))),
    'detail', jsonb_build_array(jsonb_build_object(
      'pricing', 'bareme_transporteurs', 'source', v_source, 'carriers', v_n, 'partner_cents', v_pay)));
end;
$$;

-- 3. PRIX CLIENT (devis plateau d'un véhicule) ---------------------------------
select secoto_private.mig074_patch(
  'public.secoto_quote_create(uuid, jsonb, jsonb)'::regprocedure,
  '    v_reason := v_price ->> ''manual_reason'';',
  '    v_reason := v_price ->> ''manual_reason'';
    -- 085 : le prix part des barèmes déclarés par les transporteurs.
    if v_reason is null and v_mode = ''plateau'' and jsonb_array_length(v_vehicles) = 1
       and secoto_private.flag(''bareme_transporteurs'') then
      v_price := secoto_private.market_price(v_price, v_vehicle, v_pickup, v_distance, v_pickup_at);
    end if;');

-- 4. DIFFUSION SIMULTANÉE À 5 % PRÈS ---------------------------------------------
create or replace function secoto_private.carrier_accepts_pay(p_partner uuid, p_order uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select case
    when not secoto_private.flag('bareme_transporteurs') then true
    else coalesce((
      -- Seules les commandes dont le prix vient des barèmes transporteurs sont
      -- filtrées : un prix fixé par SECOTO (devis manuel, ancien barème) part à tous.
      select o.mode <> 'plateau'
          or coalesce(q.breakdown -> 'detail' -> 0 ->> 'pricing', '') <> 'bareme_transporteurs'
          or jsonb_array_length(coalesce(q.vehicles, '[]'::jsonb)) > 1
          or coalesce(q.vehicle ->> 'category', 'standard') <> 'standard'
          or secoto_private.carrier_trip_price_cents(p_partner, q.vehicle ->> 'class',
               (q.route ->> 'distance_km')::numeric, coalesce((q.vehicle ->> 'rolling')::boolean, true))
             <= o.partner_pay_cents * (1 + coalesce((secoto_private.bareme_transporteurs() ->> 'tolerance_pct')::numeric, 5) / 100)
             is not false
        from public.transport_orders o join public.transport_quotes q on q.id = o.quote_id
       where o.id = p_order), true)
  end;
$$;

select secoto_private.mig074_patch(
  'secoto_private.od_broadcast(uuid)'::regprocedure,
  '  perform secoto_private.audit(''order_broadcast'', ''transport_order'', p_order_id::text,',
  '  -- 085 : personne au prix (barèmes modifiés depuis le devis) : SECOTO est prévenu.
  if v_count = 0 and secoto_private.flag(''bareme_transporteurs'') then
    perform secoto_private.notify_admins_event(''new_request'', ''Aucun transporteur à ce prix'',
      format(''%s · %s → %s : aucun transporteur dont le barème correspond. Rediffusez ou contactez le client.'',
        v_order.public_ref, v_quote.pickup ->> ''city'', v_quote.delivery ->> ''city''),
      ''requests'', ''order-no-carrier-price:'' || v_order.id::text || '':'' || v_order.dispatch_round, v_order.id);
  end if;
  perform secoto_private.audit(''order_broadcast'', ''transport_order'', p_order_id::text,');

select secoto_private.mig074_patch(
  'secoto_private.od_broadcast(uuid)'::regprocedure,
  '  for r in select a.id from public.accounts a where secoto_private.od_partner_eligible(a.id, p_order_id) loop',
  '  for r in select a.id from public.accounts a where secoto_private.od_partner_eligible(a.id, p_order_id)
                and secoto_private.carrier_accepts_pay(a.id, p_order_id) loop');

-- 5. TRANSPORTEUR : état, validation, modification -------------------------------
create or replace function secoto_private.carrier_sets_rates(p_account uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.accounts a
                  where a.id = p_account and a.role::text = 'transporter' and a.deleted_at is null
                    and a.transporter_type::text in ('vl', 'pl'))
     and secoto_private.carrier_rate_owner(p_account) = p_account;
$$;

create or replace function public.secoto_carrier_rates_status()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  v_b jsonb := secoto_private.bareme_transporteurs();
  v_rates jsonb := '{}'::jsonb;
  v_class text;
  v_confirmed timestamptz;
begin
  if v_uid is null or not secoto_private.carrier_sets_rates(v_uid) then
    return jsonb_build_object('active', secoto_private.flag('bareme_transporteurs'), 'concerned', false, 'required', false);
  end if;
  for v_class in select jsonb_array_elements_text(v_b -> 'classes') loop
    v_rates := v_rates || jsonb_build_object(v_class, secoto_private.carrier_rate(v_uid, v_class));
  end loop;
  select max(c.confirmed_at) into v_confirmed from public.carrier_rates_confirmations c where c.account_id = v_uid;
  return jsonb_build_object(
    'active', secoto_private.flag('bareme_transporteurs'),
    'concerned', true,
    'required', secoto_private.flag('bareme_transporteurs') and v_confirmed is null,
    'confirmed_at', v_confirmed,
    'rates', v_rates,
    'defaults', v_b -> 'defaults',
    'limits', v_b -> 'limits',
    'tolerance_pct', v_b -> 'tolerance_pct');
end;
$$;

create or replace function public.secoto_carrier_rates_save(p_rates jsonb, p_platform text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  v_b jsonb := secoto_private.bareme_transporteurs();
  v_lim jsonb := v_b -> 'limits';
  v_class text;
  v_row jsonb;
  v_km numeric; v_min numeric; v_nr numeric;
  v_saved jsonb := '{}'::jsonb;
  v_modified boolean := false;
begin
  if v_uid is null then raise exception 'Session expirée. Reconnectez-vous.'; end if;
  if not secoto_private.carrier_sets_rates(v_uid) then
    raise exception 'Seul le transporteur (ou le gérant de l''entreprise) fixe le barème.';
  end if;
  if jsonb_typeof(p_rates) <> 'object' then raise exception 'Barème invalide.'; end if;

  for v_class in select jsonb_array_elements_text(v_b -> 'classes') loop
    v_row := p_rates -> v_class;
    if v_row is null then v_row := secoto_private.carrier_rate(v_uid, v_class); end if;
    v_km := round((v_row ->> 'eur_per_km')::numeric, 2);
    v_min := round((v_row ->> 'minimum_eur')::numeric, 2);
    v_nr := round((v_row ->> 'non_rolling_eur')::numeric, 2);
    if v_min is null or v_nr is null then
      raise exception 'Barème incomplet (%) : renseignez le minimum et le supplément non roulant.', v_class;
    end if;
    if v_km is null or v_km < (v_lim ->> 'eur_per_km_min')::numeric or v_km > (v_lim ->> 'eur_per_km_max')::numeric then
      raise exception 'Prix au km (%) : entre % et % €.', v_class, v_lim ->> 'eur_per_km_min', v_lim ->> 'eur_per_km_max';
    end if;
    if v_min < 0 or v_min > (v_lim ->> 'minimum_eur_max')::numeric then
      raise exception 'Minimum par course (%) : entre 0 et % €.', v_class, v_lim ->> 'minimum_eur_max';
    end if;
    if v_nr < 0 or v_nr > (v_lim ->> 'non_rolling_eur_max')::numeric then
      raise exception 'Supplément non roulant (%) : entre 0 et % €.', v_class, v_lim ->> 'non_rolling_eur_max';
    end if;
    insert into public.carrier_rates(account_id, vehicle_class, eur_per_km, minimum_eur, non_rolling_eur, updated_at)
    values (v_uid, v_class, v_km, v_min, v_nr, now())
    on conflict (account_id, vehicle_class) do update
      set eur_per_km = excluded.eur_per_km, minimum_eur = excluded.minimum_eur,
          non_rolling_eur = excluded.non_rolling_eur, updated_at = now();
    v_saved := v_saved || jsonb_build_object(v_class, jsonb_build_object('eur_per_km', v_km, 'minimum_eur', v_min, 'non_rolling_eur', v_nr));
    if v_km <> (v_b -> 'defaults' -> v_class ->> 'eur_per_km')::numeric
       or v_min <> (v_b -> 'defaults' -> v_class ->> 'minimum_eur')::numeric
       or v_nr <> (v_b -> 'defaults' -> v_class ->> 'non_rolling_eur')::numeric then
      v_modified := true;
    end if;
  end loop;

  insert into public.carrier_rates_confirmations(account_id, rates, source, platform)
  values (v_uid, v_saved, case when v_modified then 'modifie' else 'defaut' end, left(p_platform, 20));
  perform secoto_private.audit('carrier_rates_saved', 'account', v_uid::text,
    jsonb_build_object('source', case when v_modified then 'modifie' else 'defaut' end));
  return public.secoto_carrier_rates_status();
end;
$$;

create or replace function public.secoto_admin_carrier_rates()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  perform secoto_private.assert_admin();
  return (select coalesce(jsonb_agg(jsonb_build_object(
      'account_id', a.id, 'name', coalesce(nullif(a.company_name, ''), a.full_name),
      'confirmed_at', (select max(c.confirmed_at) from public.carrier_rates_confirmations c where c.account_id = a.id),
      'voiture', secoto_private.carrier_rate(a.id, 'voiture'),
      'moto', secoto_private.carrier_rate(a.id, 'moto'),
      'utilitaire', secoto_private.carrier_rate(a.id, 'utilitaire')) order by a.full_name), '[]'::jsonb)
    from public.accounts a where secoto_private.carrier_sets_rates(a.id));
end;
$$;

revoke all on function secoto_private.bareme_transporteurs() from public, anon, authenticated;
revoke all on function secoto_private.carrier_rate_owner(uuid) from public, anon, authenticated;
revoke all on function secoto_private.carrier_rate(uuid, text) from public, anon, authenticated;
revoke all on function secoto_private.carrier_trip_price_cents(uuid, text, numeric, boolean) from public, anon, authenticated;
revoke all on function secoto_private.client_from_carrier_cents(text, integer) from public, anon, authenticated;
revoke all on function secoto_private.carrier_eligible_for_trip(uuid, jsonb, jsonb, timestamptz) from public, anon, authenticated;
revoke all on function secoto_private.market_price(jsonb, jsonb, jsonb, numeric, timestamptz) from public, anon, authenticated;
revoke all on function secoto_private.carrier_accepts_pay(uuid, uuid) from public, anon, authenticated;
revoke all on function secoto_private.carrier_sets_rates(uuid) from public, anon, authenticated;
revoke all on function public.secoto_carrier_rates_status() from public, anon;
revoke all on function public.secoto_carrier_rates_save(jsonb, text) from public, anon;
revoke all on function public.secoto_admin_carrier_rates() from public, anon;
grant execute on function public.secoto_carrier_rates_status() to authenticated;
grant execute on function public.secoto_carrier_rates_save(jsonb, text) to authenticated;
grant execute on function public.secoto_admin_carrier_rates() to authenticated;

-- 6. TEXTE DE LA PROPOSITION : délai de virement exact en paiement direct --------
-- (en paiement direct, le virement part 4 h après la livraison validée).
do $patch$
declare v_src text; v_new text;
begin
  v_src := pg_get_functiondef('secoto_private.offer_partner_json(public.transport_offers)'::regprocedure);
  if position('4 h après la livraison validée' in v_src) > 0 then return; end if;
  v_new := regexp_replace(v_src,
    $re$'Péages et carburant inclus dans votre rémunération',(\s*)'Paiement déclenché sous 48 h après la livraison'\) end,$re$,
    $rep$'Péages et carburant inclus dans votre rémunération',\1case when o.payment_circuit = 'direct' then 'Virement sur votre compte bancaire 4 h après la livraison validée' else 'Paiement déclenché sous 48 h après la livraison' end) end,$rep$);
  if v_new = v_src then
    raise notice '085 : texte de proposition non trouvé, laissé tel quel.';
    return;
  end if;
  execute v_new;
end
$patch$;

notify pgrst, 'reload schema';
