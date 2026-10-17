-- ============================================================================
-- SECOTO 099 — Trois offres (Express / Standard / Éco), débit à la confirmation
-- ----------------------------------------------------------------------------
-- Derrière l'interrupteur « trois_offres » (ÉTEINT par défaut) : éteint, rien
-- ne change (une seule offre, encaissement immédiat comme aujourd'hui).
--
-- Allumé, pour un transport sur plateau d'UN véhicule :
--  · le devis porte jusqu'à trois offres, chacune avec sa fenêtre de prise en
--    charge et le nombre RÉEL de transporteurs vérifiés qui la couvrent ;
--      - Standard : prix actuel (barèmes transporteurs 085), fenêtre 5 jours ;
--      - Express  : Standard × 1,25 pour le client ET le transporteur, 48 h ;
--      - Éco      : porte-voitures PL, voitures roulantes uniquement, barème
--                   fixe par véhicule fixé par SECOTO (300 / 500 / 800 € selon
--                   la distance, marge 30 / 30 / 20 %), 15 jours ; affichée
--                   seulement si elle est moins chère que Standard ;
--    une offre n'est proposée que si au moins 3 transporteurs la couvrent ;
--  · à la réservation, la carte est seulement ENREGISTRÉE (aucun débit) ;
--    le débit a lieu sur le compte SECOTO au moment où un transporteur
--    confirme (circuit SECOTO habituel ensuite : versement après livraison) ;
--  · fenêtre écoulée sans confirmation : annulation automatique, aucun débit,
--    et le client peut relancer en un clic (Express ou nouvelle fenêtre).
--
-- Tous les coefficients, fenêtres, tranches et seuils sont dans
-- app_settings['trois_offres'], modifiables depuis l'admin sans redéploiement.
--
-- Migration ADDITIVE et rejouable : nouvelles colonnes nullables (ou booléen
-- par défaut faux), nouvelles fonctions, interrupteur ajouté à la liste
-- autorisée. Les fonctions existantes ne reçoivent que des ajouts ciblés
-- (secoto_private.mig074_patch), sans effet tant que l'interrupteur est éteint
-- ou que la commande n'a pas d'offre. Aucune policy RLS modifiée. Le
-- paiement direct (074) et l'encaissement immédiat restent intacts.
-- ============================================================================

-- 1. INTERRUPTEUR ET RÉGLAGES --------------------------------------------------
alter table public.secoto_feature_flags drop constraint if exists secoto_feature_flags_key_check;
alter table public.secoto_feature_flags add constraint secoto_feature_flags_key_check
  check (key in ('auto_pricing', 'od_payments', 'subscriptions', 'dispatch_notifications', 'live_tracking',
                 'direct_accept', 'connect_payouts', 'plateau_paiement_direct',
                 'conditions_v2', 'commission_client',
                 'mise_en_relation_v2', 'bareme_transporteurs',
                 'adresses_internationales',
                 'trois_offres'));
insert into public.secoto_feature_flags(key, enabled) values ('trois_offres', false)
on conflict (key) do nothing;

insert into public.app_settings(key, value) values ('trois_offres', jsonb_build_object(
  'seuil_transporteurs', 3,
  'standard', jsonb_build_object('fenetre_h', 120),
  'express', jsonb_build_object('coef', 1.25, 'fenetre_h', 48),
  'eco', jsonb_build_object(
    'fenetre_h', 360,
    'classes', jsonb_build_array('voiture'),
    'tranches', jsonb_build_array(
      jsonb_build_object('max_km', 500, 'transporteur_eur', 300, 'marge_pct', 30),
      jsonb_build_object('max_km', 1000, 'transporteur_eur', 500, 'marge_pct', 30),
      jsonb_build_object('max_km', null, 'transporteur_eur', 800, 'marge_pct', 20))),
  -- Validation bancaire (3D Secure) au moment du débit : délai laissé au client.
  'attente_validation_min', 1440))
on conflict (key) do nothing;

create or replace function secoto_private.trois_offres_reglages()
returns jsonb language sql stable security definer set search_path = '' as $$
  select coalesce((select value from public.app_settings where key = 'trois_offres'), '{}'::jsonb);
$$;
revoke all on function secoto_private.trois_offres_reglages() from public, anon, authenticated;

-- 2. COLONNES (toutes additives) -------------------------------------------------
alter table public.transport_quotes add column if not exists offres jsonb;
alter table public.transport_quotes add column if not exists prix_standard jsonb;
alter table public.transport_quotes add column if not exists offre_choisie text;
alter table public.transport_orders add column if not exists offre text;
alter table public.transport_orders add column if not exists fenetre_fin timestamptz;
alter table public.payments add column if not exists debit_a_confirmation boolean not null default false;
alter table public.partner_dispatch_preferences add column if not exists accepte_delai_long boolean not null default false;

do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'transport_quotes_offre_choisie_check') then
    alter table public.transport_quotes add constraint transport_quotes_offre_choisie_check
      check (offre_choisie is null or offre_choisie in ('express', 'standard', 'eco'));
  end if;
  if not exists (select 1 from pg_constraint where conname = 'transport_orders_offre_check') then
    alter table public.transport_orders add constraint transport_orders_offre_check
      check (offre is null or offre in ('express', 'standard', 'eco'));
  end if;
end $$;

create index if not exists transport_orders_offre_idx on public.transport_orders(offre, created_at) where offre is not null;

-- 3. CALCUL DES OFFRES ---------------------------------------------------------------
-- Le transporteur reçoit-il ce type d'offre ? (Éco : porte-voitures PL qui ont
-- coché « missions à délai long / groupage ».)
create or replace function secoto_private.offre_partenaire_ok(p_partner uuid, p_offre text)
returns boolean language sql stable security definer set search_path = '' as $$
  select case when coalesce(p_offre, '') <> 'eco' then true
    else exists (select 1 from public.accounts a
                  left join public.partner_dispatch_preferences pr on pr.account_id = a.id
                  where a.id = p_partner and a.transporter_type::text = 'pl'
                    and coalesce(pr.accepte_delai_long, false)) end;
$$;
revoke all on function secoto_private.offre_partenaire_ok(uuid, text) from public, anon, authenticated;

create or replace function secoto_private.offre_eco_tranche(p_km numeric)
returns jsonb language sql stable security definer set search_path = '' as $$
  select t from jsonb_array_elements(coalesce(secoto_private.trois_offres_reglages() -> 'eco' -> 'tranches', '[]'::jsonb)) with ordinality e(t, i)
   where (t ->> 'max_km') is null or p_km <= (t ->> 'max_km')::numeric
   order by i limit 1;
$$;
revoke all on function secoto_private.offre_eco_tranche(numeric) from public, anon, authenticated;

-- Offres d'un devis plateau. Tout est calculé depuis la base : prix du devis
-- (barèmes réels), transporteurs vérifiés réellement éligibles. NULL = pas
-- d'offres (parcours actuel inchangé).
create or replace function secoto_private.calculer_offres(q public.transport_quotes)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  r jsonb := secoto_private.trois_offres_reglages();
  v_seuil integer := greatest(coalesce((r ->> 'seuil_transporteurs')::int, 3), 1);
  v_km numeric := (q.route ->> 'distance_km')::numeric;
  v_class text := q.vehicle ->> 'class';
  v_rolling boolean := coalesce((q.vehicle ->> 'rolling')::boolean, true);
  v_tol numeric := 1 + coalesce((secoto_private.bareme_transporteurs() ->> 'tolerance_pct')::numeric, 5) / 100;
  v_filtre boolean := secoto_private.flag('bareme_transporteurs')
                      and coalesce(q.breakdown -> 'detail' -> 0 ->> 'pricing', '') = 'bareme_transporteurs';
  v_coef numeric := coalesce((r -> 'express' ->> 'coef')::numeric, 1.25);
  v_std_client integer := q.client_price_cents;
  v_std_pay integer := q.partner_pay_cents;
  v_exp_client integer;
  v_exp_pay integer;
  v_n_std integer;
  v_n_exp integer;
  v_n_eco integer;
  v_tranche jsonb;
  v_eco_pay integer;
  v_eco_client integer;
  v_out jsonb := '[]'::jsonb;
begin
  if not secoto_private.flag('trois_offres') or q.mode <> 'plateau' or q.status <> 'priced'
     or v_std_client is null or v_std_pay is null or coalesce(v_km, 0) <= 0 or v_class is null
     or jsonb_array_length(coalesce(q.vehicles, '[]'::jsonb)) > 1
     or coalesce(q.vehicle ->> 'category', 'standard') <> 'standard' then
    return null;
  end if;
  v_exp_client := round(v_std_client * v_coef)::int;
  v_exp_pay := round(v_std_pay * v_coef)::int;

  -- Transporteurs vérifiés éligibles (une entreprise et ses chauffeurs = un),
  -- avec leur prix déclaré pour ce trajet (NULL = barème de départ accepté).
  with elig as (
    select secoto_private.carrier_rate_owner(a.id) as owner,
           min(secoto_private.carrier_trip_price_cents(a.id, v_class, v_km, v_rolling)) as prix,
           bool_or(secoto_private.offre_partenaire_ok(a.id, 'eco')) as eco_ok
      from public.accounts a
     where a.role::text = 'transporter' and a.deleted_at is null
       and secoto_private.carrier_eligible_for_trip(a.id, q.vehicle, q.pickup, q.pickup_at)
     group by 1)
  select count(*) filter (where not v_filtre or prix is null or prix <= v_std_pay * v_tol),
         count(*) filter (where not v_filtre or prix is null or prix <= v_exp_pay * v_tol),
         count(*) filter (where eco_ok)
    into v_n_std, v_n_exp, v_n_eco
    from elig;

  if v_n_exp >= v_seuil then
    v_out := v_out || jsonb_build_array(jsonb_build_object(
      'cle', 'express', 'libelle', 'Express',
      'client_cents', v_exp_client, 'partenaire_cents', v_exp_pay, 'commission_cents', v_exp_client - v_exp_pay,
      'fenetre_h', coalesce((r -> 'express' ->> 'fenetre_h')::int, 48), 'transporteurs', v_n_exp, 'recommande', false));
  end if;
  if v_n_std >= v_seuil then
    v_out := v_out || jsonb_build_array(jsonb_build_object(
      'cle', 'standard', 'libelle', 'Standard',
      'client_cents', v_std_client, 'partenaire_cents', v_std_pay, 'commission_cents', v_std_client - v_std_pay,
      'fenetre_h', coalesce((r -> 'standard' ->> 'fenetre_h')::int, 120), 'transporteurs', v_n_std, 'recommande', true));
  end if;
  if v_rolling and coalesce(r -> 'eco' -> 'classes', '["voiture"]'::jsonb) ? v_class and v_n_eco >= v_seuil then
    v_tranche := secoto_private.offre_eco_tranche(v_km);
    if v_tranche is not null then
      v_eco_pay := round((v_tranche ->> 'transporteur_eur')::numeric * 100)::int;
      v_eco_client := round(v_eco_pay * (1 + coalesce((v_tranche ->> 'marge_pct')::numeric, 25) / 100))::int;
      -- Éco n'a de sens que moins chère que Standard.
      if v_eco_client < v_std_client then
        v_out := v_out || jsonb_build_array(jsonb_build_object(
          'cle', 'eco', 'libelle', 'Éco',
          'client_cents', v_eco_client, 'partenaire_cents', v_eco_pay, 'commission_cents', v_eco_client - v_eco_pay,
          'fenetre_h', coalesce((r -> 'eco' ->> 'fenetre_h')::int, 360), 'transporteurs', v_n_eco, 'recommande', false));
      end if;
    end if;
  end if;
  if jsonb_array_length(v_out) = 0 then return null; end if;
  return v_out;
end;
$$;
revoke all on function secoto_private.calculer_offres(public.transport_quotes) from public, anon, authenticated;

-- Calcul au moment où le devis reçoit son prix (création, recalcul). Les
-- devis déjà réservés (offre choisie) ne sont jamais recalculés.
create or replace function secoto_private.trg_quote_offres()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.offre_choisie is not null then return new; end if;
  if tg_op = 'INSERT' or new.status is distinct from old.status
     or new.client_price_cents is distinct from old.client_price_cents
     or new.partner_pay_cents is distinct from old.partner_pay_cents then
    if new.status = 'priced' then
      new.offres := secoto_private.calculer_offres(new);
      new.prix_standard := case when new.offres is not null then
        jsonb_build_object('client_cents', new.client_price_cents, 'partenaire_cents', new.partner_pay_cents) end;
    end if;
  end if;
  return new;
end;
$$;
drop trigger if exists trg_quote_offres on public.transport_quotes;
create trigger trg_quote_offres before insert or update on public.transport_quotes
  for each row execute function secoto_private.trg_quote_offres();

-- 4. AFFICHAGE CLIENT ----------------------------------------------------------------
select secoto_private.mig074_patch('secoto_private.quote_client_json(public.transport_quotes)'::regprocedure,
  $a$'business_id', q.business_id, 'created_at', q.created_at,$a$,
  $n$'business_id', q.business_id, 'created_at', q.created_at,
    -- 099 : trois offres (interrupteur « trois_offres »).
    'offres', case when secoto_private.flag('trois_offres') and q.offre_choisie is null then q.offres end,
    'offre_choisie', q.offre_choisie,$n$);

select secoto_private.mig074_patch('secoto_private.order_client_json(public.transport_orders)'::regprocedure,
  $a$'transport_price_cents', case when o.payment_circuit = 'direct' then o.partner_pay_cents end,$a$,
  $n$'transport_price_cents', case when o.payment_circuit = 'direct' or o.offre is not null then o.partner_pay_cents end,$n$);
select secoto_private.mig074_patch('secoto_private.order_client_json(public.transport_orders)'::regprocedure,
  $a$'commission_cents', case when o.payment_circuit = 'direct' then o.client_price_cents - o.partner_pay_cents end,$a$,
  $n$'commission_cents', case when o.payment_circuit = 'direct' or o.offre is not null then o.client_price_cents - o.partner_pay_cents end,$n$);
select secoto_private.mig074_patch('secoto_private.order_client_json(public.transport_orders)'::regprocedure,
  $a$'pickup_at', o.pickup_at, 'mission_id', o.mission_id,$a$,
  $n$'pickup_at', o.pickup_at, 'mission_id', o.mission_id,
    -- 099 : offre choisie, fenêtre, débit à la confirmation, transporteurs sollicités.
    'offre', o.offre, 'fenetre_fin', o.fenetre_fin,
    'debit_a_confirmation', coalesce(p.debit_a_confirmation, false),
    'transporteurs_sollicites', (select count(distinct x.partner_id) from public.transport_offers x
                                  where x.order_id = o.id and x.round = o.dispatch_round),$n$);

-- 5. CÔTÉ TRANSPORTEUR -------------------------------------------------------------------
select secoto_private.mig074_patch('secoto_private.offer_partner_json(public.transport_offers)'::regprocedure,
  $a$'expires_at', x.expires_at,$a$,
  $n$'expires_at', x.expires_at,
    -- 099 : offre (Express, Standard, Éco) et fenêtre de prise en charge. Jamais le prix client.
    'offre', o.offre, 'fenetre_fin', o.fenetre_fin,$n$);

create or replace function public.secoto_set_accepte_delai_long(p_accepte boolean)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_user uuid := secoto_private.assert_authenticated();
begin
  if not exists (select 1 from public.accounts a where a.id = v_user and a.role::text = 'transporter') then
    raise exception 'Réservé aux transporteurs.';
  end if;
  update public.partner_dispatch_preferences set accepte_delai_long = coalesce(p_accepte, false), updated_at = now()
   where account_id = v_user;
  if not found then
    -- Pas encore de préférences : on garde la disponibilité implicite actuelle.
    insert into public.partner_dispatch_preferences(account_id, available, accepte_delai_long)
    values (v_user, true, coalesce(p_accepte, false))
    on conflict (account_id) do update set accepte_delai_long = excluded.accepte_delai_long, updated_at = now();
  end if;
  return jsonb_build_object('accepte_delai_long', coalesce(p_accepte, false));
end;
$$;
revoke all on function public.secoto_set_accepte_delai_long(boolean) from public, anon;
grant execute on function public.secoto_set_accepte_delai_long(boolean) to authenticated;

-- 6. DIFFUSION -------------------------------------------------------------------------------
-- Fenêtre : les propositions restent ouvertes jusqu'à la fin de la fenêtre choisie.
select secoto_private.mig074_patch('secoto_private.od_broadcast(uuid)'::regprocedure,
  $a$v_expire := least(now() + make_interval(mins => v_ttl::int), v_order.pickup_at);$a$,
  $n$v_expire := case when v_order.fenetre_fin is not null then v_order.fenetre_fin  -- 099 : fenêtre de l'offre
                     else least(now() + make_interval(mins => v_ttl::int), v_order.pickup_at) end;$n$);
-- Éco : porte-voitures PL volontaires, au barème fixe SECOTO (pas de filtre sur leur barème au km).
select secoto_private.mig074_patch('secoto_private.od_broadcast(uuid)'::regprocedure,
  $a$and secoto_private.carrier_accepts_pay(a.id, p_order_id) loop$a$,
  $n$and (v_order.offre = 'eco' or secoto_private.carrier_accepts_pay(a.id, p_order_id))
                and secoto_private.offre_partenaire_ok(a.id, v_order.offre) loop  -- 099$n$);
-- Express : mise en avant dans la notification.
select secoto_private.mig074_patch('secoto_private.od_broadcast(uuid)'::regprocedure,
  $a$'mission_offer', 'Mission disponible',$a$,
  $n$'mission_offer', case v_order.offre when 'express' then 'Mission Express (prioritaire)'
                                        when 'eco' then 'Mission Éco (délai long)' else 'Mission disponible' end,$n$);

-- 7. RÉSERVATION D'UNE OFFRE ----------------------------------------------------------------
create or replace function public.secoto_od_book_offre(p_quote_id uuid, p_offre text, p_idempotency_key uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_user uuid := secoto_private.assert_authenticated();
  v_quote public.transport_quotes%rowtype;
  v_offre jsonb;
  v_res jsonb;
  v_order public.transport_orders%rowtype;
  v_heures integer;
begin
  if not secoto_private.flag('trois_offres') then raise exception 'Ces offres ne sont pas encore ouvertes.'; end if;
  select * into v_quote from public.transport_quotes q where q.id = p_quote_id for update;
  if not found or not (v_quote.account_id = v_user or (v_quote.business_id is not null and secoto_private.is_business_member(v_quote.business_id, v_user))) then
    raise exception 'Devis introuvable.' using errcode = 'P0002';
  end if;
  if v_quote.offre_choisie is null then
    select e into v_offre from jsonb_array_elements(coalesce(v_quote.offres, '[]'::jsonb)) e where e ->> 'cle' = p_offre;
    if v_offre is null then raise exception 'Cette offre n''est plus disponible. Recalculez le prix.'; end if;
    update public.transport_quotes
       set offre_choisie = p_offre,
           client_price_cents = (v_offre ->> 'client_cents')::int,
           partner_pay_cents = (v_offre ->> 'partenaire_cents')::int,
           margin_cents = (v_offre ->> 'client_cents')::int - (v_offre ->> 'partenaire_cents')::int,
           collect_cents = (v_offre ->> 'client_cents')::int,
           breakdown = jsonb_set(breakdown, '{lines}', jsonb_build_array(jsonb_build_object(
             'label', format('Transport sur plateau · offre %s', v_offre ->> 'libelle'),
             'eur', round((v_offre ->> 'client_cents')::numeric / 100, 2)))),
           updated_at = now()
     where id = p_quote_id;
  elsif v_quote.offre_choisie <> p_offre then
    raise exception 'Une autre offre a déjà été choisie pour ce devis.';
  end if;

  v_res := public.secoto_od_book_quote(p_quote_id, false, p_idempotency_key);

  select * into v_order from public.transport_orders o where o.quote_id = p_quote_id for update;
  if v_order.offre is null then
    v_heures := coalesce((secoto_private.trois_offres_reglages() -> p_offre ->> 'fenetre_h')::int,
                         case p_offre when 'express' then 48 when 'eco' then 360 else 120 end);
    update public.transport_orders
       set offre = p_offre,
           fenetre_fin = greatest(now(), pickup_at) + make_interval(hours => v_heures),
           payment_strategy = case when payment_circuit is null and funding = 'card' then 'authorize_then_capture' else payment_strategy end,
           updated_at = now()
     where id = v_order.id returning * into v_order;
    -- Circuit SECOTO : carte enregistrée maintenant, débit à la confirmation.
    update public.payments set debit_a_confirmation = true, capture_method = 'manual', updated_at = now()
     where id = v_order.payment_id and payment_circuit is null and status = 'pending';
    perform secoto_private.audit('order_offre', 'transport_order', v_order.id::text,
      jsonb_build_object('offre', p_offre, 'fenetre_fin', v_order.fenetre_fin));
  end if;
  return jsonb_build_object('order', secoto_private.order_client_json(v_order),
                            'already_booked', coalesce((v_res ->> 'already_booked')::boolean, false));
end;
$$;
revoke all on function public.secoto_od_book_offre(uuid, text, uuid) from public, anon;
grant execute on function public.secoto_od_book_offre(uuid, text, uuid) to authenticated;

-- 8. CARTE ENREGISTRÉE (SetupIntent réussi) -------------------------------------------------
select secoto_private.mig074_patch('public.secoto_direct_card_saved(uuid,text,text,text)'::regprocedure,
  $a$if v_payment.payment_circuit is distinct from 'direct' then$a$,
  $n$if v_payment.payment_circuit is distinct from 'direct' and not coalesce(v_payment.debit_a_confirmation, false) then  -- 099$n$);
select secoto_private.mig074_patch('public.secoto_direct_card_saved(uuid,text,text,text)'::regprocedure,
  $a$format('Commande %s : votre carte est validée, rien n''a été débité. Vous serez débité au moment où un transporteur accepte la mission, directement au nom de ce transporteur.', v_order.public_ref),$a$,
  $n$format(case when coalesce(v_payment.debit_a_confirmation, false)  -- 099
                 then 'Commande %s : votre carte est enregistrée, rien n''a été débité. Votre demande est envoyée aux transporteurs vérifiés : vous ne serez débité qu''au moment où l''un d''eux confirme.'
                 else 'Commande %s : votre carte est validée, rien n''a été débité. Vous serez débité au moment où un transporteur accepte la mission, directement au nom de ce transporteur.' end,
               v_order.public_ref),$n$);

-- Une tentative de débit annulée (validation bancaire demandée) ne doit
-- annuler ni la carte ni la commande (même règle que 083 pour le direct).
select secoto_private.mig074_patch('public.secoto_od_apply_payment_event(uuid,text,text,text,integer,timestamp with time zone,text)'::regprocedure,
  $a$and v_payment.payment_circuit is distinct from 'direct' then v_new := 'cancelled'; end if;$a$,
  $n$and v_payment.payment_circuit is distinct from 'direct'
         and not coalesce(v_payment.debit_a_confirmation, false) then v_new := 'cancelled'; end if;  -- 099$n$);

-- 9. DÉBIT À LA CONFIRMATION (appelé par le serveur, jamais par le téléphone) ----------
create or replace function public.secoto_differe_charge_context(p_order_id uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_order public.transport_orders%rowtype;
  v_payment public.payments%rowtype;
  v_customer text;
begin
  select * into v_order from public.transport_orders o where o.id = p_order_id;
  if not found then return jsonb_build_object('error', 'commande_introuvable'); end if;
  select * into v_payment from public.payments p where p.id = v_order.payment_id;
  if not found or not coalesce(v_payment.debit_a_confirmation, false) then
    return jsonb_build_object('error', 'paiement_non_differe');
  end if;
  select a.stripe_customer_id into v_customer from public.accounts a where a.id = v_payment.account_id;
  return jsonb_build_object(
    'order_id', v_order.id, 'public_ref', v_order.public_ref, 'order_status', v_order.status,
    'offre', v_order.offre, 'lock_expires_at', v_order.lock_expires_at, 'lock_offer_id', v_order.lock_offer_id,
    'payment_id', v_payment.id, 'payment_status', v_payment.status,
    'amount_cents', v_payment.amount_cents, 'currency', coalesce(v_payment.currency, 'eur'),
    'customer_id', v_customer, 'payment_method_id', v_payment.saved_payment_method_id,
    'action_required_at', v_payment.direct_action_required_at);
end;
$$;
revoke all on function public.secoto_differe_charge_context(uuid) from public, anon, authenticated;
grant execute on function public.secoto_differe_charge_context(uuid) to service_role;

-- La banque du client demande une validation (3D Secure) : la mission reste
-- réservée au transporteur le temps réglé (24 h par défaut), le client est prévenu.
create or replace function public.secoto_differe_needs_action(p_order_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_order public.transport_orders%rowtype; v_wait integer;
begin
  select * into v_order from public.transport_orders o where o.id = p_order_id for update;
  if not found or v_order.status <> 'partner_locked' or v_order.offre is null then
    return jsonb_build_object('result', 'ignored');
  end if;
  v_wait := greatest(coalesce((secoto_private.trois_offres_reglages() ->> 'attente_validation_min')::int, 1440), 30);
  update public.transport_orders set lock_expires_at = now() + make_interval(mins => v_wait), updated_at = now()
   where id = p_order_id;
  update public.payments set direct_action_required_at = coalesce(direct_action_required_at, now()),
         last_error = 'Validation bancaire demandée au client', updated_at = now()
   where id = v_order.payment_id;
  perform secoto_private.notify_event(v_order.account_id, 'payment_failed', 'Validez votre paiement',
    format('Commande %s : un transporteur a confirmé votre transport. Votre banque demande une validation : ouvrez la commande et validez le paiement sous %s h pour garder ce transporteur.',
           v_order.public_ref, round(v_wait / 60.0)),
    null, 'courses', 'od-differe-action:' || p_order_id::text, p_order_id);
  perform secoto_private.notify_event(v_order.lock_partner_id, 'order_update', 'Mission en attente de paiement',
    'Le client doit valider son paiement auprès de sa banque. La mission vous reste réservée en attendant.',
    null, 'offre', 'od-differe-action-partner:' || p_order_id::text, p_order_id);
  perform secoto_private.audit('differe_needs_action', 'transport_order', p_order_id::text, jsonb_build_object('wait_minutes', v_wait));
  return jsonb_build_object('result', 'needs_action', 'wait_minutes', v_wait);
end;
$$;
revoke all on function public.secoto_differe_needs_action(uuid) from public, anon, authenticated;
grant execute on function public.secoto_differe_needs_action(uuid) to service_role;

-- Validation non faite dans le délai : la mission repart en diffusion, la
-- carte reste enregistrée (rien n'a été débité).
create or replace function public.secoto_differe_action_expired(p_order_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_order public.transport_orders%rowtype;
begin
  select * into v_order from public.transport_orders o where o.id = p_order_id for update;
  if not found or v_order.status <> 'partner_locked' or v_order.offre is null then
    return jsonb_build_object('result', 'ignored');
  end if;
  update public.payments set direct_action_required_at = null, last_error = 'Validation bancaire non réalisée dans le délai', updated_at = now()
   where id = v_order.payment_id and status = 'requires_capture';
  perform secoto_private.od_release_lock(p_order_id, 'validation_bancaire_non_realisee');
  perform secoto_private.notify_event(v_order.account_id, 'order_update', 'Demande de nouveau proposée',
    format('Commande %s : le paiement n''a pas été validé à temps. Rien n''a été débité ; votre demande est de nouveau proposée aux transporteurs jusqu''à la fin de votre fenêtre.', v_order.public_ref),
    null, 'courses', 'od-differe-expired:' || p_order_id::text || ':' || extract(epoch from now())::bigint, p_order_id);
  return jsonb_build_object('result', 'released');
end;
$$;
revoke all on function public.secoto_differe_action_expired(uuid) from public, anon, authenticated;
grant execute on function public.secoto_differe_action_expired(uuid) to service_role;

-- 10. FENÊTRE ÉCOULÉE ----------------------------------------------------------------------------
select secoto_private.mig074_patch('public.secoto_od_maintenance_tick()'::regprocedure,
  $a$o.public_ref, o.payment_circuit from public.transport_orders o$a$,
  $n$o.public_ref, o.payment_circuit, o.offre from public.transport_orders o$n$);
select secoto_private.mig074_patch('public.secoto_od_maintenance_tick()'::regprocedure,
  $a$format(case when r.payment_circuit = 'direct'$a$,
  $n$format(case when r.offre is not null  -- 099 : aucun débit, relance en un clic
          then 'Commande %s : aucun transporteur n''a confirmé dans la fenêtre choisie. Rien n''a été débité et la demande est annulée. Relancez-la en un clic depuis Mes commandes : en Express, ou avec une nouvelle fenêtre.'
          when r.payment_circuit = 'direct'$n$);
-- Verrous expirés : le serveur doit savoir qu'il s'agit d'un débit à la confirmation.
select secoto_private.mig074_patch('public.secoto_od_maintenance_tick()'::regprocedure,
  $a$'funding', o.funding, 'circuit', o.payment_circuit)$a$,
  $n$'funding', o.funding, 'circuit', o.payment_circuit, 'differe', coalesce(p.debit_a_confirmation, false))$n$);

-- Relance en un clic : nouveau devis, même trajet, offres recalculées.
create or replace function public.secoto_od_reproposer(p_order_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_user uuid := secoto_private.assert_authenticated();
  v_order public.transport_orders%rowtype;
  v_old public.transport_quotes%rowtype;
  v_new public.transport_quotes%rowtype;
  v_client integer;
  v_pay integer;
begin
  if not secoto_private.flag('trois_offres') then raise exception 'Ces offres ne sont pas encore ouvertes.'; end if;
  select * into v_order from public.transport_orders o where o.id = p_order_id;
  if not found or not (v_order.account_id = v_user or (v_order.business_id is not null and secoto_private.is_business_member(v_order.business_id, v_user))) then
    raise exception 'Commande introuvable.' using errcode = 'P0002';
  end if;
  if v_order.status not in ('no_partner', 'cancelled') or v_order.offre is null then
    raise exception 'Cette commande ne peut pas être relancée.';
  end if;
  select * into v_old from public.transport_quotes q where q.id = v_order.quote_id;
  v_client := coalesce((v_old.prix_standard ->> 'client_cents')::int, v_old.client_price_cents);
  v_pay := coalesce((v_old.prix_standard ->> 'partenaire_cents')::int, v_old.partner_pay_cents);
  insert into public.transport_quotes(account_id, business_id, mode, status, pickup, delivery, vehicle, schedule, route,
      grid_id, grid_version, engine, client_price_cents, partner_pay_cents, margin_cents, collect_cents,
      transport_direct_cents, breakdown, valid_until, pickup_at, vehicles, group_discount_cents,
      utm_source, utm_medium, utm_campaign, utm_content, gclid, fbclid, attribution_at, consentement_pub)
  values (v_order.account_id, v_old.business_id, v_old.mode, 'priced', v_old.pickup, v_old.delivery, v_old.vehicle, v_old.schedule, v_old.route,
      v_old.grid_id, v_old.grid_version, v_old.engine, v_client, v_pay, v_client - v_pay, v_client,
      0, v_old.breakdown, now() + interval '24 hours', greatest(v_old.pickup_at, now() + interval '2 hours'),
      v_old.vehicles, 0,
      v_old.utm_source, v_old.utm_medium, v_old.utm_campaign, v_old.utm_content, v_old.gclid, v_old.fbclid, v_old.attribution_at, v_old.consentement_pub)
  returning * into v_new;
  perform secoto_private.audit('quote_reproposed', 'transport_quote', v_new.id::text, jsonb_build_object('from_order', p_order_id));
  return secoto_private.quote_client_json(v_new);
end;
$$;
revoke all on function public.secoto_od_reproposer(uuid) from public, anon;
grant execute on function public.secoto_od_reproposer(uuid) to authenticated;

-- 11. ADMIN : réglages et mesure ------------------------------------------------------------------
create or replace function public.secoto_admin_trois_offres()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  perform secoto_private.assert_admin();
  return jsonb_build_object('actif', secoto_private.flag('trois_offres'), 'reglages', secoto_private.trois_offres_reglages());
end;
$$;
revoke all on function public.secoto_admin_trois_offres() from public, anon;
grant execute on function public.secoto_admin_trois_offres() to authenticated;

create or replace function public.secoto_admin_set_trois_offres(p_reglages jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare r jsonb := p_reglages; t jsonb; v_prev numeric := 0;
begin
  perform secoto_private.assert_admin();
  if r is null or jsonb_typeof(r) <> 'object' then raise exception 'Réglages invalides.'; end if;
  if coalesce((r ->> 'seuil_transporteurs')::int, 0) not between 1 and 50 then raise exception 'Seuil de transporteurs : entre 1 et 50.'; end if;
  if coalesce((r -> 'express' ->> 'coef')::numeric, 0) not between 1 and 3 then raise exception 'Coefficient Express : entre 1 et 3.'; end if;
  if coalesce((r -> 'express' ->> 'fenetre_h')::int, 0) not between 1 and 720 then raise exception 'Fenêtre Express : entre 1 et 720 h.'; end if;
  if coalesce((r -> 'standard' ->> 'fenetre_h')::int, 0) not between 1 and 720 then raise exception 'Fenêtre Standard : entre 1 et 720 h.'; end if;
  if coalesce((r -> 'eco' ->> 'fenetre_h')::int, 0) not between 1 and 2160 then raise exception 'Fenêtre Éco : entre 1 et 2160 h.'; end if;
  if coalesce((r ->> 'attente_validation_min')::int, 0) not between 30 and 4320 then raise exception 'Délai de validation bancaire : entre 30 et 4320 min.'; end if;
  if jsonb_typeof(r -> 'eco' -> 'tranches') <> 'array' or jsonb_array_length(r -> 'eco' -> 'tranches') = 0 then
    raise exception 'Éco : au moins une tranche.';
  end if;
  for t in select e from jsonb_array_elements(r -> 'eco' -> 'tranches') e loop
    if coalesce((t ->> 'transporteur_eur')::numeric, 0) <= 0 or coalesce((t ->> 'marge_pct')::numeric, -1) not between 0 and 100 then
      raise exception 'Éco : chaque tranche a une rémunération positive et une marge entre 0 et 100 %%.';
    end if;
    if (t ->> 'max_km') is not null then
      if (t ->> 'max_km')::numeric <= v_prev then raise exception 'Éco : tranches de distance croissantes.'; end if;
      v_prev := (t ->> 'max_km')::numeric;
    end if;
  end loop;
  insert into public.app_settings(key, value) values ('trois_offres', r)
  on conflict (key) do update set value = excluded.value;
  perform secoto_private.audit('trois_offres_reglages', 'app_settings', 'trois_offres', r);
  return secoto_private.trois_offres_reglages();
end;
$$;
revoke all on function public.secoto_admin_set_trois_offres(jsonb) from public, anon;
grant execute on function public.secoto_admin_set_trois_offres(jsonb) to authenticated;

-- Mesure par offre (sur p_jours jours). Délai = carte enregistrée -> confirmation.
create or replace function public.secoto_admin_offres_stats(p_jours integer default 30)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_depuis timestamptz := now() - make_interval(days => greatest(coalesce(p_jours, 30), 1));
begin
  perform secoto_private.assert_admin();
  return (
    with k(cle) as (values ('express'), ('standard'), ('eco')),
    aff as (select e ->> 'cle' as cle, count(*) as n
              from public.transport_quotes q, jsonb_array_elements(q.offres) e
             where q.offres is not null and q.created_at >= v_depuis group by 1),
    cmd as (select o.offre as cle,
                   count(*) as choisies,
                   count(*) filter (where o.confirmed_at is not null) as acceptees,
                   count(*) filter (where o.status = 'no_partner') as fenetre_expiree,
                   avg(extract(epoch from (o.confirmed_at - coalesce(p.authorized_at, o.created_at))) / 3600.0)
                     filter (where o.confirmed_at is not null) as delai_h,
                   sum(o.client_price_cents - o.partner_pay_cents) filter (where o.confirmed_at is not null) as commission_cents
              from public.transport_orders o left join public.payments p on p.id = o.payment_id
             where o.offre is not null and o.created_at >= v_depuis
               and coalesce(o.is_test, false) = false
             group by 1)
    select jsonb_build_object('jours', greatest(coalesce(p_jours, 30), 1), 'offres', jsonb_agg(jsonb_build_object(
      'cle', k.cle,
      'affichees', coalesce(aff.n, 0),
      'choisies', coalesce(cmd.choisies, 0),
      'acceptees', coalesce(cmd.acceptees, 0),
      'taux_acceptation', case when coalesce(cmd.choisies, 0) > 0 then round(100.0 * cmd.acceptees / cmd.choisies, 1) end,
      'delai_moyen_h', round(cmd.delai_h::numeric, 1),
      'fenetre_expiree', coalesce(cmd.fenetre_expiree, 0),
      'taux_expiration', case when coalesce(cmd.choisies, 0) > 0 then round(100.0 * cmd.fenetre_expiree / cmd.choisies, 1) end,
      'commission_cents', coalesce(cmd.commission_cents, 0)) order by array_position(array['express', 'standard', 'eco'], k.cle)))
      from k left join aff on aff.cle = k.cle left join cmd on cmd.cle = k.cle);
end;
$$;
revoke all on function public.secoto_admin_offres_stats(integer) from public, anon;
grant execute on function public.secoto_admin_offres_stats(integer) to authenticated;
