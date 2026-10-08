-- 074 — Plateau et moto : le client paie directement le transporteur.
--
-- SECOTO n'est qu'intermédiaire sur le plateau : l'argent du transport ne doit
-- jamais transiter par son compte. Pour toute NOUVELLE commande plateau ou moto
-- passée quand l'interrupteur « plateau_paiement_direct » est allumé :
--   1. à la réservation, le client valide sa carte sans être débité
--      (SetupIntent Stripe sur le compte SECOTO, aucune somme encaissée) ;
--   2. à l'acceptation, le serveur débite le client SUR LE COMPTE STRIPE DU
--      TRANSPORTEUR (« direct charge ») ; seule la commission SECOTO
--      (application_fee_amount = prix client - paie transporteur) arrive chez
--      SECOTO. Le transporteur n'est confirmé que si ce débit réussit ;
--   3. l'argent reste sur le solde Stripe du transporteur ; SECOTO déclenche
--      son virement bancaire après la livraison (payout, pas de Transfer).
--
-- RÈGLES DE SÉCURITÉ
--   · Migration uniquement additive : colonnes nullables, nouvelles tables,
--     nouvelles fonctions. Les fonctions existantes ne reçoivent que des ajouts
--     ciblés ; si un repère attendu est introuvable, la migration S'ARRÊTE au
--     lieu de modifier quoi que ce soit à l'aveugle.
--   · Interrupteur ÉTEINT par défaut : sans action explicite, rien ne change.
--   · Toute commande et tout paiement antérieurs gardent payment_circuit NULL
--     = ancien circuit, traité par l'ancien code, y compris les versements par
--     Transfer. Les versements par Transfer ignorent les lignes « direct » :
--     aucun double paiement possible.
--   · Convoyage, abonnements, liens de devis : inchangés.

-- ----------------------------------------------------------------------------
-- 0. OUTIL : ajout ciblé dans une fonction existante, avec garde-fou
-- ----------------------------------------------------------------------------
create or replace function secoto_private.mig074_patch(p_fn regprocedure, p_anchor text, p_new text)
returns void language plpgsql volatile security definer set search_path = ''
as $f$
declare v_src text; v_n integer;
begin
  select pg_get_functiondef(p_fn) into v_src;
  -- Déjà appliqué (migration rejouée) : rien à faire.
  if position(p_new in v_src) > 0 then return; end if;
  v_n := (length(v_src) - length(replace(v_src, p_anchor, ''))) / greatest(length(p_anchor), 1);
  if v_n <> 1 then
    raise exception 'Migration 074 arrêtée : repère introuvable ou ambigu dans % (% occurrence(s)). Rien n''a été modifié.', p_fn, v_n;
  end if;
  execute replace(v_src, p_anchor, p_new);
end;
$f$;
revoke all on function secoto_private.mig074_patch(regprocedure, text, text) from public, anon, authenticated;

-- ----------------------------------------------------------------------------
-- 1. INTERRUPTEUR ET RÉGLAGES (éteint par défaut)
-- ----------------------------------------------------------------------------
-- La liste des interrupteurs autorisés est élargie d'une clé (aucune retirée).
alter table public.secoto_feature_flags drop constraint if exists secoto_feature_flags_key_check;
alter table public.secoto_feature_flags add constraint secoto_feature_flags_key_check
  check (key in ('auto_pricing', 'od_payments', 'subscriptions', 'dispatch_notifications', 'live_tracking',
                 'direct_accept', 'connect_payouts', 'plateau_paiement_direct'));
insert into public.secoto_feature_flags(key) values ('plateau_paiement_direct') on conflict (key) do nothing;

update public.app_settings
   set value = coalesce(value, '{}'::jsonb)
     || jsonb_build_object(
          'direct_last_minute_hours', coalesce(value -> 'direct_last_minute_hours', '2'::jsonb),
          'direct_action_wait_minutes', coalesce(value -> 'direct_action_wait_minutes', '120'::jsonb))
 where key = 'dispatch_policy';

-- ----------------------------------------------------------------------------
-- 2. COLONNES (toutes nullables : NULL = ancien circuit)
-- ----------------------------------------------------------------------------
alter table public.transport_orders add column if not exists payment_circuit text;
alter table public.payments add column if not exists payment_circuit text;
alter table public.payments add column if not exists connected_account_id text;
alter table public.payments add column if not exists application_fee_cents integer;
alter table public.payments add column if not exists setup_intent_id text;
alter table public.payments add column if not exists saved_payment_method_id text;
alter table public.payments add column if not exists direct_charge_attempted_at timestamptz;
alter table public.payments add column if not exists direct_action_required_at timestamptz;
alter table public.partner_payouts add column if not exists payment_circuit text;
alter table public.partner_payouts add column if not exists connected_account_id text;

-- Compte de paiement du transporteur : encaissement par carte, mandat de
-- facturation et informations légales de ses factures.
alter table public.accounts add column if not exists stripe_card_payments_enabled boolean;
-- Virements bancaires pilotés par SECOTO (calendrier Stripe « manuel ») : posé
-- par le serveur à l'activation du paiement direct, jamais par l'app.
alter table public.accounts add column if not exists stripe_payouts_manual boolean;
alter table public.accounts add column if not exists billing_mandate_accepted_at timestamptz;
alter table public.accounts add column if not exists billing_mandate_version text;
alter table public.accounts add column if not exists billing_legal_name text;
alter table public.accounts add column if not exists billing_siren text;
alter table public.accounts add column if not exists billing_address text;
alter table public.accounts add column if not exists billing_vat_regime text;
alter table public.accounts add column if not exists billing_vat_number text;

do $c$
begin
  if not exists (select 1 from pg_constraint where conname = 'transport_orders_payment_circuit_check') then
    alter table public.transport_orders add constraint transport_orders_payment_circuit_check
      check (payment_circuit is null or payment_circuit = 'direct');
  end if;
  if not exists (select 1 from pg_constraint where conname = 'payments_payment_circuit_check') then
    alter table public.payments add constraint payments_payment_circuit_check
      check (payment_circuit is null or payment_circuit = 'direct');
  end if;
  if not exists (select 1 from pg_constraint where conname = 'partner_payouts_payment_circuit_check') then
    alter table public.partner_payouts add constraint partner_payouts_payment_circuit_check
      check (payment_circuit is null or payment_circuit = 'direct');
  end if;
  if not exists (select 1 from pg_constraint where conname = 'accounts_billing_vat_regime_check') then
    alter table public.accounts add constraint accounts_billing_vat_regime_check
      check (billing_vat_regime is null or billing_vat_regime in ('franchise', 'assujetti'));
  end if;
end $c$;

-- Seul le serveur écrit l'état Stripe du compte : un transporteur ne peut pas
-- se déclarer « encaissement par carte actif ». (Défense en profondeur : les
-- comptes ne sont de toute façon modifiables que par les fonctions SECOTO.)
create or replace function secoto_private.trg_protect_direct_columns()
returns trigger language plpgsql set search_path = ''
as $f$
begin
  if current_user in ('authenticated', 'anon')
     and (new.stripe_card_payments_enabled is distinct from old.stripe_card_payments_enabled
       or new.stripe_payouts_manual is distinct from old.stripe_payouts_manual) then
    raise exception 'Les informations de paiement Stripe ne se modifient que depuis SECOTO.';
  end if;
  return new;
end;
$f$;
drop trigger if exists trg_secoto_protect_direct_columns on public.accounts;
create trigger trg_secoto_protect_direct_columns
  before update on public.accounts
  for each row execute function secoto_private.trg_protect_direct_columns();

-- ----------------------------------------------------------------------------
-- 3. FACTURES ÉMISES AU NOM DU TRANSPORTEUR ET FACTURES DE COMMISSION
-- ----------------------------------------------------------------------------
create table if not exists public.partner_invoices (
  id            uuid primary key default gen_random_uuid(),
  order_id      uuid not null references public.transport_orders(id),
  partner_id    uuid not null references public.accounts(id),
  client_id     uuid references public.accounts(id),
  kind          text not null check (kind in ('client_on_behalf', 'commission')),
  number        text not null,
  amount_cents  integer not null check (amount_cents >= 0),
  body          text not null,
  issued_at     timestamptz not null default now(),
  unique (order_id, kind)
);
alter table public.partner_invoices enable row level security;
revoke all on table public.partner_invoices from public, anon, authenticated;
grant select on table public.partner_invoices to authenticated;
drop policy if exists partner_invoices_read on public.partner_invoices;
create policy partner_invoices_read on public.partner_invoices for select to authenticated
  using (
    partner_id = auth.uid()
    or (kind = 'client_on_behalf' and client_id = auth.uid())
    or secoto_private.current_is_admin()
  );

-- Numérotation propre à chaque transporteur (une séquence par mandant).
create table if not exists public.partner_invoice_counters (
  partner_id  uuid not null references public.accounts(id),
  year        integer not null,
  last_number integer not null default 0,
  primary key (partner_id, year)
);
alter table public.partner_invoice_counters enable row level security;
revoke all on table public.partner_invoice_counters from public, anon, authenticated;

-- ----------------------------------------------------------------------------
-- 4. LE TRANSPORTEUR PEUT-IL ENCAISSER EN DIRECT ?
-- ----------------------------------------------------------------------------
create or replace function secoto_private.partner_direct_ready(p_partner uuid)
returns boolean language sql stable security definer set search_path = ''
as $f$
  select exists (
    select 1 from public.accounts a
     where a.id = p_partner
       and a.stripe_connect_account_id is not null
       and coalesce(a.stripe_card_payments_enabled, false)
       and coalesce(a.stripe_transfers_enabled, false)
       and coalesce(a.stripe_payouts_manual, false)
       and a.billing_mandate_accepted_at is not null
       and nullif(trim(coalesce(a.billing_legal_name, '')), '') is not null
       and a.billing_siren ~ '^[0-9]{9}$'
       and nullif(trim(coalesce(a.billing_address, '')), '') is not null
       and a.billing_vat_regime is not null
  );
$f$;
revoke all on function secoto_private.partner_direct_ready(uuid) from public, anon, authenticated;

-- État affiché au transporteur dans l'app : ce qui manque, en clair.
create or replace function public.secoto_carrier_direct_status()
returns jsonb language plpgsql stable security definer set search_path = ''
as $f$
declare v_user uuid := secoto_private.assert_authenticated(); a public.accounts%rowtype;
begin
  select * into a from public.accounts x where x.id = v_user;
  if not found or a.role::text <> 'transporter' then
    raise exception 'Réservé aux transporteurs.';
  end if;
  return jsonb_build_object(
    'ready', secoto_private.partner_direct_ready(v_user),
    'stripe_account', a.stripe_connect_account_id is not null,
    'card_payments', coalesce(a.stripe_card_payments_enabled, false),
    'transfers', coalesce(a.stripe_transfers_enabled, false),
    'payouts', coalesce(a.stripe_payouts_enabled, false),
    'payouts_manual', coalesce(a.stripe_payouts_manual, false),
    'mandate_accepted_at', a.billing_mandate_accepted_at,
    'mandate_version', a.billing_mandate_version,
    'billing', jsonb_build_object('legal_name', a.billing_legal_name, 'siren', a.billing_siren,
      'address', a.billing_address, 'vat_regime', a.billing_vat_regime, 'vat_number', a.billing_vat_number));
end;
$f$;
revoke all on function public.secoto_carrier_direct_status() from public, anon;
grant execute on function public.secoto_carrier_direct_status() to authenticated;

-- Acceptation du mandat de facturation, une seule fois, avec les informations
-- légales nécessaires aux factures. La case n'est jamais pré-cochée côté app :
-- l'appel n'existe que si le transporteur l'a cochée.
create or replace function public.secoto_carrier_accept_billing_mandate(
  p_version text, p_legal_name text, p_siren text, p_address text, p_vat_regime text, p_vat_number text)
returns jsonb language plpgsql volatile security definer set search_path = ''
as $f$
declare v_user uuid := secoto_private.assert_authenticated(); v_siren text; v_role text;
begin
  select a.role::text into v_role from public.accounts a where a.id = v_user;
  if v_role is distinct from 'transporter' then raise exception 'Réservé aux transporteurs.'; end if;
  if nullif(trim(coalesce(p_version, '')), '') is null then raise exception 'Version des conditions manquante.'; end if;
  if nullif(trim(coalesce(p_legal_name, '')), '') is null then raise exception 'Indiquez le nom de votre entreprise.'; end if;
  v_siren := regexp_replace(coalesce(p_siren, ''), '\s', '', 'g');
  if v_siren !~ '^[0-9]{9}$' then raise exception 'Le SIREN doit comporter 9 chiffres.'; end if;
  if nullif(trim(coalesce(p_address, '')), '') is null then raise exception 'Indiquez l''adresse de votre entreprise.'; end if;
  if p_vat_regime not in ('franchise', 'assujetti') then raise exception 'Précisez votre régime de TVA.'; end if;
  if p_vat_regime = 'assujetti' and coalesce(p_vat_number, '') !~* '^FR[0-9A-Z]{2}[0-9]{9}$' then
    raise exception 'Numéro de TVA intracommunautaire invalide (format FR + 11 caractères).';
  end if;

  update public.accounts
     set billing_mandate_accepted_at = now(), billing_mandate_version = left(trim(p_version), 40),
         billing_legal_name = left(trim(p_legal_name), 200), billing_siren = v_siren,
         billing_address = left(trim(p_address), 400), billing_vat_regime = p_vat_regime,
         billing_vat_number = case when p_vat_regime = 'assujetti' then upper(trim(p_vat_number)) end
   where id = v_user;
  perform secoto_private.audit('billing_mandate_accepted', 'account', v_user::text,
    jsonb_build_object('version', p_version, 'vat_regime', p_vat_regime));
  return public.secoto_carrier_direct_status();
end;
$f$;
revoke all on function public.secoto_carrier_accept_billing_mandate(text, text, text, text, text, text) from public, anon;
grant execute on function public.secoto_carrier_accept_billing_mandate(text, text, text, text, text, text) to authenticated;

-- ----------------------------------------------------------------------------
-- 5. RÉSERVATION : la commande plateau naît dans le circuit direct
-- ----------------------------------------------------------------------------
select secoto_private.mig074_patch(
  'public.secoto_od_book_quote(uuid, boolean, uuid)'::regprocedure,
  '    update public.transport_orders set payment_id = v_payment.id where id = v_order.id returning * into v_order;',
  '    update public.transport_orders set payment_id = v_payment.id where id = v_order.id returning * into v_order;
    -- 074 : plateau et moto, interrupteur allumé -> paiement direct au transporteur.
    if v_order.mode = ''plateau'' and secoto_private.flag(''plateau_paiement_direct'') then
      update public.payments set payment_circuit = ''direct'', capture_method = ''manual'', updated_at = now()
       where id = v_payment.id returning * into v_payment;
      update public.transport_orders set payment_circuit = ''direct'', payment_strategy = ''authorize_then_capture'', updated_at = now()
       where id = v_order.id returning * into v_order;
    end if;');

select secoto_private.mig074_patch(
  'secoto_private.order_client_json(public.transport_orders)'::regprocedure,
  '''status'', o.status, ''payment_strategy'', o.payment_strategy,',
  '''status'', o.status, ''payment_strategy'', o.payment_strategy, ''payment_circuit'', o.payment_circuit, ''payment_action_required'', (p.direct_action_required_at is not null and o.status = ''partner_locked''),');

-- Carte validée (SetupIntent réussi) : la demande part aux transporteurs.
-- Appelée par le webhook Stripe, jamais par l'application.
create or replace function public.secoto_direct_card_saved(
  p_payment_id uuid, p_event_id text, p_setup_intent_id text, p_payment_method_id text)
returns jsonb language plpgsql volatile security definer set search_path = ''
as $f$
declare
  v_payment public.payments%rowtype;
  v_order public.transport_orders%rowtype;
  v_effect text := 'none';
begin
  select * into v_payment from public.payments p where p.id = p_payment_id for update;
  if not found then return jsonb_build_object('skipped', true, 'reason', 'unknown_payment'); end if;
  if v_payment.payment_circuit is distinct from 'direct' then
    return jsonb_build_object('skipped', true, 'reason', 'not_direct');
  end if;
  if p_event_id is not null and exists (select 1 from public.payment_events e where e.provider_event_id = p_event_id) then
    return jsonb_build_object('skipped', true, 'reason', 'event_already_processed');
  end if;
  if nullif(p_payment_method_id, '') is null then
    return jsonb_build_object('skipped', true, 'reason', 'no_payment_method');
  end if;

  if v_payment.status in ('pending', 'processing', 'failed', 'capture_failed') then
    update public.payments
       set status = 'requires_capture', authorized_at = coalesce(authorized_at, now()),
           setup_intent_id = coalesce(p_setup_intent_id, setup_intent_id),
           saved_payment_method_id = p_payment_method_id,
           direct_action_required_at = null, last_error = null,
           last_event_at = now(), updated_at = now()
     where id = p_payment_id returning * into v_payment;
  elsif v_payment.status = 'requires_capture' then
    -- Carte remplacée avant toute acceptation : on garde la plus récente.
    update public.payments set saved_payment_method_id = p_payment_method_id,
           setup_intent_id = coalesce(p_setup_intent_id, setup_intent_id), last_event_at = now(), updated_at = now()
     where id = p_payment_id returning * into v_payment;
  else
    return jsonb_build_object('skipped', true, 'reason', 'status_' || v_payment.status);
  end if;

  insert into public.payment_events(payment_id, event_type, provider_event_id, payload)
  values (p_payment_id, 'setup_intent.succeeded', p_event_id,
          jsonb_build_object('setup_intent', p_setup_intent_id, 'status', v_payment.status))
  on conflict (provider_event_id) where provider_event_id is not null do nothing;

  if v_payment.order_id is not null then
    select * into v_order from public.transport_orders o where o.id = v_payment.order_id for update;
    if v_order.status = 'awaiting_payment' then
      perform secoto_private.od_open_dispatch(v_order.id);
      v_effect := 'dispatch_opened';
      perform secoto_private.notify_event(v_order.account_id, 'payment', 'Carte validée',
        format('Commande %s : votre carte est validée, rien n''a été débité. Vous serez débité au moment où un transporteur accepte la mission, directement au nom de ce transporteur.', v_order.public_ref),
        null, 'courses', 'od-card-saved:' || v_order.id::text, v_order.id);
    end if;
  end if;
  return jsonb_build_object('payment_id', p_payment_id, 'status', v_payment.status, 'effect', v_effect);
end;
$f$;
revoke all on function public.secoto_direct_card_saved(uuid, text, text, text) from public, anon, authenticated;
grant execute on function public.secoto_direct_card_saved(uuid, text, text, text) to service_role;

-- ----------------------------------------------------------------------------
-- 6. ACCEPTATION : compte de paiement exigé, puis débit chez le transporteur
-- ----------------------------------------------------------------------------
select secoto_private.mig074_patch(
  'secoto_private.od_try_accept(uuid, uuid, uuid)'::regprocedure,
  '    return jsonb_build_object(''result'', ''not_eligible'');',
  '    return jsonb_build_object(''result'', ''not_eligible'');
  end if;
  -- 074 : en paiement direct, le transporteur doit pouvoir encaisser lui-même.
  if v_order.payment_circuit = ''direct'' and not secoto_private.partner_direct_ready(p_partner) then
    return jsonb_build_object(''result'', ''payment_account_required'');');

select secoto_private.mig074_patch(
  'public.secoto_admin_od_lock_for_partner(uuid, uuid)'::regprocedure,
  '  insert into public.partner_dispatch_preferences(account_id) values (p_partner_id) on conflict do nothing;',
  '  if v_order.payment_circuit = ''direct'' and not secoto_private.partner_direct_ready(p_partner_id) then
    raise exception ''Ce transporteur n''''a pas encore activé son compte de paiement : impossible de lui attribuer une commande en paiement direct.'';
  end if;
  insert into public.partner_dispatch_preferences(account_id) values (p_partner_id) on conflict do nothing;');

-- Tout ce qu'il faut au serveur pour débiter le client chez le transporteur.
-- Les montants viennent de la commande, jamais de l'appelant.
create or replace function public.secoto_direct_charge_context(p_order_id uuid)
returns jsonb language plpgsql volatile security definer set search_path = ''
as $f$
declare
  v_order public.transport_orders%rowtype;
  v_payment public.payments%rowtype;
  v_partner public.accounts%rowtype;
  v_customer text;
  v_fee integer;
  v_partner_id uuid;
begin
  select * into v_order from public.transport_orders o where o.id = p_order_id for update;
  if not found then return jsonb_build_object('error', 'order_not_found'); end if;
  if v_order.payment_circuit is distinct from 'direct' then return jsonb_build_object('error', 'not_direct'); end if;
  select * into v_payment from public.payments p where p.id = v_order.payment_id for update;
  v_partner_id := coalesce(v_order.lock_partner_id, v_order.assigned_partner_id);
  select * into v_partner from public.accounts a where a.id = v_partner_id;
  select a.stripe_customer_id into v_customer from public.accounts a where a.id = v_payment.account_id;

  v_fee := v_payment.amount_cents - v_order.partner_pay_cents;
  if v_fee < 0 or v_fee >= v_payment.amount_cents then
    return jsonb_build_object('error', 'invalid_fee');
  end if;

  update public.payments
     set connected_account_id = coalesce(connected_account_id, v_partner.stripe_connect_account_id),
         application_fee_cents = v_fee,
         direct_charge_attempted_at = coalesce(direct_charge_attempted_at, now()),
         updated_at = now()
   where id = v_payment.id returning * into v_payment;

  return jsonb_build_object(
    'order_id', v_order.id, 'order_status', v_order.status, 'public_ref', v_order.public_ref,
    'payment_id', v_payment.id, 'payment_status', v_payment.status,
    'amount_cents', v_payment.amount_cents, 'currency', coalesce(v_payment.currency, 'eur'),
    'application_fee_cents', v_fee,
    'partner_id', v_partner_id,
    'partner_ready', secoto_private.partner_direct_ready(v_partner_id),
    'connected_account_id', v_payment.connected_account_id,
    'customer_id', v_customer,
    'payment_method_id', v_payment.saved_payment_method_id,
    'provider_intent_id', v_payment.provider_intent_id,
    'mode', v_order.mode,
    'lock_expires_at', v_order.lock_expires_at,
    'action_required_at', v_payment.direct_action_required_at);
end;
$f$;
revoke all on function public.secoto_direct_charge_context(uuid) from public, anon, authenticated;
grant execute on function public.secoto_direct_charge_context(uuid) to service_role;

-- La banque du client exige une validation (3D Secure) : on garde la mission
-- réservée au transporteur le temps que le client valide lui-même.
create or replace function public.secoto_direct_charge_needs_action(p_order_id uuid, p_intent_id text)
returns jsonb language plpgsql volatile security definer set search_path = ''
as $f$
declare v_order public.transport_orders%rowtype; v_wait integer;
begin
  select * into v_order from public.transport_orders o where o.id = p_order_id for update;
  if not found or v_order.status <> 'partner_locked' or v_order.payment_circuit is distinct from 'direct' then
    return jsonb_build_object('result', 'ignored');
  end if;
  v_wait := secoto_private.policy_num('direct_action_wait_minutes', 120)::int;
  update public.transport_orders set lock_expires_at = now() + make_interval(mins => v_wait), updated_at = now()
   where id = p_order_id;
  update public.payments set direct_action_required_at = coalesce(direct_action_required_at, now()),
         provider_intent_id = coalesce(p_intent_id, provider_intent_id),
         last_error = 'Validation bancaire demandée au client', updated_at = now()
   where id = v_order.payment_id;
  perform secoto_private.notify_event(v_order.account_id, 'payment_failed', 'Validez votre paiement',
    format('Commande %s : un transporteur a accepté votre mission. Votre banque demande une validation : ouvrez la commande et validez le paiement dans les %s minutes pour confirmer le transport.', v_order.public_ref, v_wait),
    null, 'courses', 'od-direct-action:' || p_order_id::text, p_order_id);
  perform secoto_private.notify_event(v_order.lock_partner_id, 'order_update', 'Mission en attente de paiement',
    'Le client doit valider son paiement auprès de sa banque. La mission vous reste réservée en attendant.',
    null, 'offre', 'od-direct-action-partner:' || p_order_id::text, p_order_id);
  perform secoto_private.audit('direct_charge_needs_action', 'transport_order', p_order_id::text,
    jsonb_build_object('intent', p_intent_id, 'wait_minutes', v_wait));
  return jsonb_build_object('result', 'needs_action', 'wait_minutes', v_wait);
end;
$f$;
revoke all on function public.secoto_direct_charge_needs_action(uuid, text) from public, anon, authenticated;
grant execute on function public.secoto_direct_charge_needs_action(uuid, text) to service_role;

-- ----------------------------------------------------------------------------
-- 7. MAINTENANCE : le serveur sait de quel circuit relève chaque action
-- ----------------------------------------------------------------------------
select secoto_private.mig074_patch(
  'public.secoto_od_maintenance_tick()'::regprocedure,
  'jsonb_build_object(''order_id'', o.id, ''payment_id'', o.payment_id, ''intent_id'', p.provider_intent_id, ''funding'', o.funding)',
  'jsonb_build_object(''order_id'', o.id, ''payment_id'', o.payment_id, ''intent_id'', p.provider_intent_id, ''funding'', o.funding, ''circuit'', o.payment_circuit)');

select secoto_private.mig074_patch(
  'public.secoto_od_maintenance_tick()'::regprocedure,
  '''action'', case when p.status = ''refund_pending'' then ''refund'' else ''cancel'' end,',
  '''action'', case when p.status = ''refund_pending'' then ''refund'' else ''cancel'' end,
      ''circuit'', p.payment_circuit, ''connected_account_id'', p.connected_account_id,');

-- Sans transporteur, un client du circuit direct n'a jamais été débité.
select secoto_private.mig074_patch(
  'public.secoto_od_maintenance_tick()'::regprocedure,
  'for r in select o.id, o.dispatch_round, o.pickup_at, o.account_id, o.public_ref from public.transport_orders o',
  'for r in select o.id, o.dispatch_round, o.pickup_at, o.account_id, o.public_ref, o.payment_circuit from public.transport_orders o');
select secoto_private.mig074_patch(
  'public.secoto_od_maintenance_tick()'::regprocedure,
  'format(''Commande %s : aucun transporteur ne s''''est rendu disponible dans les 48 heures. Vous êtes remboursé intégralement sous 24 heures.'', r.public_ref)',
  'format(case when r.payment_circuit = ''direct''
          then ''Commande %s : aucun transporteur ne s''''est rendu disponible. Votre carte n''''a pas été débitée.''
          else ''Commande %s : aucun transporteur ne s''''est rendu disponible dans les 48 heures. Vous êtes remboursé intégralement sous 24 heures.'' end, r.public_ref)');

-- ----------------------------------------------------------------------------
-- 8. ANNULATION PAR LE CLIENT (circuit direct)
--    > 24 h avant l'enlèvement : 100 % remboursés
--    24 h à 2 h avant          : 50 % remboursés
--    < 2 h avant               : rien n'est remboursé (frais de dernière minute)
--    Ce qui est retenu est partagé au prorata : Stripe rend la commission dans
--    la même proportion que le remboursement (refund_application_fee).
--    Client jamais débité (aucun transporteur n'a accepté) : annulation libre.
-- ----------------------------------------------------------------------------
create or replace function secoto_private.od_direct_cancel(p_order_id uuid)
returns jsonb language plpgsql volatile security definer set search_path = ''
as $f$
declare
  v_order public.transport_orders%rowtype;
  v_payment public.payments%rowtype;
  v_free_h numeric := secoto_private.policy_num('free_cancel_hours_before_pickup', 24);
  v_last_h numeric := secoto_private.policy_num('direct_last_minute_hours', 2);
  v_late_pct numeric := secoto_private.policy_num('late_cancel_retained_pct', 50);
  v_pct numeric := 0;
  v_refund integer;
  v_partner_part integer := 0;
  v_reason text := 'annulation_client';
  v_charged boolean;
begin
  select * into v_order from public.transport_orders o where o.id = p_order_id for update;
  select * into v_payment from public.payments p where p.id = v_order.payment_id;
  v_charged := coalesce(v_payment.status, '') = 'paid';

  if v_charged then
    if v_order.pickup_at - make_interval(hours => v_last_h::int) <= now() then
      v_pct := 100; v_reason := 'annulation_client_derniere_minute';
    elsif v_order.pickup_at - make_interval(hours => v_free_h::int) <= now() then
      v_pct := v_late_pct; v_reason := 'annulation_client_tardive';
    end if;
    v_refund := v_order.client_price_cents - round(v_order.client_price_cents * v_pct / 100)::int;
  else
    v_refund := null;
  end if;

  perform secoto_private.od_stop_order_amount(p_order_id, 'cancelled', v_reason, case when v_charged then v_refund else null end);

  -- Part retenue du transporteur : elle est déjà sur SON solde Stripe ; on
  -- programme seulement son virement bancaire (aucun Transfer depuis SECOTO).
  if v_charged and v_pct > 0 and v_order.assigned_partner_id is not null and v_order.mission_id is not null then
    v_partner_part := round(v_order.partner_pay_cents * v_pct / 100)::int;
    if v_partner_part > 0 then
      insert into public.partner_payouts(mission_id, order_id, partner_id, amount_cents, due_at, mode, kind, payment_circuit, connected_account_id)
      values (v_order.mission_id, v_order.id, v_order.assigned_partner_id, v_partner_part,
              now() + make_interval(hours => secoto_private.policy_num('payout_delay_hours', 48)::int),
              v_order.mode, 'late_cancel', 'direct', v_payment.connected_account_id)
      on conflict (mission_id) do update
         set amount_cents = excluded.amount_cents, status = 'to_pay', kind = 'late_cancel', due_at = excluded.due_at,
             order_id = excluded.order_id, payment_circuit = 'direct', connected_account_id = excluded.connected_account_id
       where public.partner_payouts.status = 'cancelled';
    end if;
  end if;

  if v_order.assigned_partner_id is not null then
    perform secoto_private.notify_event(v_order.assigned_partner_id, 'cancellation', 'Mission annulée',
      case when v_partner_part > 0
        then format('Commande %s annulée par le client. Frais d''annulation : %s € vous restent acquis, virés sur votre compte bancaire.',
               v_order.public_ref, replace(to_char(v_partner_part / 100.0, 'FM999990D00'), '.', ','))
        else format('Commande %s annulée par le client.', v_order.public_ref) end,
      v_order.mission_id, 'assigned', 'od-cancel-partner:' || p_order_id::text, p_order_id);
    perform secoto_private.notify_admins_event('cancellation', 'Annulation après attribution',
      format('%s · %s %% retenus (paiement direct)', v_order.public_ref, v_pct::int),
      'requests', 'od-cancel-admin:' || p_order_id::text, p_order_id);
  end if;

  perform secoto_private.notify_event(v_order.account_id, 'order_update', 'Commande annulée',
    case
      when not v_charged then format('Commande %s annulée. Votre carte n''a pas été débitée.', v_order.public_ref)
      when v_pct = 0 then format('Commande %s annulée. Vous êtes remboursé intégralement.', v_order.public_ref)
      when v_pct >= 100 then format('Commande %s annulée moins de %s h avant l''enlèvement : les frais d''annulation de dernière minute s''appliquent, aucun remboursement.', v_order.public_ref, v_last_h::int)
      else format('Commande %s annulée moins de %s h avant l''enlèvement : %s %% retenus, %s € remboursés.',
             v_order.public_ref, v_free_h::int, v_pct::int, replace(to_char(coalesce(v_refund, 0) / 100.0, 'FM999990D00'), '.', ','))
    end,
    null, 'courses', 'od-cancel-client:' || p_order_id::text, p_order_id);

  perform secoto_private.audit('order_cancelled_by_client', 'transport_order', p_order_id::text,
    jsonb_build_object('circuit', 'direct', 'charged', v_charged, 'retained_pct', v_pct,
                       'refund_cents', v_refund, 'partner_retained_cents', v_partner_part));
  select * into v_order from public.transport_orders o where o.id = p_order_id;
  return secoto_private.order_client_json(v_order);
end;
$f$;
revoke all on function secoto_private.od_direct_cancel(uuid) from public, anon, authenticated;

select secoto_private.mig074_patch(
  'public.secoto_od_cancel_order(uuid, uuid)'::regprocedure,
  '  v_late := v_order.pickup_at - make_interval(hours => v_free_h::int) <= now();',
  '  -- 074 : paiement direct, barème 100 / 50 / 0 et partage au prorata.
  if v_order.payment_circuit = ''direct'' then
    return secoto_private.finish_operation(''od_cancel_order'', p_idempotency_key, secoto_private.od_direct_cancel(p_order_id));
  end if;
  v_late := v_order.pickup_at - make_interval(hours => v_free_h::int) <= now();');

-- Aperçu affiché AVANT de confirmer l'annulation : mêmes règles, mêmes chiffres.
create or replace function secoto_private.od_direct_cancel_preview(p_order public.transport_orders)
returns jsonb language plpgsql stable security definer set search_path = ''
as $f$
declare
  v_free_h numeric := secoto_private.policy_num('free_cancel_hours_before_pickup', 24);
  v_last_h numeric := secoto_private.policy_num('direct_last_minute_hours', 2);
  v_late_pct numeric := secoto_private.policy_num('late_cancel_retained_pct', 50);
  v_charged boolean;
  v_pct numeric := 0;
  v_last boolean := false;
begin
  select coalesce(p.status, '') = 'paid' into v_charged from public.payments p where p.id = p_order.payment_id;
  v_charged := coalesce(v_charged, false);
  if v_charged then
    if p_order.pickup_at - make_interval(hours => v_last_h::int) <= now() then v_pct := 100; v_last := true;
    elsif p_order.pickup_at - make_interval(hours => v_free_h::int) <= now() then v_pct := v_late_pct;
    end if;
  end if;
  return jsonb_build_object(
    'cancellable', p_order.status not in ('delivered', 'cancelled', 'no_partner'),
    'circuit', 'direct',
    'charged', v_charged,
    'late', v_pct > 0,
    'last_minute', v_last,
    'free_until', p_order.pickup_at - make_interval(hours => v_free_h::int),
    'last_minute_from', p_order.pickup_at - make_interval(hours => v_last_h::int),
    'retained_pct', v_pct,
    'refund_cents', case when v_charged then p_order.client_price_cents - round(p_order.client_price_cents * v_pct / 100)::int else 0 end);
end;
$f$;
revoke all on function secoto_private.od_direct_cancel_preview(public.transport_orders) from public, anon, authenticated;

select secoto_private.mig074_patch(
  'public.secoto_od_cancel_quote_preview(uuid)'::regprocedure,
  '  v_late := v_order.pickup_at - make_interval(hours => v_free_h::int) <= now();',
  '  if v_order.payment_circuit = ''direct'' then
    return secoto_private.od_direct_cancel_preview(v_order);
  end if;
  v_late := v_order.pickup_at - make_interval(hours => v_free_h::int) <= now();');

-- ----------------------------------------------------------------------------
-- 9. VERSEMENTS : jamais de Transfer pour une course encaissée en direct
-- ----------------------------------------------------------------------------
create or replace function secoto_private.trg_payout_circuit()
returns trigger language plpgsql security definer set search_path = ''
as $f$
begin
  if new.payment_circuit is null and new.order_id is not null then
    select o.payment_circuit into new.payment_circuit from public.transport_orders o where o.id = new.order_id;
  end if;
  if new.payment_circuit = 'direct' and new.connected_account_id is null then
    select p.connected_account_id into new.connected_account_id
      from public.transport_orders o join public.payments p on p.id = o.payment_id
     where o.id = new.order_id;
  end if;
  return new;
end;
$f$;
drop trigger if exists trg_secoto_payout_circuit on public.partner_payouts;
create trigger trg_secoto_payout_circuit
  before insert on public.partner_payouts
  for each row execute function secoto_private.trg_payout_circuit();

select secoto_private.mig074_patch(
  'public.secoto_payouts_claim_due(integer)'::regprocedure,
  '       and pp.amount_cents > 0',
  '       and pp.amount_cents > 0
       -- 074 : paiement direct -> l''argent est déjà chez le transporteur.
       and coalesce(pp.payment_circuit, '''') <> ''direct''');

-- Virements bancaires du circuit direct : depuis le solde Stripe DU
-- TRANSPORTEUR vers sa banque, après la livraison. Même réservation atomique
-- et même suivi des échecs que les versements existants.
create or replace function public.secoto_direct_payouts_claim_due(p_limit integer default 20)
returns jsonb language plpgsql volatile security definer set search_path = ''
as $f$
declare v_rows jsonb;
begin
  if not secoto_private.flag('connect_payouts') then return '[]'::jsonb; end if;
  with due as (
    select pp.id
      from public.partner_payouts pp
      join public.transport_orders o on o.id = pp.order_id
      join public.payments p on p.id = o.payment_id
     where pp.payment_circuit = 'direct'
       and (
             (pp.status = 'to_pay' and pp.due_at <= now() and coalesce(pp.next_retry_at, now()) <= now())
          or (pp.status = 'processing' and pp.processing_at < now() - interval '15 minutes')
           )
       and pp.amount_cents > 0
       and pp.connected_account_id is not null
       and p.status in ('paid', 'refunded', 'refund_pending')
       and coalesce(p.dispute_status, '') <> 'open'
       and (pp.kind = 'late_cancel' or o.status = 'delivered')
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
      'connected_account_id', r.connected_account_id,
      'order_id', r.order_id, 'mission_id', r.mission_id, 'attempt', r.attempt_count)), '[]'::jsonb)
    into v_rows
    from reserve r;
  return v_rows;
end;
$f$;
revoke all on function public.secoto_direct_payouts_claim_due(integer) from public, anon, authenticated;
grant execute on function public.secoto_direct_payouts_claim_due(integer) to service_role;

-- Comptes passés en virement « manuel » : un versement de l'ANCIEN circuit
-- (Transfer, par exemple une course payée avant la mise en ligne, ou après un
-- retour arrière) arrive sur le solde du transporteur, puis SECOTO déclenche
-- aussitôt son virement bancaire. Les comptes non concernés (convoyeurs,
-- transporteurs n'ayant pas activé le paiement direct) restent sur le
-- virement automatique de Stripe : pour eux, rien ne change.
create table if not exists public.connect_bank_payouts (
  id                   uuid primary key default gen_random_uuid(),
  source_payout_id     uuid not null unique references public.partner_payouts(id),
  partner_id           uuid not null references public.accounts(id),
  connected_account_id text not null,
  amount_cents         integer not null check (amount_cents > 0),
  status               text not null default 'to_pay' check (status in ('to_pay', 'processing', 'paid', 'failed')),
  attempt_count        integer not null default 0,
  next_retry_at        timestamptz,
  processing_at        timestamptz,
  stripe_payout_id     text,
  last_error           text,
  created_at           timestamptz not null default now(),
  paid_at              timestamptz
);
alter table public.connect_bank_payouts enable row level security;
revoke all on table public.connect_bank_payouts from public, anon, authenticated;

select secoto_private.mig074_patch(
  'public.secoto_payout_transfer_result(uuid, boolean, text, text, text)'::regprocedure,
  '    perform secoto_private.audit(''payout_paid_connect'', ''partner_payout'', p_payout_id::text,',
  '    -- 074 : compte en virement manuel -> SECOTO déclenche le virement bancaire du Transfer reçu.
    if v.payment_circuit is distinct from ''direct'' then
      insert into public.connect_bank_payouts(source_payout_id, partner_id, connected_account_id, amount_cents)
      select v.id, a.id, a.stripe_connect_account_id, v.amount_cents
        from public.accounts a
       where a.id = v.partner_id and coalesce(a.stripe_payouts_manual, false)
         and a.stripe_connect_account_id is not null and v.amount_cents > 0
      on conflict (source_payout_id) do nothing;
    end if;
    perform secoto_private.audit(''payout_paid_connect'', ''partner_payout'', p_payout_id::text,');

create or replace function public.secoto_bank_payouts_claim_due(p_limit integer default 20)
returns jsonb language plpgsql volatile security definer set search_path = ''
as $f$
declare v_rows jsonb;
begin
  with due as (
    select b.id from public.connect_bank_payouts b
     where (b.status = 'to_pay' and coalesce(b.next_retry_at, now()) <= now())
        or (b.status = 'processing' and b.processing_at < now() - interval '15 minutes')
     order by b.created_at
     limit greatest(1, least(coalesce(p_limit, 20), 100))
     for update skip locked
  ), reserve as (
    update public.connect_bank_payouts b
       set status = 'processing', processing_at = now(), attempt_count = b.attempt_count + 1
      from due where b.id = due.id
    returning b.*
  )
  select coalesce(jsonb_agg(jsonb_build_object('bank_payout_id', r.id, 'amount_cents', r.amount_cents,
           'connected_account_id', r.connected_account_id, 'attempt', r.attempt_count)), '[]'::jsonb)
    into v_rows from reserve r;
  return v_rows;
end;
$f$;
revoke all on function public.secoto_bank_payouts_claim_due(integer) from public, anon, authenticated;
grant execute on function public.secoto_bank_payouts_claim_due(integer) to service_role;

create or replace function public.secoto_bank_payout_result(p_id uuid, p_success boolean, p_stripe_payout_id text, p_error text)
returns jsonb language plpgsql volatile security definer set search_path = ''
as $f$
declare v public.connect_bank_payouts%rowtype;
begin
  select * into v from public.connect_bank_payouts b where b.id = p_id for update;
  if not found then return jsonb_build_object('result', 'unknown'); end if;
  if v.status = 'paid' then return jsonb_build_object('result', 'already_paid'); end if;
  if p_success then
    update public.connect_bank_payouts set status = 'paid', paid_at = now(), stripe_payout_id = p_stripe_payout_id,
           processing_at = null, last_error = null where id = p_id;
    return jsonb_build_object('result', 'paid');
  end if;
  -- Fonds pas encore disponibles chez Stripe : on réessaie toutes les heures,
  -- pendant dix jours, puis on prévient l'administrateur.
  if v.created_at < now() - interval '10 days' then
    update public.connect_bank_payouts set status = 'failed', processing_at = null, last_error = left(coalesce(p_error, ''), 500) where id = p_id;
    perform secoto_private.notify_admins_event('payment', 'Virement bancaire transporteur bloqué',
      format('%s € attendent sur le compte Stripe %s depuis plus de dix jours.', to_char(v.amount_cents / 100.0, 'FM999990D00'), v.connected_account_id),
      'paiement', 'bank-payout-failed:' || p_id::text, p_id);
    return jsonb_build_object('result', 'failed');
  end if;
  update public.connect_bank_payouts set status = 'to_pay', processing_at = null, last_error = left(coalesce(p_error, ''), 500),
         next_retry_at = now() + interval '1 hour' where id = p_id;
  return jsonb_build_object('result', 'retry');
end;
$f$;
revoke all on function public.secoto_bank_payout_result(uuid, boolean, text, text) from public, anon, authenticated;
grant execute on function public.secoto_bank_payout_result(uuid, boolean, text, text) to service_role;

-- ----------------------------------------------------------------------------
-- 10. FACTURES DU CIRCUIT DIRECT
--     · au client : émise par SECOTO au nom et pour le compte du transporteur
--       (mandat de facturation accepté par le transporteur) ;
--     · au transporteur : facture SECOTO de frais de mise en relation.
-- ----------------------------------------------------------------------------
create or replace function secoto_private.od_issue_direct_invoices(p_order_id uuid)
returns void language plpgsql volatile security definer set search_path = ''
as $f$
declare
  v_order public.transport_orders%rowtype;
  v_quote public.transport_quotes%rowtype;
  v_payment public.payments%rowtype;
  v_partner public.accounts%rowtype;
  v_client public.accounts%rowtype;
  v_partner_id uuid;
  v_year integer := extract(year from now() at time zone 'Europe/Paris')::int;
  v_n integer;
  v_num text;
  v_fac text;
  v_fee integer;
  v_vat_line text;
  v_body text;
  v_body_fee text;
begin
  select * into v_order from public.transport_orders o where o.id = p_order_id for update;
  if not found or v_order.invoice_number is not null then return; end if;
  select * into v_quote from public.transport_quotes q where q.id = v_order.quote_id;
  select * into v_payment from public.payments p where p.id = v_order.payment_id;
  v_partner_id := coalesce(v_order.assigned_partner_id, v_order.lock_partner_id);
  select * into v_partner from public.accounts a where a.id = v_partner_id;
  select * into v_client from public.accounts a where a.id = v_order.account_id;
  if v_partner_id is null then return; end if;
  v_fee := coalesce(v_payment.application_fee_cents, v_order.client_price_cents - v_order.partner_pay_cents);

  insert into public.partner_invoice_counters(partner_id, year, last_number) values (v_partner_id, v_year, 1)
  on conflict (partner_id, year) do update set last_number = public.partner_invoice_counters.last_number + 1
  returning last_number into v_n;
  v_num := 'TR' || v_year || '-' || lpad(v_n::text, 4, '0');

  -- Mention TVA selon le régime déclaré par le transporteur (à valider par
  -- l'expert-comptable avant activation).
  v_vat_line := case
    when v_partner.billing_vat_regime = 'assujetti' then
      'Montant TTC. TVA (20 %) incluse : ' || to_char(round(v_order.client_price_cents - v_order.client_price_cents / 1.2) / 100.0, 'FM999990D00') || ' EUR'
      || ' - TVA intracommunautaire ' || coalesce(v_partner.billing_vat_number, '')
    else 'TVA non applicable, article 293 B du CGI.' end;

  v_body :=
    'Facture ' || v_num || E'\n' ||
    'Etablie par SECOTO au nom et pour le compte de ' || coalesce(v_partner.billing_legal_name, coalesce(v_partner.company_name, v_partner.full_name)) || E'\n' ||
    'SIREN ' || coalesce(v_partner.billing_siren, '') || ' - ' || coalesce(v_partner.billing_address, '') || E'\n\n' ||
    'Client : ' || coalesce(v_client.company_name, v_client.full_name, '') || E'\n' ||
    'Commande ' || v_order.public_ref || E'\n\n' ||
    'Prestation : transport de vehicule sur camion plateau' || E'\n' ||
    'Vehicule : ' || coalesce(nullif(v_quote.vehicle ->> 'model', ''), 'non precise') || E'\n' ||
    'Enlevement : ' || coalesce(v_quote.pickup ->> 'label', '') || E'\n' ||
    'Livraison : ' || coalesce(v_quote.delivery ->> 'label', '') || E'\n' ||
    'Date de prise en charge : ' || to_char(v_order.pickup_at at time zone 'Europe/Paris', 'DD/MM/YYYY') || E'\n\n' ||
    'Total paye : ' || to_char(v_order.client_price_cents / 100.0, 'FM999990D00') || ' EUR' || E'\n' ||
    v_vat_line || E'\n\n' ||
    'Paiement encaisse par ' || coalesce(v_partner.billing_legal_name, 'le transporteur') || ', via SECOTO (mise en relation).' || E'\n' ||
    'Annulation : remboursement integral plus de 24 h avant l''enlevement ; 50 % entre 24 h et 2 h ; aucun remboursement a moins de 2 h.';

  insert into public.partner_invoices(order_id, partner_id, client_id, kind, number, amount_cents, body)
  values (p_order_id, v_partner_id, v_order.account_id, 'client_on_behalf', v_num, v_order.client_price_cents, v_body)
  on conflict (order_id, kind) do nothing;

  update public.transport_orders set invoice_number = v_num, invoiced_at = now(), updated_at = now() where id = p_order_id;

  perform secoto_private.queue_email(v_order.account_id,
    'SECOTO - Facture ' || v_num || ' - commande ' || v_order.public_ref, v_body, v_order.mission_id, 'od-direct-invoice:' || p_order_id::text);
  perform secoto_private.queue_email(v_partner_id,
    'SECOTO - Copie de la facture ' || v_num || ' emise en votre nom - ' || v_order.public_ref, v_body, v_order.mission_id, 'od-direct-invoice-copy:' || p_order_id::text);

  -- Facture de commission SECOTO au transporteur (prélevée à la source).
  if v_fee > 0 then
    v_fac := secoto_private.next_doc_number('FAC');
    v_body_fee :=
      'Facture ' || v_fac || E'\n' ||
      'SECOTO - SIREN 951 857 531' || E'\n\n' ||
      'Destinataire : ' || coalesce(v_partner.billing_legal_name, coalesce(v_partner.company_name, v_partner.full_name)) ||
        ' - SIREN ' || coalesce(v_partner.billing_siren, '') || E'\n' ||
      'Objet : frais de mise en relation - commande ' || v_order.public_ref || E'\n\n' ||
      'Montant : ' || to_char(v_fee / 100.0, 'FM999990D00') || ' EUR' || E'\n' ||
      secoto_private.policy_text('tva', 'TVA non applicable, article 293 B du CGI.') || E'\n\n' ||
      'Montant preleve automatiquement par Stripe sur le paiement du client. Aucune somme ne reste a regler.';
    insert into public.partner_invoices(order_id, partner_id, client_id, kind, number, amount_cents, body)
    values (p_order_id, v_partner_id, null, 'commission', v_fac, v_fee, v_body_fee)
    on conflict (order_id, kind) do nothing;
    perform secoto_private.queue_email(v_partner_id,
      'SECOTO - Facture ' || v_fac || ' - frais de mise en relation ' || v_order.public_ref, v_body_fee, v_order.mission_id,
      'od-direct-commission:' || p_order_id::text);
  end if;

  perform secoto_private.notify_event(v_order.account_id, 'payment', 'Facture disponible',
    format('Commande %s : facture %s envoyée par e-mail.', v_order.public_ref, v_num),
    null, 'courses', 'od-invoice:' || p_order_id::text, p_order_id);
  perform secoto_private.audit('order_invoiced_direct', 'transport_order', p_order_id::text,
    jsonb_build_object('invoice_number', v_num, 'commission_invoice', v_fac, 'amount_cents', v_order.client_price_cents, 'fee_cents', v_fee));
end;
$f$;
revoke all on function secoto_private.od_issue_direct_invoices(uuid) from public, anon, authenticated;

select secoto_private.mig074_patch(
  'secoto_private.od_issue_invoice(uuid)'::regprocedure,
  '  if not found or v_order.invoice_number is not null then return; end if;',
  '  if not found or v_order.invoice_number is not null then return; end if;
  -- 074 : en paiement direct, facture au nom du transporteur et facture de commission.
  if v_order.payment_circuit = ''direct'' then
    perform secoto_private.od_issue_direct_invoices(p_order_id);
    return;
  end if;');

-- ----------------------------------------------------------------------------
-- 11. CONTRÔLES DE FIN : la migration s'arrête si un ajout manque.
-- ----------------------------------------------------------------------------
do $$
begin
  if position('plateau_paiement_direct' in pg_get_functiondef('public.secoto_od_book_quote(uuid, boolean, uuid)'::regprocedure)) = 0 then
    raise exception '074 : réservation non adaptée.';
  end if;
  if position('payment_account_required' in pg_get_functiondef('secoto_private.od_try_accept(uuid, uuid, uuid)'::regprocedure)) = 0 then
    raise exception '074 : acceptation non adaptée.';
  end if;
  if position('<> ''direct''' in pg_get_functiondef('public.secoto_payouts_claim_due(integer)'::regprocedure)) = 0 then
    raise exception '074 : exclusion des versements directs absente.';
  end if;
  if position('od_direct_cancel' in pg_get_functiondef('public.secoto_od_cancel_order(uuid, uuid)'::regprocedure)) = 0 then
    raise exception '074 : annulation non adaptée.';
  end if;
  if position('od_issue_direct_invoices' in pg_get_functiondef('secoto_private.od_issue_invoice(uuid)'::regprocedure)) = 0 then
    raise exception '074 : facturation non adaptée.';
  end if;
  if exists (select 1 from public.secoto_feature_flags where key = 'plateau_paiement_direct' and enabled) then
    raise notice '074 : interrupteur plateau_paiement_direct déjà ALLUMÉ.';
  end if;
end $$;

notify pgrst, 'reload schema';
