-- ============================================================================
-- SECOTO — MIGRATION 036 : VERSEMENTS TRANSPORTEURS PAR STRIPE CONNECT
-- ----------------------------------------------------------------------------
-- Décisions Nawfal Benchiha du 22/09/2026 :
--
--  1. Le client paie SECOTO (inchangé). SECOTO reverse ensuite le transporteur
--     par un Stripe Transfer vers son compte Connect Express : modèle
--     « charges et transferts séparés ». Aucun Transfer à l'acceptation.
--  2. Le point d'entrée est public.partner_payouts : un versement part quand il
--     est dû (livraison + 48 h), jamais s'il est annulé. Montant = EXACTEMENT
--     partner_payouts.amount_cents, relu au moment du transfert.
--  3. Missions créées à la main : un versement est programmé à la livraison,
--     sauf si le client paie en espèces.
--  4. Frais réels du convoyage : restent en virement, hors Connect.
--  5. Annulation client tardive APRÈS acceptation : le client est remboursé à
--     50 %, le transporteur reçoit 45 % du prix client, SECOTO garde 5 %.
--     Exemple : 600 € → 300 € remboursés, 270 € au transporteur, 30 € SECOTO.
--  6. Le virement manuel reste possible en secours. Un versement ne peut être
--     soldé qu'une fois, par l'un ou par l'autre.
--  7. On annonce « paiement déclenché sous 48 h » : le virement bancaire vers
--     le transporteur suit ensuite le calendrier de son compte Stripe.
--
-- Les transferts automatiques restent COUPÉS tant que l'interrupteur
-- connect_payouts n'est pas ouvert. Additive et rejouable.
-- ============================================================================

begin;

do $guard$
begin
  if not exists (select 1 from information_schema.columns
                  where table_schema = 'public' and table_name = 'partner_payouts' and column_name = 'due_at') then
    raise exception 'Migration 035 requise avant la 036.';
  end if;
end
$guard$;

-- ----------------------------------------------------------------------------
-- 1. INTERRUPTEUR ET POLITIQUE
-- ----------------------------------------------------------------------------
alter table public.secoto_feature_flags drop constraint if exists secoto_feature_flags_key_check;
alter table public.secoto_feature_flags add constraint secoto_feature_flags_key_check
  check (key in ('auto_pricing', 'od_payments', 'subscriptions', 'dispatch_notifications',
                 'live_tracking', 'direct_accept', 'connect_payouts'));
insert into public.secoto_feature_flags(key) values ('connect_payouts') on conflict (key) do nothing;

update public.app_settings
   set value = value || jsonb_build_object(
     'late_cancel_partner_pct', 45,   -- part du prix client versée au transporteur
     'payout_max_attempts', 5)        -- au-delà : échec, contrôle manuel
 where key = 'dispatch_policy';

-- ----------------------------------------------------------------------------
-- 2. COMPTE CONNECT DU TRANSPORTEUR
-- ----------------------------------------------------------------------------
alter table public.accounts add column if not exists stripe_connect_account_id text;
alter table public.accounts add column if not exists stripe_connect_status text;
alter table public.accounts add column if not exists stripe_transfers_enabled boolean not null default false;
alter table public.accounts add column if not exists stripe_payouts_enabled boolean not null default false;
alter table public.accounts add column if not exists stripe_connect_onboarded_at timestamptz;
alter table public.accounts add column if not exists stripe_connect_updated_at timestamptz;
create unique index if not exists accounts_stripe_connect_account_uidx
  on public.accounts(stripe_connect_account_id) where stripe_connect_account_id is not null;

-- Seul le serveur écrit ces colonnes. Un utilisateur qui modifie son profil ne
-- peut ni poser un identifiant Stripe arbitraire, ni se déclarer « actif ».
create or replace function secoto_private.trg_protect_connect_columns()
returns trigger language plpgsql set search_path = ''
as $f$
begin
  if current_user in ('authenticated', 'anon') and (
       new.stripe_connect_account_id is distinct from old.stripe_connect_account_id
    or new.stripe_connect_status     is distinct from old.stripe_connect_status
    or new.stripe_transfers_enabled  is distinct from old.stripe_transfers_enabled
    or new.stripe_payouts_enabled    is distinct from old.stripe_payouts_enabled
    or new.stripe_connect_onboarded_at is distinct from old.stripe_connect_onboarded_at) then
    raise exception 'Les informations de versement Stripe ne se modifient que depuis SECOTO.';
  end if;
  return new;
end;
$f$;
drop trigger if exists trg_secoto_protect_connect_columns on public.accounts;
create trigger trg_secoto_protect_connect_columns
  before update on public.accounts
  for each row execute function secoto_private.trg_protect_connect_columns();

-- ----------------------------------------------------------------------------
-- 3. VERSEMENTS : états et traçabilité
-- ----------------------------------------------------------------------------
alter table public.partner_payouts drop constraint if exists partner_payouts_status_check;
alter table public.partner_payouts add constraint partner_payouts_status_check
  check (status in ('to_pay', 'processing', 'paid', 'failed', 'cancelled'));
alter table public.partner_payouts add column if not exists kind text not null default 'mission';
alter table public.partner_payouts drop constraint if exists partner_payouts_kind_check;
alter table public.partner_payouts add constraint partner_payouts_kind_check check (kind in ('mission', 'late_cancel'));
alter table public.partner_payouts add column if not exists paid_via text;
alter table public.partner_payouts drop constraint if exists partner_payouts_paid_via_check;
alter table public.partner_payouts add constraint partner_payouts_paid_via_check check (paid_via is null or paid_via in ('connect', 'manual'));
alter table public.partner_payouts add column if not exists stripe_transfer_id text;
alter table public.partner_payouts add column if not exists stripe_source_charge_id text;
alter table public.partner_payouts add column if not exists attempt_count integer not null default 0;
alter table public.partner_payouts add column if not exists last_error text;
alter table public.partner_payouts add column if not exists processing_at timestamptz;
alter table public.partner_payouts add column if not exists next_retry_at timestamptz;
create unique index if not exists partner_payouts_transfer_uidx
  on public.partner_payouts(stripe_transfer_id) where stripe_transfer_id is not null;
create index if not exists partner_payouts_due_idx on public.partner_payouts(status, due_at);

-- ----------------------------------------------------------------------------
-- 4. RÉSERVATION ATOMIQUE DES VERSEMENTS DUS (service_role uniquement)
-- ----------------------------------------------------------------------------
-- Deux exécutions simultanées de od-maintenance ne peuvent jamais réserver le
-- même versement : verrou de ligne + skip locked. La clé d'idempotence Stripe
-- n'est que la seconde protection.
create or replace function public.secoto_payouts_claim_due(p_limit integer default 20)
returns jsonb language plpgsql volatile security definer set search_path = ''
as $f$
declare v_rows jsonb;
begin
  if not secoto_private.flag('connect_payouts') then return '[]'::jsonb; end if;

  -- Traitement interrompu depuis plus de 24 h : la clé d'idempotence Stripe a
  -- pu expirer, on ne rejoue plus rien automatiquement.
  update public.partner_payouts
     set status = 'failed', processing_at = null,
         last_error = left(coalesce(last_error || ' | ', '') || 'Traitement interrompu depuis plus de 24 h : vérifier dans Stripe avant tout nouveau versement.', 500)
   where status = 'processing' and processing_at < now() - interval '24 hours';

  with due as (
    select pp.id
      from public.partner_payouts pp
      join public.accounts a on a.id = pp.partner_id
      left join public.transport_orders o on o.id = pp.order_id
      left join public.payments p on p.id = o.payment_id
     where (
             (pp.status = 'to_pay' and pp.due_at <= now() and coalesce(pp.next_retry_at, now()) <= now())
          -- Réservé il y a plus de 15 min sans résultat : reprise sans risque,
          -- la clé d'idempotence renvoie le même transfert.
          or (pp.status = 'processing' and pp.processing_at < now() - interval '15 minutes')
           )
       and pp.amount_cents > 0
       and a.stripe_connect_account_id is not null
       and a.stripe_transfers_enabled
       -- Commande en ligne : paiement client encaissé et non contesté.
       and (pp.order_id is null or (p.status = 'paid' and coalesce(p.dispute_status, '') <> 'open'))
       -- Mission : seulement une fois livrée. Annulation tardive : dès échéance.
       and (pp.kind = 'late_cancel' or pp.order_id is null or o.status = 'delivered')
     order by pp.due_at
     limit greatest(1, least(coalesce(p_limit, 20), 100))
     for update of pp skip locked
  ), reserve as (
    update public.partner_payouts pp
       set status = 'processing', processing_at = now(), attempt_count = pp.attempt_count + 1
      from due where pp.id = due.id
    returning pp.*
  )
  select coalesce(jsonb_agg(jsonb_build_object(
      'payout_id', r.id, 'amount_cents', r.amount_cents, 'kind', r.kind,
      'destination', a.stripe_connect_account_id,
      'order_id', r.order_id, 'mission_id', r.mission_id, 'attempt', r.attempt_count,
      -- Charge d'origine : paiement de la commande, sinon dernier paiement
      -- encaissé de la mission (missions manuelles payées par carte).
      'intent_id', coalesce(p.provider_intent_id, (
        select pm.provider_intent_id from public.payments pm
         where pm.mission_id = r.mission_id and pm.status = 'paid' and pm.provider_intent_id is not null
         order by pm.paid_at desc nulls last limit 1)))), '[]'::jsonb)
    into v_rows
    from reserve r
    join public.accounts a on a.id = r.partner_id
    left join public.transport_orders o on o.id = r.order_id
    left join public.payments p on p.id = o.payment_id;

  return v_rows;
end;
$f$;

create or replace function public.secoto_payout_transfer_result(
  p_payout_id uuid, p_success boolean, p_transfer_id text, p_charge_id text, p_error text)
returns jsonb language plpgsql volatile security definer set search_path = ''
as $f$
declare
  v public.partner_payouts%rowtype;
  v_max integer := secoto_private.policy_num('payout_max_attempts', 5)::int;
  v_ref text;
begin
  select * into v from public.partner_payouts pp where pp.id = p_payout_id for update;
  if not found then return jsonb_build_object('result', 'unknown_payout'); end if;
  if v.status = 'paid' then return jsonb_build_object('result', 'already_paid'); end if;
  select m.public_ref into v_ref from public.missions m where m.id = v.mission_id;

  if p_success then
    update public.partner_payouts
       set status = 'paid', paid_via = 'connect', paid_at = now(),
           reference = left(p_transfer_id, 120), stripe_transfer_id = p_transfer_id,
           stripe_source_charge_id = p_charge_id,
           processing_at = null, next_retry_at = null, last_error = null
     where id = p_payout_id;
    perform secoto_private.notify_event(v.partner_id, 'payment', 'Paiement déclenché',
      format('%s : %s € envoyés sur votre compte de versement. Le virement vers votre banque suit le calendrier de votre compte Stripe.',
        coalesce(v_ref, 'Mission'), replace(to_char(v.amount_cents / 100.0, 'FM999990D00'), '.', ',')),
      v.mission_id, 'paiement', 'payout-paid:' || p_payout_id::text, p_payout_id);
    if v.status <> 'processing' then
      -- Résultat arrivé après un passage en échec : l'argent est parti, on le
      -- signale pour éviter tout virement manuel en double.
      perform secoto_private.notify_admins_event('payment', 'Versement Connect confirmé tardivement',
        format('%s : transfert %s réussi alors que le versement était marqué %s.', coalesce(v_ref, p_payout_id::text), p_transfer_id, v.status),
        'paiement', 'payout-late-success:' || p_payout_id::text, p_payout_id);
    end if;
    perform secoto_private.audit('payout_paid_connect', 'partner_payout', p_payout_id::text,
      jsonb_build_object('transfer', p_transfer_id, 'charge', p_charge_id, 'amount_cents', v.amount_cents));
    return jsonb_build_object('result', 'paid');
  end if;

  if v.status <> 'processing' then return jsonb_build_object('result', 'ignored', 'status', v.status); end if;

  if v.attempt_count >= v_max then
    update public.partner_payouts
       set status = 'failed', processing_at = null, last_error = left(coalesce(p_error, 'transfer_failed'), 500)
     where id = p_payout_id;
    perform secoto_private.notify_admins_event('payment', 'Versement transporteur en échec',
      format('%s : %s € — %s. À régler manuellement.', coalesce(v_ref, p_payout_id::text),
        replace(to_char(v.amount_cents / 100.0, 'FM999990D00'), '.', ','), left(coalesce(p_error, ''), 160)),
      'paiement', 'payout-failed:' || p_payout_id::text, p_payout_id);
    return jsonb_build_object('result', 'failed');
  end if;

  -- Nouvel essai avec délai croissant : 15 min, 30 min, 1 h, 2 h… (6 h max).
  update public.partner_payouts
     set status = 'to_pay', processing_at = null, last_error = left(coalesce(p_error, 'transfer_failed'), 500),
         next_retry_at = now() + make_interval(mins => least(360, (15 * power(2, greatest(v.attempt_count - 1, 0)))::int))
   where id = p_payout_id;
  return jsonb_build_object('result', 'retry');
end;
$f$;

-- ----------------------------------------------------------------------------
-- 5. VIREMENT MANUEL : toujours possible, jamais en double
-- ----------------------------------------------------------------------------
create or replace function public.secoto_admin_mark_payout_paid(p_payout_id uuid, p_reference text)
returns jsonb language plpgsql volatile security definer set search_path = ''
as $f$
declare v public.partner_payouts%rowtype;
begin
  perform secoto_private.assert_admin();
  if length(btrim(coalesce(p_reference, ''))) < 3 then raise exception 'Référence du virement requise.'; end if;
  select * into v from public.partner_payouts pp where pp.id = p_payout_id for update;
  if not found then raise exception 'Versement introuvable.'; end if;
  if v.status = 'processing' then
    raise exception 'Un versement Stripe est en cours pour cette mission : attendez son résultat avant tout virement manuel.';
  end if;
  if v.status not in ('to_pay', 'failed') then
    raise exception 'Versement déjà réglé ou annulé (%).', v.status;
  end if;
  update public.partner_payouts
     set status = 'paid', paid_via = 'manual', paid_at = now(), reference = left(p_reference, 120),
         marked_by = auth.uid(), processing_at = null, next_retry_at = null
   where id = p_payout_id returning * into v;
  perform secoto_private.audit('payout_marked_paid', 'partner_payout', p_payout_id::text,
    jsonb_build_object('reference', p_reference, 'via', 'manual'));
  return to_jsonb(v);
end;
$f$;

-- La liste « à payer » montre aussi ce qui est en cours ou en échec.
create or replace function public.secoto_admin_partner_payouts(p_status text default 'to_pay')
returns jsonb language plpgsql stable security definer set search_path = ''
as $f$
begin
  perform secoto_private.assert_admin();
  return coalesce((select jsonb_agg(to_jsonb(pp) || jsonb_build_object(
      'partner_name', coalesce(a.company_name, a.full_name), 'mission_ref', m.public_ref,
      'partner_connect_status', coalesce(a.stripe_connect_status, 'none'),
      'partner_transfers_enabled', a.stripe_transfers_enabled,
      'client_payment_status', (select p.status from public.payments p join public.transport_orders o on o.payment_id = p.id where o.id = pp.order_id))
    order by pp.due_at nulls last, pp.created_at)
    from public.partner_payouts pp
    join public.accounts a on a.id = pp.partner_id
    join public.missions m on m.id = pp.mission_id
    where p_status is null
       or pp.status = p_status
       or (p_status = 'to_pay' and pp.status in ('processing', 'failed'))), '[]'::jsonb);
end;
$f$;

-- ----------------------------------------------------------------------------
-- 6. ANNULATION TARDIVE APRÈS ACCEPTATION : 45 % au transporteur
-- ----------------------------------------------------------------------------
create or replace function secoto_private.od_late_cancel_compensation(p_order_id uuid)
returns void language plpgsql volatile security definer set search_path = ''
as $f$
declare
  v_order public.transport_orders%rowtype;
  v_pct numeric := secoto_private.policy_num('late_cancel_partner_pct', 45);
  v_amount integer;
begin
  select * into v_order from public.transport_orders o where o.id = p_order_id;
  if not found or v_order.assigned_partner_id is null or v_order.mission_id is null
     or v_order.funding <> 'card' then return; end if;
  v_amount := round(v_order.client_price_cents * v_pct / 100)::int;
  if v_amount <= 0 then return; end if;

  insert into public.partner_payouts(mission_id, order_id, partner_id, amount_cents, due_at, mode, kind)
  values (v_order.mission_id, v_order.id, v_order.assigned_partner_id, v_amount,
          now() + make_interval(hours => secoto_private.policy_num('payout_delay_hours', 48)::int),
          v_order.mode, 'late_cancel')
  on conflict (mission_id) do update
     set amount_cents = excluded.amount_cents, status = 'to_pay', kind = 'late_cancel',
         due_at = excluded.due_at, order_id = excluded.order_id
   where public.partner_payouts.status = 'cancelled';

  perform secoto_private.notify_event(v_order.assigned_partner_id, 'payment', 'Indemnité d''annulation',
    format('Commande %s annulée tardivement par le client : %s € vous sont dus, paiement déclenché sous 48 h.',
      v_order.public_ref, replace(to_char(v_amount / 100.0, 'FM999990D00'), '.', ',')),
    v_order.mission_id, 'paiement', 'od-late-cancel-pay:' || p_order_id::text, p_order_id);
  perform secoto_private.audit('late_cancel_compensation', 'transport_order', p_order_id::text,
    jsonb_build_object('amount_cents', v_amount, 'pct', v_pct));
end;
$f$;

-- Branchement dans l'annulation client (migration 035), sans réécrire la fonction.
do $cancel$
declare v_src text;
begin
  select pg_get_functiondef(p.oid) into v_src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'secoto_od_cancel_order';
  if v_src is null or position('od_late_cancel_compensation' in v_src) > 0 then return; end if;
  if position('perform secoto_private.od_stop_order_amount(p_order_id, ''cancelled'', v_reason, v_refund);' in v_src) = 0 then
    raise exception 'secoto_od_cancel_order : point d''insertion introuvable, migration 035 attendue.';
  end if;
  v_src := replace(v_src,
    'perform secoto_private.od_stop_order_amount(p_order_id, ''cancelled'', v_reason, v_refund);',
    'perform secoto_private.od_stop_order_amount(p_order_id, ''cancelled'', v_reason, v_refund);' || E'\n' ||
    '  if v_late then perform secoto_private.od_late_cancel_compensation(p_order_id); end if;');
  v_src := replace(v_src, 'retenus · transporteur à arbitrer', 'retenus · 45 %% au transporteur');
  execute v_src;
end
$cancel$;

-- Annulation admin SANS remboursement : le versement doit aussi être annulé.
do $admin_cancel$
declare v_src text; v_marque text := 'update public.transport_orders set status = ''cancelled'', cancelled_at = now(), cancel_reason = left(p_reason, 200), updated_at = now() where id = p_order_id;';
begin
  select pg_get_functiondef(p.oid) into v_src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'secoto_admin_od_cancel_order';
  if v_src is null or position('partner_payouts' in v_src) > 0 then return; end if;
  if position(v_marque in v_src) = 0 then
    raise exception 'secoto_admin_od_cancel_order : point d''insertion introuvable.';
  end if;
  v_src := replace(v_src, v_marque, v_marque || E'\n' ||
    '    update public.partner_payouts set status = ''cancelled'' where order_id = p_order_id and status in (''to_pay'', ''failed'');');
  execute v_src;
end
$admin_cancel$;

-- ----------------------------------------------------------------------------
-- 7. MISSIONS CRÉÉES À LA MAIN : versement programmé, sauf espèces
-- ----------------------------------------------------------------------------
create or replace function secoto_private.trg_manual_mission_payout()
returns trigger language plpgsql volatile security definer set search_path = ''
as $f$
declare v_done_new boolean; v_done_old boolean; v_cutover timestamptz;
begin
  v_done_new := coalesce(new.progress_status, '') in ('delivery_completed', 'completed') or new.status::text = 'completed';
  v_done_old := coalesce(old.progress_status, '') in ('delivery_completed', 'completed') or old.status::text = 'completed';
  if not v_done_new or v_done_old then return new; end if;
  if new.assigned_transporter_id is null or coalesce(new.carrier_pay, 0) <= 0 then return new; end if;
  if lower(coalesce(new.payment_method, '')) in ('especes', 'espèces', 'cash') then return new; end if;
  -- Commandes en ligne : versement créé par trg_od_sync_from_mission.
  if exists (select 1 from public.transport_orders o where o.mission_id = new.id) then return new; end if;
  -- Plateau antérieur à la sous-traitance totale : le client payait le
  -- transport en direct au transporteur. Verser en plus serait payer deux fois.
  select (s.value ->> 'sous_traitance_totale_since')::timestamptz into v_cutover
    from public.app_settings s where s.key = 'dispatch_policy';
  if new.type::text = 'plateau' and (v_cutover is null or coalesce(new.created_at, now()) < v_cutover) then
    return new;
  end if;

  insert into public.partner_payouts(mission_id, order_id, partner_id, amount_cents, due_at, mode, kind)
  values (new.id, null, new.assigned_transporter_id, round(new.carrier_pay * 100)::int,
          now() + make_interval(hours => secoto_private.policy_num('payout_delay_hours', 48)::int),
          new.type::text, 'mission')
  on conflict (mission_id) do nothing;
  if found then
    perform secoto_private.notify_event(new.assigned_transporter_id, 'payment', 'Paiement programmé',
      format('Mission %s livrée : paiement de %s € déclenché sous 48 heures.', new.public_ref,
        replace(to_char(new.carrier_pay, 'FM999990D00'), '.', ',')),
      new.id, 'paiement', 'manual-payout:' || new.id::text, new.id);
  end if;
  return new;
end;
$f$;
drop trigger if exists trg_secoto_manual_mission_payout on public.missions;
create trigger trg_secoto_manual_mission_payout
  after update of status, progress_status on public.missions
  for each row execute function secoto_private.trg_manual_mission_payout();

-- ----------------------------------------------------------------------------
-- 8. « PAIEMENT DÉCLENCHÉ SOUS 48 H » : libellés alignés, et €/km affiché
-- ----------------------------------------------------------------------------
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
    'partner_included',
      case when coalesce((q.route ->> 'distance_km')::numeric, 0) > 0
        then jsonb_build_array(format('Soit %s €/km',
               replace(to_char(round((x.partner_pay_cents / 100.0)
                 / (q.route ->> 'distance_km')::numeric, 2), 'FM990D00'), '.', ',')))
        else '[]'::jsonb end
      || case when o.mode = 'convoyage'
        then jsonb_build_array(
          'Frais réels (carburant, péages) remboursés sur justificatifs validés',
          'Paiement déclenché sous 48 h après la livraison')
        else jsonb_build_array(
          'Péages et carburant inclus dans votre rémunération',
          'Paiement déclenché sous 48 h après la livraison') end,
    'partner_excluded', case when o.mode = 'convoyage'
      then jsonb_build_array('Retour après livraison : à votre charge')
      else jsonb_build_array('Retour à vide après livraison : à votre charge') end,
    'mission_id', case when o.assigned_partner_id = x.partner_id then o.mission_id end)
  from public.transport_orders o join public.transport_quotes q on q.id = o.quote_id
  where o.id = x.order_id;
$f$;

do $textes$
declare v_src text;
begin
  -- €/km dans la notification d'offre (idempotent).
  select pg_get_functiondef(p.oid) into v_src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'secoto_private' and p.proname = 'od_broadcast';
  if v_src is not null and position('€ pour vous (' in v_src) = 0 then
    v_src := replace(v_src,
      '''%s · %s → %s · %s · %s € pour vous''',
      '''%s · %s → %s · %s · %s € pour vous (%s €/km)''');
    v_src := replace(v_src,
      'to_char(v_order.partner_pay_cents / 100.0, ''FM999990D00'')),',
      'to_char(v_order.partner_pay_cents / 100.0, ''FM999990D00''),' || E'\n' ||
      '          replace(to_char(round((v_order.partner_pay_cents / 100.0) / nullif((v_quote.route ->> ''distance_km'')::numeric, 0), 2), ''FM990D00''), ''.'', '','')),');
    execute v_src;
  end if;

  -- Notification de livraison : « déclenché », pas « versé ».
  select pg_get_functiondef(p.oid) into v_src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'secoto_private' and p.proname = 'trg_od_sync_from_mission';
  if v_src is not null and position('vous sont versés sous 48 heures' in v_src) > 0 then
    v_src := replace(v_src, 'Mission %s livrée : %s € vous sont versés sous 48 heures.',
                            'Mission %s livrée : paiement de %s € déclenché sous 48 heures.');
    execute v_src;
  end if;
end
$textes$;

-- ----------------------------------------------------------------------------
-- 9. BARÈME PLATEAU EN PRODUCTION : voiture 1,20 € client / 1,00 € transporteur
-- ----------------------------------------------------------------------------
-- Déjà appliqué en production par SQL le 20/09/2026. Rejoué ici pour que le
-- dépôt décrive la même base ; sans effet si la grille active est déjà à jour.
do $grille$
declare v_params jsonb; v_version integer;
begin
  select params into v_params from public.pricing_grids where mode = 'plateau' and status = 'active';
  if v_params is null
     or ((v_params -> 'class_rates' -> 'voiture' ->> 'client_eur_per_km')::numeric = 1.20
         and (v_params -> 'class_rates' -> 'voiture' ->> 'partner_eur_per_km')::numeric = 1.00) then
    return;
  end if;
  v_params := jsonb_set(v_params, '{class_rates,voiture}',
    jsonb_build_object('client_eur_per_km', 1.20, 'partner_eur_per_km', 1.00));
  perform secoto_private.validate_grid_params('plateau', v_params);
  select coalesce(max(version), 0) + 1 into v_version from public.pricing_grids where mode = 'plateau';
  update public.pricing_grids set status = 'archived' where mode = 'plateau' and status = 'active';
  insert into public.pricing_grids(mode, version, status, params, source_note, activated_at)
  values ('plateau', v_version, 'active', v_params,
    'Barème plateau du 20/09/2026 — voiture : 1,20 €/km facturé au client, 1,00 €/km versé au transporteur. Moto et utilitaire inchangées.',
    now());
end
$grille$;

-- ----------------------------------------------------------------------------
-- 10. DROITS
-- ----------------------------------------------------------------------------
revoke all on function public.secoto_payouts_claim_due(integer) from public, anon, authenticated;
grant execute on function public.secoto_payouts_claim_due(integer) to service_role;
revoke all on function public.secoto_payout_transfer_result(uuid, boolean, text, text, text) from public, anon, authenticated;
grant execute on function public.secoto_payout_transfer_result(uuid, boolean, text, text, text) to service_role;
revoke all on function public.secoto_admin_mark_payout_paid(uuid, text) from public, anon;
grant execute on function public.secoto_admin_mark_payout_paid(uuid, text) to authenticated, service_role;
revoke all on function public.secoto_admin_partner_payouts(text) from public, anon;
grant execute on function public.secoto_admin_partner_payouts(text) to authenticated, service_role;

-- ----------------------------------------------------------------------------
-- 11. CONTRÔLES
-- ----------------------------------------------------------------------------
do $verif$
begin
  if secoto_private.policy_num('late_cancel_partner_pct', 0) <> 45 then
    raise exception 'Part transporteur en annulation tardive incorrecte.';
  end if;
  if exists (select 1 from public.secoto_feature_flags f where f.key = 'connect_payouts' and f.enabled) then
    raise exception 'connect_payouts ne doit pas être ouvert par la migration.';
  end if;
  if has_function_privilege('authenticated', 'public.secoto_payouts_claim_due(integer)', 'execute') then
    raise exception 'La réservation des versements doit rester réservée au serveur.';
  end if;
end
$verif$;

notify pgrst, 'reload schema';
commit;
