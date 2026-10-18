-- ============================================================================
-- SECOTO 100 — Règlement à l'arrivée du véhicule
-- ----------------------------------------------------------------------------
-- Décision du 18/10/2026 : les clients hésitent à payer d'avance. Derrière
-- l'interrupteur « reglement_arrivee » (ÉTEINT par défaut), pour toutes les
-- commandes payées par carte (plateau et convoyage, un ou plusieurs véhicules,
-- trois offres comprises, liens de paiement compris) :
--
--  · à la réservation, la carte bancaire est seulement ENREGISTRÉE : 0 €
--    prélevé. Elle sert de garantie, même si le client paie autrement ;
--  · le client choisit son mode de règlement :
--      - carte    : prélèvement automatique à la livraison ;
--      - klarna   : à la livraison, il paie lui-même (en plusieurs fois) ;
--                   sans paiement sous 24 h, la carte est prélevée ;
--      - virement : à la livraison, il vire à SECOTO (IBAN + référence) ;
--                   sans virement confirmé sous 48 h, la carte est prélevée ;
--      - especes  : 1 000 € au plus (article L112-6 du Code monétaire et
--                   financier) ; il paie le transporteur en main propre ;
--  · le transporteur n'est confirmé qu'avec une carte valide, sans débit ;
--  · espèces : le transporteur confirme « reçu » (il garde tout et doit la
--    marge SECOTO, à payer par carte, IBAN ou virement ; sans paiement sous
--    7 jours, elle est retenue sur son prochain versement et il ne reçoit plus
--    de missions) ou « non reçu » (la carte du client est prélevée 24 h après,
--    sauf contestation) ;
--  · le versement au transporteur attend toujours que SECOTO ait encaissé
--    (règle existante : paiement « paid »), 4 h après la livraison.
--
-- Tous les délais sont dans app_settings['reglement_arrivee'].
-- Migration ADDITIVE et rejouable : colonnes nullables ou booléennes à faux,
-- une table, des fonctions nouvelles, des ajouts ciblés (mig074_patch) sans
-- effet tant que l'interrupteur est éteint. Aucune policy existante modifiée.
-- Le paiement direct au transporteur (074) n'est pas concerné.
-- ============================================================================

-- 1. INTERRUPTEUR ET RÉGLAGES ----------------------------------------------------
alter table public.secoto_feature_flags drop constraint if exists secoto_feature_flags_key_check;
alter table public.secoto_feature_flags add constraint secoto_feature_flags_key_check
  check (key in ('auto_pricing', 'od_payments', 'subscriptions', 'dispatch_notifications', 'live_tracking',
                 'direct_accept', 'connect_payouts', 'plateau_paiement_direct',
                 'conditions_v2', 'commission_client',
                 'mise_en_relation_v2', 'bareme_transporteurs',
                 'adresses_internationales',
                 'trois_offres',
                 'reglement_arrivee'));
insert into public.secoto_feature_flags(key, enabled) values ('reglement_arrivee', false)
on conflict (key) do nothing;

insert into public.app_settings(key, value) values ('reglement_arrivee', jsonb_build_object(
  'plafond_especes_eur', 1000,
  'delai_klarna_h', 24,
  'delai_virement_h', 48,
  'delai_especes_non_recu_h', 24,
  'relance_especes_h', 48,
  'delai_commission_jours', 7,
  'tentatives_carte_max', 3))
on conflict (key) do nothing;

create or replace function secoto_private.reglement_num(p_key text, p_default numeric)
returns numeric language sql stable security definer set search_path = '' as $$
  select coalesce((select (s.value ->> p_key)::numeric from public.app_settings s where s.key = 'reglement_arrivee'), p_default);
$$;
revoke all on function secoto_private.reglement_num(text, numeric) from public, anon, authenticated;

-- IBAN de SECOTO (facture, virement à la livraison). Vide = virement indisponible.
create or replace function secoto_private.reglement_iban()
returns jsonb language sql stable security definer set search_path = '' as $$
  select case when nullif(trim(coalesce(s.value ->> 'iban', '')), '') is not null
    then jsonb_build_object('iban', trim(s.value ->> 'iban'), 'bic', nullif(trim(coalesce(s.value ->> 'bic', '')), ''),
                            'titulaire', coalesce(nullif(trim(coalesce(s.value ->> 'titulaire', '')), ''), 'SECOTO')) end
    from public.app_settings s where s.key = 'bank_details';
$$;
revoke all on function secoto_private.reglement_iban() from public, anon, authenticated;

create or replace function secoto_private.reglement_eur(p_cents integer)
returns text language sql immutable set search_path = '' as $$
  select replace(to_char(coalesce(p_cents, 0) / 100.0, 'FM999999990D00'), '.', ',') || ' €';
$$;

-- 2. COLONNES (toutes additives) -------------------------------------------------
alter table public.transport_orders add column if not exists mode_reglement text;
alter table public.payments add column if not exists debit_a_livraison boolean not null default false;
alter table public.payments add column if not exists reglement_echeance timestamptz;
alter table public.payments add column if not exists reglement_debit_tente_at timestamptz;
alter table public.payments add column if not exists reglement_tentatives integer not null default 0;
alter table public.payments add column if not exists especes_statut text;
alter table public.payments add column if not exists especes_declare_at timestamptz;
alter table public.payments add column if not exists especes_relance_at timestamptz;

do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'transport_orders_mode_reglement_check') then
    alter table public.transport_orders add constraint transport_orders_mode_reglement_check
      check (mode_reglement is null or mode_reglement in ('carte', 'virement', 'klarna', 'especes'));
  end if;
  if not exists (select 1 from pg_constraint where conname = 'payments_especes_statut_check') then
    alter table public.payments add constraint payments_especes_statut_check
      check (especes_statut is null or especes_statut in ('recu', 'non_recu'));
  end if;
end $$;

comment on column public.transport_orders.mode_reglement is
  '100 : règlement choisi par le client (carte, virement, klarna, especes). La carte reste enregistrée en garantie.';
comment on column public.payments.debit_a_livraison is
  '100 : carte enregistrée sans débit ; règlement à la livraison du véhicule.';

create index if not exists payments_reglement_echeance_idx on public.payments(reglement_echeance)
  where debit_a_livraison and status in ('requires_capture', 'capture_failed');

-- 3. MARGE DUE PAR LE TRANSPORTEUR (espèces) -------------------------------------
create table if not exists public.commissions_dues (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null unique references public.transport_orders(id),
  partner_id uuid not null references public.accounts(id),
  amount_cents integer not null check (amount_cents > 0),
  retenue_cents integer not null default 0 check (retenue_cents >= 0),
  statut text not null default 'due' check (statut in ('due', 'payee', 'retenue', 'annulee')),
  due_at timestamptz not null,
  paid_at timestamptz,
  paid_via text check (paid_via is null or paid_via in ('carte', 'virement', 'retenue', 'admin')),
  provider_intent_id text,
  note text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists commissions_dues_partner_idx on public.commissions_dues(partner_id, statut);
alter table public.commissions_dues enable row level security;
-- Aucune policy : lecture et écriture uniquement par les fonctions ci-dessous.
revoke all on public.commissions_dues from anon, authenticated;

-- Compte qui encaisse pour ce transporteur (entreprise, sinon lui-même) : même règle que 062.
create or replace function secoto_private.reglement_payee(p_partner uuid)
returns uuid language sql stable security definer set search_path = '' as $$
  select coalesce((select b.payout_account_id from public.business_members bm
                     join public.business_accounts b on b.id = bm.business_id
                    where bm.account_id = p_partner and b.kind = 'transporteur' and b.archived_at is null
                      and b.payout_account_id is not null
                    order by bm.created_at limit 1), p_partner);
$$;
revoke all on function secoto_private.reglement_payee(uuid) from public, anon, authenticated;

-- Marge échue et non réglée : le transporteur ne reçoit plus de missions.
create or replace function secoto_private.commission_en_retard(p_partner uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.commissions_dues c
                  where c.statut = 'due' and c.due_at <= now()
                    and c.partner_id in (p_partner, secoto_private.reglement_payee(p_partner)));
$$;
revoke all on function secoto_private.commission_en_retard(uuid) from public, anon, authenticated;

select secoto_private.mig074_patch('secoto_private.od_partner_eligible(uuid,uuid)'::regprocedure,
  $a$and not exists (select 1 from public.transport_offers x where x.order_id = o.id and x.partner_id = a.id and x.status = 'declined')$a$,
  $n$and not exists (select 1 from public.transport_offers x where x.order_id = o.id and x.partner_id = a.id and x.status = 'declined')
      and not secoto_private.commission_en_retard(a.id)  -- 100 : marge SECOTO impayée$n$);

-- 4. RÉSERVATION : CARTE ENREGISTRÉE, 0 € PRÉLEVÉ ----------------------------------
-- Toute nouvelle commande payée par carte sur le compte SECOTO (réservation dans
-- l'app, offre, lien de paiement) : débit reporté à la livraison.
create or replace function secoto_private.trg_reglement_paiement()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if tg_op = 'INSERT' and secoto_private.flag('reglement_arrivee')
     and new.order_id is not null and new.purpose in ('od_plateau', 'od_convoyage')
     and new.payment_circuit is null and new.status = 'pending' then
    new.debit_a_confirmation := true;
    new.debit_a_livraison := true;
    new.capture_method := 'manual';
  end if;
  -- Paiement direct au transporteur (074) : circuit inchangé.
  if new.payment_circuit = 'direct' and new.debit_a_livraison then
    new.debit_a_livraison := false;
    new.debit_a_confirmation := false;
  end if;
  return new;
end;
$$;
drop trigger if exists trg_secoto_reglement_paiement on public.payments;
create trigger trg_secoto_reglement_paiement before insert or update of payment_circuit on public.payments
  for each row execute function secoto_private.trg_reglement_paiement();

create or replace function secoto_private.trg_reglement_commande()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.debit_a_livraison and new.order_id is not null then
    update public.transport_orders
       set mode_reglement = coalesce(mode_reglement, 'carte'),
           payment_strategy = case when funding = 'card' then 'authorize_then_capture' else payment_strategy end,
           updated_at = now()
     where id = new.order_id;
  end if;
  return new;
end;
$$;
drop trigger if exists trg_secoto_reglement_commande on public.payments;
create trigger trg_secoto_reglement_commande after insert on public.payments
  for each row execute function secoto_private.trg_reglement_commande();

-- Le client choisit (ou change) son mode de règlement tant qu'aucun transporteur
-- n'a confirmé. Espèces : 1 000 € au plus. Virement : IBAN SECOTO renseigné.
create or replace function public.secoto_od_choisir_reglement(p_order_id uuid, p_mode text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_user uuid := secoto_private.assert_authenticated();
  v_order public.transport_orders%rowtype;
  v_payment public.payments%rowtype;
  v_plafond integer := (secoto_private.reglement_num('plafond_especes_eur', 1000) * 100)::int;
begin
  if not secoto_private.flag('reglement_arrivee') then raise exception 'Le règlement à l''arrivée n''est pas encore ouvert.'; end if;
  if p_mode not in ('carte', 'virement', 'klarna', 'especes') then raise exception 'Mode de règlement inconnu.'; end if;
  select * into v_order from public.transport_orders o where o.id = p_order_id for update;
  if not found or not (v_order.account_id = v_user or (v_order.business_id is not null and secoto_private.is_business_member(v_order.business_id, v_user))) then
    raise exception 'Commande introuvable.' using errcode = 'P0002';
  end if;
  select * into v_payment from public.payments p where p.id = v_order.payment_id for update;
  if v_order.funding <> 'card' or v_payment.id is null or not v_payment.debit_a_livraison then
    raise exception 'Cette commande se règle déjà autrement.';
  end if;
  if v_order.status not in ('awaiting_payment', 'searching_partner') then
    raise exception 'Le mode de règlement ne peut plus être changé : un transporteur a déjà confirmé. Contactez SECOTO.';
  end if;
  if p_mode = 'especes' and v_order.client_price_cents > v_plafond then
    raise exception 'Paiement en espèces limité à % € par la loi. Choisissez la carte, le virement ou Klarna.', v_plafond / 100;
  end if;
  if p_mode = 'virement' and secoto_private.reglement_iban() is null then
    raise exception 'Le virement n''est pas disponible pour le moment.';
  end if;
  update public.transport_orders set mode_reglement = p_mode, updated_at = now()
   where id = p_order_id returning * into v_order;
  perform secoto_private.audit('order_mode_reglement', 'transport_order', p_order_id::text, jsonb_build_object('mode', p_mode));
  return jsonb_build_object('order', secoto_private.order_client_json(v_order));
end;
$$;
revoke all on function public.secoto_od_choisir_reglement(uuid, text) from public, anon;
grant execute on function public.secoto_od_choisir_reglement(uuid, text) to authenticated;

-- Carte enregistrée : message adapté au règlement à l'arrivée.
select secoto_private.mig074_patch('public.secoto_direct_card_saved(uuid,text,text,text)'::regprocedure,
  $a$format(case when coalesce(v_payment.debit_a_confirmation, false)  -- 099$a$,
  $n$format(case when coalesce(v_payment.debit_a_livraison, false)  -- 100
                 then 'Commande %s : votre carte est enregistrée, 0 € prélevé. Votre demande est envoyée aux transporteurs vérifiés ; vous réglez à l''arrivée du véhicule, avec le mode choisi.'
                 when coalesce(v_payment.debit_a_confirmation, false)  -- 099$n$);

-- 5. CONFIRMATION DU TRANSPORTEUR : AUCUN DÉBIT ----------------------------------
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
    'action_required_at', v_payment.direct_action_required_at,
    -- 100 : règlement à l'arrivée (aucun débit à la confirmation).
    'debit_a_livraison', v_payment.debit_a_livraison, 'mode_reglement', v_order.mode_reglement);
end;
$$;
revoke all on function public.secoto_differe_charge_context(uuid) from public, anon, authenticated;
grant execute on function public.secoto_differe_charge_context(uuid) to service_role;

-- Carte enregistrée et valide : la mission est confirmée au transporteur, rien n'est prélevé.
create or replace function public.secoto_reglement_confirmer(p_order_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_order public.transport_orders%rowtype; v_payment public.payments%rowtype;
begin
  select * into v_order from public.transport_orders o where o.id = p_order_id for update;
  if not found then return jsonb_build_object('result', 'unavailable'); end if;
  if v_order.status in ('partner_confirmed', 'picked_up', 'delivered') then return jsonb_build_object('result', 'confirmed'); end if;
  if v_order.status <> 'partner_locked' then return jsonb_build_object('result', 'unavailable'); end if;
  select * into v_payment from public.payments p where p.id = v_order.payment_id;
  if not coalesce(v_payment.debit_a_livraison, false) or v_payment.status <> 'requires_capture'
     or v_payment.saved_payment_method_id is null then
    return jsonb_build_object('result', 'capture_failed', 'reason', 'carte_absente');
  end if;
  perform secoto_private.audit('reglement_confirme_sans_debit', 'transport_order', p_order_id::text,
    jsonb_build_object('mode', v_order.mode_reglement));
  return secoto_private.od_confirm(p_order_id);
end;
$$;
revoke all on function public.secoto_reglement_confirmer(uuid) from public, anon, authenticated;
grant execute on function public.secoto_reglement_confirmer(uuid) to service_role;

-- 6. LIVRAISON : DÉCLENCHEMENT DU RÈGLEMENT ----------------------------------------
create or replace function secoto_private.trg_reglement_livraison()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  v_payment public.payments%rowtype;
  v_email text;
  v_banque jsonb := secoto_private.reglement_iban();
  v_montant text := secoto_private.reglement_eur(new.client_price_cents);
  v_delai integer;
  v_corps text;
begin
  if new.status <> 'delivered' or old.status = 'delivered' then return new; end if;
  select * into v_payment from public.payments p where p.id = new.payment_id for update;
  if not found or not v_payment.debit_a_livraison or v_payment.status not in ('requires_capture', 'capture_failed') then
    return new;
  end if;
  select a.email into v_email from public.accounts a where a.id = new.account_id;

  if new.mode_reglement = 'klarna' then
    v_delai := secoto_private.reglement_num('delai_klarna_h', 24)::int;
    update public.payments set reglement_echeance = now() + make_interval(hours => v_delai), updated_at = now() where id = v_payment.id;
    perform secoto_private.notify_event(new.account_id, 'payment', 'Véhicule livré : réglez en plusieurs fois',
      format('Commande %s livrée. Réglez %s avec Klarna depuis votre commande (bouton « Payer maintenant »). Sans paiement sous %s h, votre carte enregistrée sera prélevée.', new.public_ref, v_montant, v_delai),
      null, 'courses', 'od-reglement-livraison:' || new.id::text, new.id);
  elsif new.mode_reglement = 'virement' and v_banque is not null then
    v_delai := secoto_private.reglement_num('delai_virement_h', 48)::int;
    update public.payments set reglement_echeance = now() + make_interval(hours => v_delai), updated_at = now() where id = v_payment.id;
    v_corps := format(E'Bonjour,\n\nVotre véhicule a été livré (commande %s). Merci de régler %s par virement :\n\n  Titulaire : %s\n  IBAN : %s%s\n  Référence à indiquer : %s\n\nSans virement reçu sous %s h, la carte enregistrée lors de votre réservation sera prélevée automatiquement du même montant.\n\nUne question ? Répondez à cet e-mail.\n\nL''équipe SECOTO',
      new.public_ref, v_montant, v_banque ->> 'titulaire', v_banque ->> 'iban',
      coalesce(E'\n  BIC : ' || (v_banque ->> 'bic'), ''), new.public_ref, v_delai);
    perform secoto_private.notify_event(new.account_id, 'payment', 'Véhicule livré : réglez par virement',
      format('Commande %s livrée. Virez %s à SECOTO (IBAN %s, référence %s). Sans virement reçu sous %s h, votre carte enregistrée sera prélevée.', new.public_ref, v_montant, v_banque ->> 'iban', new.public_ref, v_delai),
      null, 'courses', 'od-reglement-livraison:' || new.id::text, new.id);
    if v_email is not null then
      insert into public.email_outbox(account_id, to_email, subject, body_text, event_key)
      values (new.account_id, v_email, format('SECOTO — virement de %s pour la commande %s', v_montant, new.public_ref), v_corps,
              'od-reglement-virement:' || new.id::text)
      on conflict (event_key) do nothing;
    end if;
  elsif new.mode_reglement = 'especes' then
    perform secoto_private.notify_event(new.account_id, 'payment', 'Véhicule livré',
      format('Commande %s livrée. Réglez %s en espèces au transporteur. Rien n''est prélevé sur votre carte tant que le transporteur confirme votre paiement.', new.public_ref, v_montant),
      null, 'courses', 'od-reglement-livraison:' || new.id::text, new.id);
    perform secoto_private.notify_event(new.assigned_partner_id, 'payment', 'Encaissez le règlement en espèces',
      format('Commande %s : encaissez %s en espèces auprès du client, puis confirmez la réception dans l''application (Missions proposées → Règlements). Marge SECOTO à reverser : %s.',
        new.public_ref, v_montant, secoto_private.reglement_eur(new.client_price_cents - new.partner_pay_cents)),
      new.mission_id, 'offre', 'od-reglement-especes:' || new.id::text, new.id);
  else
    -- Carte (ou virement indisponible) : prélèvement automatique, tout de suite.
    update public.payments set reglement_echeance = now(), updated_at = now() where id = v_payment.id;
    perform secoto_private.notify_event(new.account_id, 'payment', 'Véhicule livré',
      format('Commande %s livrée. %s vont être prélevés sur votre carte enregistrée.', new.public_ref, v_montant),
      null, 'courses', 'od-reglement-livraison:' || new.id::text, new.id);
  end if;
  return new;
end;
$$;
drop trigger if exists trg_secoto_reglement_livraison on public.transport_orders;
create trigger trg_secoto_reglement_livraison after update of status on public.transport_orders
  for each row execute function secoto_private.trg_reglement_livraison();

-- Message de livraison au transporteur : le paiement en espèces ne passe pas par SECOTO.
select secoto_private.mig074_patch('secoto_private.trg_od_sync_from_mission()'::regprocedure,
  $a$else 'Mission %s livrée : paiement de %s € déclenché sous 48 heures.' end$a$,
  $n$when v_order.mode_reglement = 'especes'  -- 100
                 then 'Mission %s livrée : encaissez le règlement du client en espèces, puis confirmez-le dans l''application (%s € pour vous).'
               else 'Mission %s livrée : paiement de %s € déclenché sous 48 heures.' end$n$);

-- 7. PRÉLÈVEMENT DE LA CARTE (appelé par le serveur, jamais par le téléphone) -------
-- Réserve les paiements dont l'échéance est passée ; une même ligne n'est pas
-- reprise avant 15 minutes (la clé d'idempotence Stripe protège la reprise).
create or replace function public.secoto_reglements_a_debiter(p_limit integer default 20)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_rows jsonb;
begin
  with dus as (
    select p.id from public.payments p
      join public.transport_orders o on o.id = p.order_id
     where p.debit_a_livraison and p.status in ('requires_capture', 'capture_failed')
       and o.status = 'delivered'
       and p.reglement_echeance is not null and p.reglement_echeance <= now()
       and p.reglement_tentatives < secoto_private.reglement_num('tentatives_carte_max', 3)
       and (p.reglement_debit_tente_at is null or p.reglement_debit_tente_at < now() - interval '15 minutes')
       and (o.mode_reglement is distinct from 'especes' or p.especes_statut = 'non_recu')
       and p.saved_payment_method_id is not null
     order by p.reglement_echeance
     limit greatest(coalesce(p_limit, 20), 1)
     for update of p skip locked
  ), pris as (
    update public.payments p set reglement_debit_tente_at = now(), updated_at = now()
      from dus where p.id = dus.id returning p.*
  )
  select coalesce(jsonb_agg(jsonb_build_object(
      'payment_id', pr.id, 'order_id', o.id, 'public_ref', o.public_ref,
      'amount_cents', pr.amount_cents, 'currency', coalesce(pr.currency, 'eur'),
      'customer_id', a.stripe_customer_id, 'payment_method_id', pr.saved_payment_method_id,
      'provider_intent_id', pr.provider_intent_id, 'tentative', pr.reglement_tentatives,
      'mode_reglement', o.mode_reglement, 'purpose', pr.purpose)), '[]'::jsonb)
    into v_rows
    from pris pr join public.transport_orders o on o.id = pr.order_id
    join public.accounts a on a.id = pr.account_id;
  return v_rows;
end;
$$;
revoke all on function public.secoto_reglements_a_debiter(integer) from public, anon, authenticated;
grant execute on function public.secoto_reglements_a_debiter(integer) to service_role;

-- Résultat d'un prélèvement : reussi | refuse | action | reseau.
create or replace function public.secoto_reglement_debit_resultat(p_payment_id uuid, p_resultat text, p_intent_id text, p_error text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_payment public.payments%rowtype; v_order public.transport_orders%rowtype;
begin
  select * into v_payment from public.payments p where p.id = p_payment_id for update;
  if not found or not v_payment.debit_a_livraison then return jsonb_build_object('result', 'ignored'); end if;
  select * into v_order from public.transport_orders o where o.id = v_payment.order_id;
  if v_payment.status = 'paid' then return jsonb_build_object('result', 'paid'); end if;

  if p_resultat = 'reussi' then
    update public.payments set status = 'paid', captured_at = coalesce(captured_at, now()), paid_at = coalesce(paid_at, now()),
           provider_intent_id = coalesce(p_intent_id, provider_intent_id), last_error = null, updated_at = now()
     where id = p_payment_id;
    perform secoto_private.od_issue_invoice(v_order.id);
    perform secoto_private.notify_event(v_order.account_id, 'payment', 'Paiement effectué',
      format('Commande %s : %s ont été prélevés sur votre carte. Merci d''avoir choisi SECOTO.', v_order.public_ref, secoto_private.reglement_eur(v_payment.amount_cents)),
      null, 'courses', 'od-reglement-paye:' || v_order.id::text, v_order.id);
    return jsonb_build_object('result', 'paid');
  elsif p_resultat in ('refuse', 'action') then
    update public.payments set status = 'capture_failed', reglement_tentatives = reglement_tentatives + 1,
           reglement_echeance = now() + interval '24 hours',
           provider_intent_id = coalesce(provider_intent_id, p_intent_id),
           last_error = left(coalesce(p_error, p_resultat), 500), updated_at = now()
     where id = p_payment_id returning * into v_payment;
    perform secoto_private.notify_event(v_order.account_id, 'payment_failed', 'Paiement à régler',
      format(case when p_resultat = 'action'
               then 'Commande %s : votre banque demande une validation. Ouvrez la commande et touchez « Payer maintenant » (carte ou Klarna) pour régler %s.'
               else 'Commande %s : le prélèvement de %s n''a pas abouti. Ouvrez la commande et touchez « Payer maintenant » (carte ou Klarna).' end,
             v_order.public_ref, secoto_private.reglement_eur(v_payment.amount_cents)),
      null, 'courses', 'od-reglement-echec:' || v_order.id::text || ':' || v_payment.reglement_tentatives, v_order.id);
    perform secoto_private.notify_admins_event('payment_failed', 'Prélèvement à la livraison refusé',
      format('%s · %s · tentative %s : %s', v_order.public_ref, secoto_private.reglement_eur(v_payment.amount_cents),
             v_payment.reglement_tentatives, coalesce(p_error, p_resultat)),
      'requests', 'od-reglement-echec-admin:' || v_order.id::text || ':' || v_payment.reglement_tentatives, v_order.id);
    return jsonb_build_object('result', 'capture_failed', 'tentatives', v_payment.reglement_tentatives);
  end if;
  -- Réseau, Stripe indisponible : rien n'est tranché, nouvel essai dans 15 minutes.
  return jsonb_build_object('result', 'retry');
end;
$$;
revoke all on function public.secoto_reglement_debit_resultat(uuid, text, text, text) from public, anon, authenticated;
grant execute on function public.secoto_reglement_debit_resultat(uuid, text, text, text) to service_role;

-- 8. ESPÈCES : DÉCLARATION DU TRANSPORTEUR ----------------------------------------
create or replace function public.secoto_reglement_especes(p_order_id uuid, p_recu boolean)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_user uuid := secoto_private.assert_authenticated();
  v_order public.transport_orders%rowtype;
  v_payment public.payments%rowtype;
  v_marge integer;
  v_jours integer := secoto_private.reglement_num('delai_commission_jours', 7)::int;
  v_delai integer := secoto_private.reglement_num('delai_especes_non_recu_h', 24)::int;
begin
  select * into v_order from public.transport_orders o where o.id = p_order_id for update;
  if not found or not (v_order.assigned_partner_id = v_user
       or exists (select 1 from public.missions m where m.id = v_order.mission_id and m.assigned_transporter_id = v_user)) then
    raise exception 'Commande introuvable.' using errcode = 'P0002';
  end if;
  select * into v_payment from public.payments p where p.id = v_order.payment_id for update;
  if v_order.mode_reglement is distinct from 'especes' or not coalesce(v_payment.debit_a_livraison, false) then
    raise exception 'Cette commande ne se règle pas en espèces.';
  end if;
  if v_order.status <> 'delivered' then raise exception 'Confirmez d''abord la livraison du véhicule.'; end if;
  if v_payment.especes_statut is not null or v_payment.status = 'paid' then
    return jsonb_build_object('result', 'deja_declare', 'especes_statut', v_payment.especes_statut);
  end if;

  if p_recu then
    update public.payments set especes_statut = 'recu', especes_declare_at = now(), status = 'cancelled',
           released_at = coalesce(released_at, now()), last_error = 'Réglé en espèces auprès du transporteur', updated_at = now()
     where id = v_payment.id;
    -- Le transporteur a tout encaissé : aucun virement de SECOTO pour cette mission.
    update public.partner_payouts set status = 'cancelled', last_error = 'Réglé en espèces par le client'
     where order_id = v_order.id and kind = 'mission' and status in ('to_pay', 'failed');
    v_marge := greatest(v_order.client_price_cents - v_order.partner_pay_cents, 0);
    if v_marge > 0 then
      insert into public.commissions_dues(order_id, partner_id, amount_cents, due_at)
      values (v_order.id, v_order.assigned_partner_id, v_marge, now() + make_interval(days => v_jours))
      on conflict (order_id) do nothing;
      perform secoto_private.notify_event(v_order.assigned_partner_id, 'payment', format('%s dû à SECOTO', secoto_private.reglement_eur(v_marge)),
        format('Commande %s : merci, espèces reçues. Réglez la marge SECOTO de %s sous %s jours (bouton « Payer », carte ou virement). Passé ce délai, elle est retenue sur votre prochain versement et les nouvelles missions sont suspendues.',
          v_order.public_ref, secoto_private.reglement_eur(v_marge), v_jours),
        v_order.mission_id, 'offre', 'od-commission-due:' || v_order.id::text, v_order.id);
    end if;
    perform secoto_private.notify_event(v_order.account_id, 'payment', 'Paiement reçu',
      format('Commande %s : le transporteur confirme votre règlement en espèces. Rien n''a été prélevé sur votre carte. Merci !', v_order.public_ref),
      null, 'courses', 'od-especes-recu:' || v_order.id::text, v_order.id);
    perform secoto_private.audit('especes_recu', 'transport_order', v_order.id::text, jsonb_build_object('marge_cents', v_marge));
    return jsonb_build_object('result', 'recu', 'commission_cents', v_marge);
  end if;

  update public.payments set especes_statut = 'non_recu', especes_declare_at = now(),
         reglement_echeance = now() + make_interval(hours => v_delai), updated_at = now()
   where id = v_payment.id;
  perform secoto_private.notify_event(v_order.account_id, 'payment_failed', 'Règlement non reçu',
    format('Commande %s : le transporteur indique ne pas avoir reçu votre règlement en espèces. Votre carte enregistrée sera prélevée de %s dans %s h. Vous avez déjà payé ? Contactez SECOTO tout de suite.',
      v_order.public_ref, secoto_private.reglement_eur(v_order.client_price_cents), v_delai),
    null, 'courses', 'od-especes-non-recu:' || v_order.id::text, v_order.id);
  perform secoto_private.notify_admins_event('payment_failed', 'Espèces non reçues',
    format('%s · %s : le transporteur déclare ne pas avoir été payé. Carte du client prélevée dans %s h.',
      v_order.public_ref, secoto_private.reglement_eur(v_order.client_price_cents), v_delai),
    'requests', 'od-especes-non-recu-admin:' || v_order.id::text, v_order.id);
  perform secoto_private.audit('especes_non_recu', 'transport_order', v_order.id::text, '{}'::jsonb);
  return jsonb_build_object('result', 'non_recu');
end;
$$;
revoke all on function public.secoto_reglement_especes(uuid, boolean) from public, anon;
grant execute on function public.secoto_reglement_especes(uuid, boolean) to authenticated;

-- 9. CÔTÉ TRANSPORTEUR : RÈGLEMENTS ET MARGES DUES --------------------------------
create or replace function public.secoto_mes_reglements()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_user uuid := secoto_private.assert_authenticated(); v_payee uuid := secoto_private.reglement_payee(v_user);
begin
  return jsonb_build_object(
    'especes_a_declarer', coalesce((select jsonb_agg(jsonb_build_object(
        'order_id', o.id, 'public_ref', o.public_ref, 'montant_cents', o.client_price_cents,
        'marge_cents', greatest(o.client_price_cents - o.partner_pay_cents, 0),
        'livre_le', o.updated_at) order by o.updated_at desc)
      from public.transport_orders o join public.payments p on p.id = o.payment_id
      where o.status = 'delivered' and o.mode_reglement = 'especes' and p.debit_a_livraison
        and p.especes_statut is null and p.status in ('requires_capture', 'capture_failed')
        and (o.assigned_partner_id in (v_user, v_payee)
             or exists (select 1 from public.missions m where m.id = o.mission_id and m.assigned_transporter_id = v_user))), '[]'::jsonb),
    'commissions', coalesce((select jsonb_agg(jsonb_build_object(
        'id', c.id, 'order_id', c.order_id, 'public_ref', o.public_ref,
        'montant_cents', c.amount_cents, 'reste_cents', c.amount_cents - c.retenue_cents,
        'due_at', c.due_at, 'en_retard', c.due_at <= now(), 'reference', 'COM-' || o.public_ref) order by c.due_at)
      from public.commissions_dues c join public.transport_orders o on o.id = c.order_id
      where c.statut = 'due' and c.partner_id in (v_user, v_payee)), '[]'::jsonb),
    'bloque', secoto_private.commission_en_retard(v_user),
    'virement', secoto_private.reglement_iban());
end;
$$;
revoke all on function public.secoto_mes_reglements() from public, anon;
grant execute on function public.secoto_mes_reglements() to authenticated;

-- Contexte de paiement d'une marge (fonction serveur commission-pay).
create or replace function public.secoto_commission_contexte(p_commission_id uuid, p_account uuid)
returns jsonb language sql stable security definer set search_path = '' as $$
  select case when c.id is null then jsonb_build_object('error', 'introuvable')
              when c.statut <> 'due' then jsonb_build_object('error', 'deja_reglee')
              when not (c.partner_id in (p_account, secoto_private.reglement_payee(p_account))) then jsonb_build_object('error', 'introuvable')
    else jsonb_build_object('id', c.id, 'reste_cents', c.amount_cents - c.retenue_cents, 'public_ref', o.public_ref,
                            'reference', 'COM-' || o.public_ref, 'email', a.email) end
    from (select 1) x
    left join public.commissions_dues c on c.id = p_commission_id
    left join public.transport_orders o on o.id = c.order_id
    left join public.accounts a on a.id = p_account;
$$;
revoke all on function public.secoto_commission_contexte(uuid, uuid) from public, anon, authenticated;
grant execute on function public.secoto_commission_contexte(uuid, uuid) to service_role;

-- Marge réglée par carte (webhook Stripe signé).
create or replace function public.secoto_commission_payee(p_commission_id uuid, p_intent_id text, p_montant_cents integer)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_c public.commissions_dues%rowtype;
begin
  select * into v_c from public.commissions_dues c where c.id = p_commission_id for update;
  if not found then return jsonb_build_object('result', 'ignored'); end if;
  if v_c.statut <> 'due' then return jsonb_build_object('result', 'deja_reglee'); end if;
  if coalesce(p_montant_cents, 0) < v_c.amount_cents - v_c.retenue_cents then
    return jsonb_build_object('result', 'montant_insuffisant');
  end if;
  update public.commissions_dues set statut = 'payee', paid_at = now(), paid_via = 'carte',
         provider_intent_id = p_intent_id, updated_at = now() where id = v_c.id;
  perform secoto_private.notify_event(v_c.partner_id, 'payment', 'Marge réglée',
    'Merci : la marge SECOTO est réglée. Vous recevez de nouveau toutes les missions.', null, 'offre',
    'od-commission-payee:' || v_c.id::text, v_c.order_id);
  return jsonb_build_object('result', 'payee');
end;
$$;
revoke all on function public.secoto_commission_payee(uuid, text, integer) from public, anon, authenticated;
grant execute on function public.secoto_commission_payee(uuid, text, integer) to service_role;

-- 10. MAINTENANCE : RETENUES ET RELANCES -------------------------------------------
-- Marge échue : retenue sur le prochain versement « à payer » du même bénéficiaire.
create or replace function public.secoto_commissions_retenir()
returns jsonb language plpgsql security definer set search_path = '' as $$
declare c record; pp record; v_reste integer; v_pris integer; v_n integer := 0;
begin
  for c in select * from public.commissions_dues d where d.statut = 'due' and d.due_at <= now()
            order by d.due_at for update skip locked loop
    v_reste := c.amount_cents - c.retenue_cents;
    for pp in select * from public.partner_payouts x
               where x.partner_id = c.partner_id and x.status = 'to_pay' and x.kind = 'mission'
                 and x.payment_circuit is null and x.amount_cents > 0
               order by x.due_at for update skip locked loop
      exit when v_reste <= 0;
      v_pris := least(v_reste, pp.amount_cents);
      update public.partner_payouts
         set amount_cents = amount_cents - v_pris,
             status = case when amount_cents - v_pris = 0 then 'cancelled' else status end,
             last_error = format('Marge SECOTO retenue : %s (commande %s)', secoto_private.reglement_eur(v_pris),
                                 (select o.public_ref from public.transport_orders o where o.id = c.order_id))
       where id = pp.id;
      v_reste := v_reste - v_pris;
      update public.commissions_dues set retenue_cents = retenue_cents + v_pris, updated_at = now(),
             note = concat_ws(' · ', note, format('retenue %s sur le versement %s', secoto_private.reglement_eur(v_pris), pp.id))
       where id = c.id;
      v_n := v_n + 1;
    end loop;
    if v_reste <= 0 then
      update public.commissions_dues set statut = 'retenue', paid_via = 'retenue', paid_at = now(), updated_at = now() where id = c.id;
      perform secoto_private.notify_event(c.partner_id, 'payment', 'Marge retenue',
        format('La marge SECOTO due (%s) a été retenue sur votre versement. Vous recevez de nouveau toutes les missions.', secoto_private.reglement_eur(c.amount_cents)),
        null, 'offre', 'od-commission-retenue:' || c.id::text, c.order_id);
    else
      perform secoto_private.notify_event(c.partner_id, 'payment_failed', 'Marge SECOTO en retard',
        format('Il reste %s de marge SECOTO à régler. Les nouvelles missions sont suspendues jusqu''au paiement (bouton « Payer », carte ou virement).', secoto_private.reglement_eur(v_reste)),
        null, 'offre', 'od-commission-retard:' || c.id::text || ':' || to_char(now(), 'YYYYMMDD'), c.order_id);
    end if;
  end loop;
  return jsonb_build_object('retenues', v_n);
end;
$$;
revoke all on function public.secoto_commissions_retenir() from public, anon, authenticated;
grant execute on function public.secoto_commissions_retenir() to service_role;

-- Espèces jamais déclarées : une relance au transporteur et à SECOTO.
create or replace function public.secoto_reglement_relances()
returns jsonb language plpgsql security definer set search_path = '' as $$
declare r record; v_n integer := 0; v_h integer := secoto_private.reglement_num('relance_especes_h', 48)::int;
begin
  for r in select o.*, p.id as pay_id from public.transport_orders o join public.payments p on p.id = o.payment_id
            where o.status = 'delivered' and o.mode_reglement = 'especes' and p.debit_a_livraison
              and p.especes_statut is null and p.especes_relance_at is null
              and p.status in ('requires_capture', 'capture_failed')
              and o.updated_at < now() - make_interval(hours => v_h)
            for update of p skip locked loop
    update public.payments set especes_relance_at = now() where id = r.pay_id;
    perform secoto_private.notify_event(r.assigned_partner_id, 'payment_failed', 'Règlement en espèces à confirmer',
      format('Commande %s : confirmez dans l''application si vous avez reçu le règlement en espèces du client (%s).', r.public_ref, secoto_private.reglement_eur(r.client_price_cents)),
      r.mission_id, 'offre', 'od-especes-relance:' || r.id::text, r.id);
    perform secoto_private.notify_admins_event('payment_failed', 'Espèces non confirmées',
      format('%s · %s : le transporteur n''a pas confirmé le règlement en espèces %s h après la livraison.', r.public_ref, secoto_private.reglement_eur(r.client_price_cents), v_h),
      'requests', 'od-especes-relance-admin:' || r.id::text, r.id);
    v_n := v_n + 1;
  end loop;
  return jsonb_build_object('relances', v_n);
end;
$$;
revoke all on function public.secoto_reglement_relances() from public, anon, authenticated;
grant execute on function public.secoto_reglement_relances() to service_role;

-- 11. ADMINISTRATION ----------------------------------------------------------------------
create or replace function public.secoto_admin_reglements()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  if not secoto_private.is_admin(auth.uid()) then raise exception 'Réservé à l''administrateur SECOTO.'; end if;
  return jsonb_build_object(
    'actif', secoto_private.flag('reglement_arrivee'),
    'a_regler', coalesce((select jsonb_agg(jsonb_build_object(
        'order_id', o.id, 'public_ref', o.public_ref, 'mode', o.mode_reglement, 'montant_cents', o.client_price_cents,
        'statut', p.status, 'echeance', p.reglement_echeance, 'tentatives', p.reglement_tentatives,
        'especes_statut', p.especes_statut, 'erreur', p.last_error,
        'client', (select coalesce(a.company_name, a.full_name) from public.accounts a where a.id = o.account_id)) order by o.updated_at)
      from public.transport_orders o join public.payments p on p.id = o.payment_id
      where o.status = 'delivered' and p.debit_a_livraison and p.status in ('requires_capture', 'capture_failed')), '[]'::jsonb),
    'commissions', coalesce((select jsonb_agg(jsonb_build_object(
        'id', c.id, 'public_ref', o.public_ref, 'montant_cents', c.amount_cents, 'retenue_cents', c.retenue_cents,
        'due_at', c.due_at, 'en_retard', c.due_at <= now(),
        'transporteur', (select coalesce(a.company_name, a.full_name) from public.accounts a where a.id = c.partner_id)) order by c.due_at)
      from public.commissions_dues c join public.transport_orders o on o.id = c.order_id where c.statut = 'due'), '[]'::jsonb));
end;
$$;
revoke all on function public.secoto_admin_reglements() from public, anon;
grant execute on function public.secoto_admin_reglements() to authenticated;

-- Virement du client reçu sur le compte SECOTO.
create or replace function public.secoto_admin_virement_recu(p_order_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_order public.transport_orders%rowtype; v_payment public.payments%rowtype;
begin
  if not secoto_private.is_admin(auth.uid()) then raise exception 'Réservé à l''administrateur SECOTO.'; end if;
  select * into v_order from public.transport_orders o where o.id = p_order_id for update;
  if not found then raise exception 'Commande introuvable.'; end if;
  select * into v_payment from public.payments p where p.id = v_order.payment_id for update;
  if not coalesce(v_payment.debit_a_livraison, false) then raise exception 'Cette commande ne se règle pas à l''arrivée.'; end if;
  if v_payment.status = 'paid' then return jsonb_build_object('result', 'deja_paye'); end if;
  if v_payment.status not in ('requires_capture', 'capture_failed') then raise exception 'Paiement dans l''état « % ».', v_payment.status; end if;
  update public.payments set status = 'paid', paid_at = now(), captured_at = now(), reglement_echeance = null,
         last_error = 'Virement reçu (confirmé par SECOTO)', updated_at = now()
   where id = v_payment.id;
  perform secoto_private.od_issue_invoice(v_order.id);
  perform secoto_private.notify_event(v_order.account_id, 'payment', 'Virement reçu',
    format('Commande %s : votre virement de %s est bien reçu. Rien n''a été prélevé sur votre carte. Merci !', v_order.public_ref, secoto_private.reglement_eur(v_payment.amount_cents)),
    null, 'courses', 'od-virement-recu:' || v_order.id::text, v_order.id);
  perform secoto_private.audit('virement_recu', 'transport_order', v_order.id::text, '{}'::jsonb);
  return jsonb_build_object('result', 'paid');
end;
$$;
revoke all on function public.secoto_admin_virement_recu(uuid) from public, anon;
grant execute on function public.secoto_admin_virement_recu(uuid) to authenticated;

-- Marge reçue par virement du transporteur.
create or replace function public.secoto_admin_commission_reglee(p_commission_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_c public.commissions_dues%rowtype;
begin
  if not secoto_private.is_admin(auth.uid()) then raise exception 'Réservé à l''administrateur SECOTO.'; end if;
  select * into v_c from public.commissions_dues c where c.id = p_commission_id for update;
  if not found then raise exception 'Marge introuvable.'; end if;
  if v_c.statut <> 'due' then return jsonb_build_object('result', 'deja_reglee'); end if;
  update public.commissions_dues set statut = 'payee', paid_via = 'virement', paid_at = now(), updated_at = now() where id = v_c.id;
  perform secoto_private.notify_event(v_c.partner_id, 'payment', 'Marge réglée',
    'Merci : votre virement est reçu, la marge SECOTO est réglée.', null, 'offre', 'od-commission-payee:' || v_c.id::text, v_c.order_id);
  perform secoto_private.audit('commission_reglee', 'commission_due', v_c.id::text, '{}'::jsonb);
  return jsonb_build_object('result', 'payee');
end;
$$;
revoke all on function public.secoto_admin_commission_reglee(uuid) from public, anon;
grant execute on function public.secoto_admin_commission_reglee(uuid) to authenticated;

-- 12. AFFICHAGE -------------------------------------------------------------------------------
select secoto_private.mig074_patch('secoto_private.order_client_json(public.transport_orders)'::regprocedure,
  $a$'debit_a_confirmation', coalesce(p.debit_a_confirmation, false),$a$,
  $n$'debit_a_confirmation', coalesce(p.debit_a_confirmation, false),
    -- 100 : règlement à l'arrivée.
    'mode_reglement', o.mode_reglement, 'debit_a_livraison', coalesce(p.debit_a_livraison, false),
    'reglement_echeance', p.reglement_echeance, 'especes_statut', p.especes_statut,
    'reglement_a_payer', (coalesce(p.debit_a_livraison, false) and o.status = 'delivered'
        and p.status in ('requires_capture', 'capture_failed')
        and (o.mode_reglement is distinct from 'especes' or p.especes_statut = 'non_recu')),
    'virement', case when coalesce(p.debit_a_livraison, false) and o.mode_reglement = 'virement' and o.status = 'delivered'
        and p.status in ('requires_capture', 'capture_failed')
      then secoto_private.reglement_iban() || jsonb_build_object('reference', o.public_ref) end,
    'especes_possible', o.client_price_cents <= (secoto_private.reglement_num('plafond_especes_eur', 1000) * 100)::int,
    'virement_possible', secoto_private.reglement_iban() is not null,$n$);

-- Transporteur : il sait, avant d'accepter, s'il encaisse en espèces et ce qu'il reverse.
select secoto_private.mig074_patch('secoto_private.offer_partner_json(public.transport_offers)'::regprocedure,
  $a$'offre', o.offre, 'fenetre_fin', o.fenetre_fin,$a$,
  $n$'offre', o.offre, 'fenetre_fin', o.fenetre_fin,
    -- 100 : règlement en espèces à la livraison (le transporteur encaisse et reverse la marge).
    'mode_reglement', o.mode_reglement,
    'especes_a_encaisser_cents', case when o.mode_reglement = 'especes' then o.client_price_cents end,
    'commission_a_reverser_cents', case when o.mode_reglement = 'especes' then greatest(o.client_price_cents - o.partner_pay_cents, 0) end,$n$);

notify pgrst, 'reload schema';
