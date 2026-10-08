-- ============================================================================
-- SECOTO 077 — Liens de paiement de devis plateau en paiement direct (D9)
-- ----------------------------------------------------------------------------
-- Interrupteur `plateau_paiement_direct` allumé, un lien de paiement de devis
-- plateau ne fait plus encaisser SECOTO :
--
--   A. Devis du transport à la demande (« Devis à établir », 040) : payer vaut
--      réserver, comme dans l'application. La commande naît dans le circuit
--      direct : le client enregistre sa carte (aucun débit), la demande part
--      aux transporteurs, le client est débité chez celui qui accepte.
--
--   B. Mission créée à la main (038) : le transporteur est déjà attribué. Le
--      client paie directement sur le compte Stripe de ce transporteur ; la
--      commission SECOTO (prix client - paie transporteur) est prélevée par
--      Stripe. Si le transporteur n'a pas encore activé le paiement direct, le
--      lien l'indique au client et SECOTO est prévenu : rien n'est encaissé
--      chez SECOTO.
--
-- Dans les deux cas, l'argent reste sur le solde du transporteur jusqu'à la
-- livraison + 4 h (076), puis il est viré vers sa banque.
--
-- Interrupteur éteint : comportement strictement identique à avant.
-- Le convoyage n'est jamais concerné. Migration additive et rejouable.
-- ============================================================================

-- 1. A — LA COMMANDE RÉSERVÉE PAR LIEN NAÎT DANS LE CIRCUIT DIRECT -----------------
select secoto_private.mig074_patch(
  'secoto_private.od_book_for_link(uuid)'::regprocedure,
  '  update public.transport_orders set payment_id = v_payment.id where id = v_order.id;',
  '  update public.transport_orders set payment_id = v_payment.id where id = v_order.id;
  -- 077 : plateau et moto, interrupteur allumé -> paiement direct au transporteur.
  if v_order.mode = ''plateau'' and secoto_private.flag(''plateau_paiement_direct'') then
    update public.payments set payment_circuit = ''direct'', capture_method = ''manual'', updated_at = now()
     where id = v_payment.id returning * into v_payment;
    update public.transport_orders set payment_circuit = ''direct'', payment_strategy = ''authorize_then_capture'', updated_at = now()
     where id = v_order.id;
  end if;');

-- 2. OUVERTURE DU LIEN ------------------------------------------------------------------
-- Réécrite à l'identique de la 040, plus les branches du circuit direct.
create or replace function public.secoto_devis_link_open(p_token text)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, secoto_private
as $function$
declare
  v_link    public.devis_payment_links%rowtype;
  v_mission public.missions%rowtype;
  v_quote   public.transport_quotes%rowtype;
  v_account uuid;
  v_payment public.payments%rowtype;
  v_direct  boolean := false;
  v_partner uuid;
  v_acct    text;
  v_fee     integer;
begin
  select * into v_link from public.devis_payment_links l where l.token = p_token for update;
  if not found then return jsonb_build_object('error', 'lien_inconnu'); end if;
  if v_link.paid_at is not null then return jsonb_build_object('error', 'deja_paye'); end if;
  if v_link.revoked_at is not null then return jsonb_build_object('error', 'lien_revoque'); end if;
  if v_link.expires_at <= now() then return jsonb_build_object('error', 'lien_expire'); end if;

  -- ---- Devis du transport a la demande ----------------------------------------
  if v_link.quote_id is not null then
    select * into v_quote from public.transport_quotes q where q.id = v_link.quote_id;
    if not found then return jsonb_build_object('error', 'lien_inconnu'); end if;

    -- 077 : carte déjà enregistrée (circuit direct), la demande est partie.
    if exists (select 1 from public.transport_orders o join public.payments p on p.id = o.payment_id
                where o.quote_id = v_link.quote_id and o.payment_circuit = 'direct'
                  and p.status = 'requires_capture') then
      return jsonb_build_object('error', 'carte_deja_validee');
    end if;

    begin
      v_payment := secoto_private.od_book_for_link(v_link.quote_id);
    exception
      when others then
        return jsonb_build_object('error', case
          when sqlerrm like '%DATE_DEPASSEE%' then 'date_depassee'
          when sqlerrm like '%PAIEMENTS_FERMES%' then 'compte_introuvable'
          when sqlerrm like '%COMMANDE_EN_COURS%' then 'deja_paye'
          else 'lien_inconnu' end);
    end;

    if v_payment.status = 'paid' then return jsonb_build_object('error', 'deja_paye'); end if;
    -- 077 : carte déjà enregistrée, la demande est partie aux transporteurs.
    if v_payment.payment_circuit = 'direct' and v_payment.status = 'requires_capture' then
      return jsonb_build_object('error', 'carte_deja_validee');
    end if;

    update public.devis_payment_links set payment_id = v_payment.id where id = v_link.id;

    return jsonb_build_object(
      'payment_id',      v_payment.id,
      'amount_cents',    v_payment.amount_cents,
      'currency',        v_payment.currency,
      'purpose',         v_payment.purpose,
      'waiver_required', coalesce(v_payment.waiver_required, false) and not coalesce(v_payment.waiver_accepted, false),
      'reference',       coalesce((select o.public_ref from public.transport_orders o where o.id = v_payment.order_id), ''),
      'trajet',          coalesce(v_quote.pickup ->> 'city', '') || ' - ' || coalesce(v_quote.delivery ->> 'city', ''),
      'vehicule',        coalesce(v_quote.vehicle ->> 'model', ''),
      'circuit',         v_payment.payment_circuit,
      'account_id',      v_payment.account_id
    );
  end if;

  -- ---- Mission creee a la main --------------------------------------------------
  select * into v_mission from public.missions m where m.id = v_link.mission_id;
  if not found then return jsonb_build_object('error', 'lien_inconnu'); end if;
  if v_mission.cancelled_at is not null then return jsonb_build_object('error', 'course_annulee'); end if;
  if lower(coalesce(v_mission.payment_method, '')) in ('especes', 'espèces', 'cash') then
    return jsonb_build_object('error', 'reglement_especes');
  end if;
  if coalesce(v_mission.payment_status, '') = 'paid' then return jsonb_build_object('error', 'deja_paye'); end if;

  -- 077 : plateau, interrupteur allumé -> le client paie le transporteur attribué.
  v_direct := v_mission.type::text = 'plateau' and secoto_private.flag('plateau_paiement_direct');
  if v_direct then
    v_partner := coalesce(secoto_private.beneficiaire_mission(v_mission.id), v_mission.assigned_transporter_id);
    if v_partner is null or not secoto_private.partner_direct_ready(v_partner) then
      perform secoto_private.notify_admins_event('payment', 'Lien de paiement en attente du transporteur',
        format('%s : le client a ouvert son lien de paiement, mais %s. Rien n''a été encaissé.',
          coalesce(v_mission.public_ref, v_mission.id::text),
          case when v_partner is null then 'aucun transporteur n''est attribué'
               else 'le transporteur n''a pas encore activé le paiement direct' end),
        'paiement', 'devis-direct-attente:' || v_mission.id::text, v_mission.id);
      return jsonb_build_object('error', 'transporteur_non_pret');
    end if;
    select a.stripe_connect_account_id into v_acct from public.accounts a where a.id = v_partner;
    v_fee := v_link.amount_cents - round(coalesce(v_mission.carrier_pay, 0) * 100)::int;
    if coalesce(v_mission.carrier_pay, 0) <= 0 or v_fee < 0 then
      perform secoto_private.notify_admins_event('payment', 'Lien de paiement : montants à vérifier',
        format('%s : paie du transporteur absente ou supérieure au prix client. Rien n''a été encaissé.',
          coalesce(v_mission.public_ref, v_mission.id::text)),
        'paiement', 'devis-direct-montants:' || v_mission.id::text, v_mission.id);
      return jsonb_build_object('error', 'compte_introuvable');
    end if;
  end if;

  v_account := v_mission.client_account_id;
  if v_account is null then
    select a.id into v_account from public.accounts a
     where a.role::text = 'admin' and a.deleted_at is null
     order by a.created_at limit 1;
  end if;
  if v_account is null then return jsonb_build_object('error', 'compte_introuvable'); end if;

  select * into v_payment from public.payments p
   where p.mission_id = v_link.mission_id
     and p.purpose = 'devis_course'
     and p.status in ('pending', 'processing')
     and p.amount_cents = v_link.amount_cents
     and coalesce(p.payment_circuit, '') = case when v_direct then 'direct' else '' end
     and (not v_direct or (p.connected_account_id = v_acct and p.application_fee_cents = v_fee))
   order by p.created_at desc limit 1;

  if not found then
    insert into public.payments (mission_id, account_id, purpose, amount_cents, currency, status,
                                 payment_circuit, connected_account_id, application_fee_cents)
    values (v_link.mission_id, v_account, 'devis_course', v_link.amount_cents, v_link.currency, 'pending',
            case when v_direct then 'direct' end, case when v_direct then v_acct end, case when v_direct then v_fee end)
    returning * into v_payment;
  end if;

  update public.devis_payment_links set payment_id = v_payment.id where id = v_link.id;

  return jsonb_build_object(
    'payment_id',      v_payment.id,
    'amount_cents',    v_payment.amount_cents,
    'currency',        v_payment.currency,
    'purpose',         v_payment.purpose,
    'waiver_required', false,
    'reference',       coalesce(v_mission.public_ref, ''),
    'trajet',          coalesce(v_mission.from_city, '') || ' - ' || coalesce(v_mission.to_city, ''),
    'vehicule',        coalesce(nullif(v_mission.vehicle, ''), ''),
    'circuit',         v_payment.payment_circuit,
    'connected_account_id', v_payment.connected_account_id,
    'application_fee_cents', v_payment.application_fee_cents
  );
end;
$function$;

revoke all on function public.secoto_devis_link_open(text) from public, anon, authenticated;
grant execute on function public.secoto_devis_link_open(text) to service_role;

-- 3. VERSEMENT DES MISSIONS MANUELLES PAYÉES EN DIRECT -------------------------------
-- La ligne de versement d'une mission manuelle payée directement chez le
-- transporteur rejoint le circuit direct : jamais de Transfer depuis SECOTO,
-- virement de SON solde vers SA banque à l'échéance (076).
create or replace function secoto_private.trg_payout_circuit()
returns trigger language plpgsql security definer set search_path = ''
as $f$
declare v_manuel boolean;
begin
  if new.payment_circuit is null and new.order_id is not null then
    select o.payment_circuit into new.payment_circuit from public.transport_orders o where o.id = new.order_id;
  end if;
  if new.payment_circuit = 'direct' and new.connected_account_id is null and new.order_id is not null then
    select p.connected_account_id into new.connected_account_id
      from public.transport_orders o join public.payments p on p.id = o.payment_id
     where o.id = new.order_id;
  end if;
  -- 077 : mission manuelle réglée par lien en paiement direct.
  if new.payment_circuit is null and new.order_id is null and new.mission_id is not null then
    select p.payment_circuit, p.connected_account_id into new.payment_circuit, new.connected_account_id
      from public.payments p
     where p.mission_id = new.mission_id and p.purpose = 'devis_course'
       and p.status = 'paid' and p.payment_circuit = 'direct'
     order by p.paid_at desc nulls last limit 1;
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

create or replace function public.secoto_direct_payouts_claim_due(p_limit integer default 20)
returns jsonb language plpgsql volatile security definer set search_path = ''
as $f$
declare v_rows jsonb;
begin
  with due as (
    select pp.id
      from public.partner_payouts pp
      left join public.transport_orders o on o.id = pp.order_id
      join public.payments p on p.id = coalesce(o.payment_id, (
             select p2.id from public.payments p2
              where pp.order_id is null and p2.mission_id = pp.mission_id
                and p2.purpose = 'devis_course' and p2.payment_circuit = 'direct'
              order by p2.paid_at desc nulls last limit 1))
     where pp.payment_circuit = 'direct'
       and (
             (pp.status = 'to_pay' and pp.due_at <= now() and coalesce(pp.next_retry_at, now()) <= now())
          or (pp.status = 'processing' and pp.processing_at < now() - interval '15 minutes')
           )
       and pp.amount_cents > 0
       and pp.connected_account_id is not null
       and p.status in ('paid', 'refunded', 'refund_pending')
       and coalesce(p.dispute_status, '') <> 'open'
       -- Mission manuelle : la ligne n'existe qu'une fois la mission livrée.
       and (pp.kind = 'late_cancel' or o.status = 'delivered' or pp.order_id is null)
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

-- 4. CONTRÔLES BLOQUANTS --------------------------------------------------------------------
do $controles$
begin
  if position('plateau_paiement_direct' in pg_get_functiondef('secoto_private.od_book_for_link(uuid)'::regprocedure)) = 0 then
    raise exception '077 : réservation par lien non adaptée';
  end if;
  if position('<> ''direct''' in pg_get_functiondef('public.secoto_payouts_claim_due(integer)'::regprocedure)) = 0 then
    raise exception '077 : les Transfers doivent toujours exclure le circuit direct';
  end if;
end;
$controles$;

notify pgrst, 'reload schema';
