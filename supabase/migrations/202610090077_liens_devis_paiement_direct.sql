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
    -- Mission déjà livrée et réglée au transporteur par SECOTO (ancien
    -- circuit) : le client ne doit pas le payer une seconde fois.
    if exists (select 1 from public.partner_payouts pp
                where pp.mission_id = v_mission.id and pp.payment_circuit is distinct from 'direct'
                  and pp.status in ('paid', 'processing', 'failed')) then
      perform secoto_private.notify_admins_event('payment', 'Lien de paiement : transporteur déjà réglé',
        format('%s : le transporteur a déjà été réglé par SECOTO. Le paiement direct est bloqué ; encaissez le client autrement.',
          coalesce(v_mission.public_ref, v_mission.id::text)),
        'paiement', 'devis-direct-deja-regle:' || v_mission.id::text, v_mission.id);
      return jsonb_build_object('error', 'compte_introuvable');
    end if;
    -- Versement de l'ancien circuit encore à faire (mission livrée avant le
    -- paiement) : il bascule dans le circuit direct, aucun Transfer ne partira.
    update public.partner_payouts
       set payment_circuit = 'direct', connected_account_id = v_acct, partner_id = v_partner
     where mission_id = v_mission.id and payment_circuit is null and status = 'to_pay';
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
-- transporteur rejoint le circuit direct (secoto_private.trg_payout_circuit et
-- secoto_direct_payouts_claim_due, définis en 076) : jamais de Transfer depuis
-- SECOTO, virement de SON solde vers SA banque à l'échéance.

-- 4. LITIGES SUR UN PAIEMENT DIRECT DE MISSION MANUELLE ----------------------------------
-- Appelée par le webhook des comptes transporteurs : tant qu'un litige est
-- ouvert, rien n'est viré au transporteur.
create or replace function public.secoto_direct_dispute_event(p_payment_id uuid, p_open boolean)
returns jsonb language plpgsql volatile security definer set search_path = ''
as $f$
declare v public.payments%rowtype;
begin
  update public.payments set dispute_status = case when p_open then 'open' else 'closed' end, updated_at = now()
   where id = p_payment_id and payment_circuit = 'direct'
  returning * into v;
  if not found then return jsonb_build_object('skipped', true); end if;
  if p_open then
    perform secoto_private.notify_admins_event('payment', 'Litige client ouvert',
      format('Paiement %s : le client conteste chez sa banque. Le virement au transporteur est suspendu.', p_payment_id),
      'paiement', 'direct-dispute:' || p_payment_id::text, p_payment_id);
  end if;
  return jsonb_build_object('ok', true, 'dispute_status', v.dispute_status);
end;
$f$;
revoke all on function public.secoto_direct_dispute_event(uuid, boolean) from public, anon, authenticated;
grant execute on function public.secoto_direct_dispute_event(uuid, boolean) to service_role;

-- 5. CONTRÔLES BLOQUANTS --------------------------------------------------------------------
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
