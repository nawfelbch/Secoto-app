-- ============================================================================
-- SECOTO 076 — Paiement direct : argent retenu jusqu'à la livraison (D3)
-- ----------------------------------------------------------------------------
-- Décision du 09/10/2026 : le prix du transport reste sur le solde Stripe DU
-- TRANSPORTEUR jusqu'à la livraison validée, puis il est viré automatiquement
-- sur son compte bancaire 4 h après (payout_delay_hours). Jamais chez SECOTO,
-- jamais à la main.
--
-- Mécanisme :
--   • le compte du transporteur passe en virement « manuel » chez Stripe au
--     moment où il active le paiement direct (colonne stripe_payouts_manual,
--     relue de Stripe à chaque synchronisation) ;
--   • sans ce réglage, le transporteur n'est pas « prêt » : il ne peut pas
--     accepter de mission plateau en paiement direct ;
--   • à la livraison, la ligne de versement du circuit direct est « à payer »
--     (et non plus une simple trace) ; la maintenance déclenche le virement
--     bancaire depuis le solde du transporteur à l'échéance ;
--   • un Transfer de l'ancien circuit reçu par un compte en virement manuel
--     (mission manuelle, ancienne commande) est aussitôt viré vers sa banque :
--     rien ne reste bloqué.
--
-- Migration UNIQUEMENT ADDITIVE et rejouable. Rien ne change pour le
-- convoyage ni pour l'ancien circuit : la fonction de versement par Transfer
-- n'est modifiée que sur sa branche « réussite », pour la file de virement.
-- ============================================================================

-- 1. COLONNE ET PROTECTION --------------------------------------------------------
alter table public.accounts add column if not exists stripe_payouts_manual boolean;
comment on column public.accounts.stripe_payouts_manual is
  'Virements bancaires du compte Stripe déclenchés par SECOTO après la livraison (paiement direct). Relu de Stripe.';

create or replace function secoto_private.trg_protect_payouts_manual()
returns trigger language plpgsql set search_path = ''
as $f$
begin
  if current_user in ('authenticated', 'anon')
     and new.stripe_payouts_manual is distinct from old.stripe_payouts_manual then
    raise exception 'Les informations de paiement Stripe ne se modifient que depuis SECOTO.';
  end if;
  return new;
end;
$f$;
drop trigger if exists trg_secoto_protect_payouts_manual on public.accounts;
create trigger trg_secoto_protect_payouts_manual
  before update on public.accounts
  for each row execute function secoto_private.trg_protect_payouts_manual();

-- 2. PRÊT POUR LE PAIEMENT DIRECT : virement manuel exigé ---------------------------
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

select secoto_private.mig074_patch(
  'public.secoto_carrier_direct_status()'::regprocedure,
  '    ''payouts'', coalesce(a.stripe_payouts_enabled, false),',
  '    ''payouts'', coalesce(a.stripe_payouts_enabled, false),
    ''payouts_manual'', coalesce(a.stripe_payouts_manual, false),');

-- 3. LIGNE DE VERSEMENT DU CIRCUIT DIRECT : « à payer » à l'échéance ----------------
-- Compte en virement manuel : le virement bancaire est à déclencher (échéance
-- posée par l'appelant : livraison + payout_delay_hours). Sinon (compte resté
-- au virement automatique de Stripe) : simple trace, comme avant.
create or replace function secoto_private.trg_payout_circuit()
returns trigger language plpgsql security definer set search_path = ''
as $f$
declare v_manuel boolean;
begin
  if new.payment_circuit is null and new.order_id is not null then
    select o.payment_circuit into new.payment_circuit from public.transport_orders o where o.id = new.order_id;
  end if;
  if new.payment_circuit = 'direct' and new.connected_account_id is null then
    select p.connected_account_id into new.connected_account_id
      from public.transport_orders o join public.payments p on p.id = o.payment_id
     where o.id = new.order_id;
  end if;
  if new.payment_circuit = 'direct' then
    select coalesce(a.stripe_payouts_manual, false) into v_manuel
      from public.accounts a where a.id = new.partner_id;
    if coalesce(v_manuel, false) then
      new.status := 'to_pay';
      new.paid_at := null;
      new.paid_via := null;
      new.reference := coalesce(new.reference, 'Virement du solde Stripe du transporteur vers sa banque');
    else
      new.status := 'paid';
      new.paid_at := coalesce(new.paid_at, now());
      new.paid_via := 'connect';
      new.reference := coalesce(new.reference, 'Paiement direct du client au transporteur (Stripe)');
    end if;
  end if;
  return new;
end;
$f$;

-- Annulation tardive déjà tracée puis rouverte : même règle.
select secoto_private.mig074_patch(
  'secoto_private.od_direct_cancel(uuid)'::regprocedure,
  '         set amount_cents = excluded.amount_cents, status = ''paid'', paid_at = now(), paid_via = ''connect'', kind = ''late_cancel'',',
  '         set amount_cents = excluded.amount_cents,
             status = case when exists (select 1 from public.accounts a where a.id = excluded.partner_id
                                         and coalesce(a.stripe_payouts_manual, false)) then ''to_pay'' else ''paid'' end,
             paid_at = case when exists (select 1 from public.accounts a where a.id = excluded.partner_id
                                          and coalesce(a.stripe_payouts_manual, false)) then null else now() end,
             paid_via = case when exists (select 1 from public.accounts a where a.id = excluded.partner_id
                                           and coalesce(a.stripe_payouts_manual, false)) then null else ''connect'' end,
             kind = ''late_cancel'',');

-- Textes transporteur : virement vers sa banque, plus « Stripe vous les vire ».
select secoto_private.mig074_patch(
  'secoto_private.trg_od_sync_from_mission()'::regprocedure,
  '               then ''Mission %s livrée. Le client vous a payé %s € directement : Stripe vous les vire automatiquement.''',
  '               then ''Mission %s livrée. Les %s € payés par le client sont virés automatiquement sur votre compte bancaire sous 4 h.''');
select secoto_private.mig074_patch(
  'secoto_private.od_direct_cancel(uuid)'::regprocedure,
  'vous restent acquis, versés automatiquement par Stripe.',
  'vous restent acquis, virés automatiquement sur votre compte bancaire.');

-- 4. FILE DES VIREMENTS DU CIRCUIT DIRECT -------------------------------------------
create or replace function public.secoto_direct_payouts_claim_due(p_limit integer default 20)
returns jsonb language plpgsql volatile security definer set search_path = ''
as $f$
declare v_rows jsonb;
begin
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

-- 5. TRANSFERS DE L'ANCIEN CIRCUIT REÇUS PAR UN COMPTE EN VIREMENT MANUEL -----------
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
  '    -- 076 : compte en virement manuel -> le Transfer reçu part aussitôt vers sa banque.
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
  -- Fonds pas encore disponibles chez Stripe : nouvel essai toutes les heures,
  -- pendant dix jours, puis l'administrateur est prévenu.
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

-- 6. CONTRÔLES BLOQUANTS ------------------------------------------------------------------
do $controles$
declare v_src text;
begin
  select pg_get_functiondef('secoto_private.partner_direct_ready(uuid)'::regprocedure) into v_src;
  if position('stripe_payouts_manual' in v_src) = 0 then raise exception '076 : prêt sans virement manuel'; end if;
  select pg_get_functiondef('public.secoto_payouts_claim_due(integer)'::regprocedure) into v_src;
  if position('<> ''direct''' in v_src) = 0 then raise exception '076 : les Transfers doivent toujours exclure le circuit direct'; end if;
  select pg_get_functiondef('public.secoto_payout_transfer_result(uuid, boolean, text, text, text)'::regprocedure) into v_src;
  if position('connect_bank_payouts' in v_src) = 0 then raise exception '076 : file de virement absente'; end if;
end;
$controles$;

notify pgrst, 'reload schema';
