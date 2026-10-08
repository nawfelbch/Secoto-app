-- ============================================================================
-- SECOTO 078 — Commission due par le client (D4), derrière interrupteur
-- ----------------------------------------------------------------------------
-- EN ATTENTE DE VALIDATION COMPTABLE. Interrupteur `commission_client` éteint :
-- rien ne change (facture du transporteur pour le montant total, commission
-- facturée au transporteur, schéma 074).
--
-- Allumé, pour les commandes plateau en paiement direct réservées ensuite :
--   • le transporteur facture (via le mandat) le seul PRIX DU TRANSPORT ;
--   • SECOTO facture sa COMMISSION DE MISE EN RELATION au CLIENT ;
--   • le paiement reste unique pour le client (une seule validation) :
--     Stripe prélève la commission sur le paiement encaissé chez le
--     transporteur (application_fee_amount) et la reverse à SECOTO.
-- Le choix est figé sur la commande au moment de la réservation : changer
-- l'interrupteur ne modifie jamais une commande déjà réservée.
--
-- Le transporteur ne voit toujours ni le prix client ni la commission.
-- Migration additive et rejouable.
-- ============================================================================

-- 1. COLONNE FIGÉE À LA RÉSERVATION ----------------------------------------------------
alter table public.transport_orders add column if not exists commission_payer text
  check (commission_payer is null or commission_payer in ('client', 'transporteur'));
comment on column public.transport_orders.commission_payer is
  'Paiement direct : qui doit la commission SECOTO (client = facture SECOTO au client). NULL = schéma 074 (transporteur).';

select secoto_private.mig074_patch(
  'public.secoto_od_book_quote(uuid, boolean, uuid)'::regprocedure,
  '      update public.transport_orders set payment_circuit = ''direct'', payment_strategy = ''authorize_then_capture'', updated_at = now()',
  '      update public.transport_orders set payment_circuit = ''direct'', payment_strategy = ''authorize_then_capture'', updated_at = now(),
             commission_payer = case when secoto_private.flag(''commission_client'') then ''client'' end');
select secoto_private.mig074_patch(
  'secoto_private.od_book_for_link(uuid)'::regprocedure,
  '    update public.transport_orders set payment_circuit = ''direct'', payment_strategy = ''authorize_then_capture'', updated_at = now()',
  '    update public.transport_orders set payment_circuit = ''direct'', payment_strategy = ''authorize_then_capture'', updated_at = now(),
           commission_payer = case when secoto_private.flag(''commission_client'') then ''client'' end');

-- 2. NOUVELLE SORTE DE FACTURE ET LECTURE --------------------------------------------------
alter table public.partner_invoices drop constraint if exists partner_invoices_kind_check;
alter table public.partner_invoices add constraint partner_invoices_kind_check
  check (kind in ('client_on_behalf', 'commission', 'commission_client'));

-- Le client lit ses deux factures ; le transporteur ne lit jamais la facture
-- de commission adressée au client (elle porte le prix client).
drop policy if exists partner_invoices_read on public.partner_invoices;
create policy partner_invoices_read on public.partner_invoices for select to authenticated
  using (
    (partner_id = auth.uid() and kind <> 'commission_client')
    or (kind in ('client_on_behalf', 'commission_client') and client_id = auth.uid())
    or secoto_private.current_is_admin()
  );

-- 3. FACTURES DU CIRCUIT DIRECT -------------------------------------------------------------
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
  -- 078 (D4, en attente de validation comptable) : commission due par le client.
  v_client_paie boolean;
  v_montant_tr integer;
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
  v_client_paie := coalesce(v_order.commission_payer = 'client', false);
  -- Commission due par le client : la facture du transporteur ne porte que le
  -- prix du transport ; SECOTO facture sa commission au client, à part.
  v_montant_tr := case when v_client_paie then v_order.client_price_cents - v_fee else v_order.client_price_cents end;

  insert into public.partner_invoice_counters(partner_id, year, last_number) values (v_partner_id, v_year, 1)
  on conflict (partner_id, year) do update set last_number = public.partner_invoice_counters.last_number + 1
  returning last_number into v_n;
  v_num := 'TR' || v_year || '-' || lpad(v_n::text, 4, '0');

  -- Mention TVA selon le régime déclaré par le transporteur (à valider par
  -- l'expert-comptable avant activation).
  v_vat_line := case
    when v_partner.billing_vat_regime = 'assujetti' then
      'Montant TTC. TVA (20 %) incluse : ' || to_char(round(v_montant_tr - v_montant_tr / 1.2) / 100.0, 'FM999990D00') || ' EUR'
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
    case when v_client_paie then
      'Prix du transport : ' || to_char(v_montant_tr / 100.0, 'FM999990D00') || ' EUR' || E'\n' ||
      'La commission de mise en relation SECOTO fait l''objet d''une facture distincte de SECOTO.' || E'\n'
    else
      'Total paye : ' || to_char(v_order.client_price_cents / 100.0, 'FM999990D00') || ' EUR' || E'\n'
    end ||
    v_vat_line || E'\n\n' ||
    'Paiement encaisse par ' || coalesce(v_partner.billing_legal_name, 'le transporteur') || ', via SECOTO (mise en relation).' || E'\n' ||
    'Annulation : remboursement integral plus de 24 h avant l''enlevement ; 50 % entre 24 h et 2 h ; aucun remboursement a moins de 2 h.';

  insert into public.partner_invoices(order_id, partner_id, client_id, kind, number, amount_cents, body)
  values (p_order_id, v_partner_id, v_order.account_id, 'client_on_behalf', v_num, v_montant_tr, v_body)
  on conflict (order_id, kind) do nothing;

  update public.transport_orders set invoice_number = v_num, invoiced_at = now(), updated_at = now() where id = p_order_id;

  perform secoto_private.queue_email(v_order.account_id,
    'SECOTO - Facture ' || v_num || ' - commande ' || v_order.public_ref, v_body, v_order.mission_id, 'od-direct-invoice:' || p_order_id::text);
  perform secoto_private.queue_email(v_partner_id,
    'SECOTO - Copie de la facture ' || v_num || ' emise en votre nom - ' || v_order.public_ref, v_body, v_order.mission_id, 'od-direct-invoice-copy:' || p_order_id::text);

  -- 078 : commission due par le client -> facture SECOTO au CLIENT, invisible
  -- du transporteur (cloisonnement inchangé pour lui).
  if v_client_paie and v_fee > 0 then
    v_fac := secoto_private.next_doc_number('FAC');
    v_body_fee :=
      'Facture ' || v_fac || E'\n' ||
      'SECOTO - SIREN 951 857 531 - intermediaire de mise en relation' || E'\n\n' ||
      'Client : ' || coalesce(v_client.company_name, v_client.full_name, '') || E'\n' ||
      'Objet : commission de mise en relation - commande ' || v_order.public_ref || E'\n\n' ||
      'Montant : ' || to_char(v_fee / 100.0, 'FM999990D00') || ' EUR' || E'\n' ||
      secoto_private.policy_text('tva', 'TVA non applicable, article 293 B du CGI.') || E'\n\n' ||
      'Reglee avec le paiement du transport (' || to_char(v_order.client_price_cents / 100.0, 'FM999990D00') ||
        ' EUR au total), et reversee a SECOTO par le prestataire de paiement Stripe.';
    insert into public.partner_invoices(order_id, partner_id, client_id, kind, number, amount_cents, body)
    values (p_order_id, v_partner_id, v_order.account_id, 'commission_client', v_fac, v_fee, v_body_fee)
    on conflict (order_id, kind) do nothing;
    perform secoto_private.queue_email(v_order.account_id,
      'SECOTO - Facture ' || v_fac || ' - commission de mise en relation ' || v_order.public_ref, v_body_fee, v_order.mission_id,
      'od-direct-commission-client:' || p_order_id::text);
  end if;

  -- Facture de commission SECOTO au transporteur (prélevée à la source).
  if not v_client_paie and v_fee > 0 then
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

-- 4. CONTRÔLES BLOQUANTS ---------------------------------------------------------------------
do $controles$
begin
  if position('commission_client' in pg_get_functiondef('public.secoto_od_book_quote(uuid, boolean, uuid)'::regprocedure)) = 0 then
    raise exception '078 : réservation non adaptée';
  end if;
  if position('commission_client' in pg_get_functiondef('secoto_private.od_book_for_link(uuid)'::regprocedure)) = 0 then
    raise exception '078 : réservation par lien non adaptée';
  end if;
  if exists (select 1 from public.secoto_feature_flags where key = 'commission_client' and enabled) then
    raise notice '078 : interrupteur commission_client déjà ALLUMÉ.';
  end if;
end;
$controles$;

notify pgrst, 'reload schema';
