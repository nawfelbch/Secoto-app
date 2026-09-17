-- ============================================================================
-- SECOTO — RETOUR ARRIÈRE DES MIGRATIONS 030 À 032
-- ----------------------------------------------------------------------------
-- NIVEAU 1 (recommandé, sans perte) : désactiver les fonctionnalités.
--   update public.secoto_feature_flags set enabled = false;
--   → plus de devis automatique, de paiement en ligne, d'abonnement, de
--     diffusion ni de suivi. Les parcours existants ne dépendent pas de 030-032.
--
-- NIVEAU 2 (ce fichier) : suppression des objets ajoutés.
--   ⚠ DÉTRUIT les données créées par ces parcours (devis, commandes, offres,
--   abonnements, positions GPS, journal). Avant exécution :
--     1. Sauvegarde PITR + export CSV des tables listées en §3.
--     2. Vérifier qu'aucun paiement Stripe « requires_capture » ou
--        « refund_pending » n'est en cours (requête §0).
--   Les colonnes ajoutées aux tables existantes (payments.*, notifications.ref_id,
--   documents.valid_until) sont CONSERVÉES : elles sont inertes et leur
--   suppression ferait perdre l'historique des paiements concernés.
-- ============================================================================

-- §0 — contrôle préalable (doit renvoyer 0 ligne)
-- select id, status, purpose from public.payments
--  where purpose in ('od_convoyage','od_plateau_commission','subscription_extension')
--    and status in ('pending','processing','requires_capture','refund_pending');

begin;

-- §1 — déclencheurs
drop trigger if exists trg_secoto_od_sync_from_mission on public.missions;
drop trigger if exists trg_secoto_live_autostop on public.missions;
drop trigger if exists trg_secoto_extension_payment on public.payments;
drop policy if exists secoto_business_private_read on storage.objects;
drop policy if exists secoto_business_private_insert on storage.objects;

-- §2 — fonctions restaurées dans leur version antérieure (migration 009/024)
CREATE OR REPLACE FUNCTION secoto_private.prepare_notification()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  new.push_screen := case
    when new.push_screen in (
      'courses','documents','frais','available','assigned',
      'applications','requests','paiement','transporters'
    ) then new.push_screen
    when new.type = 'document' then 'documents'
    when new.type in ('frais','frais_status') then 'frais'
    when new.type = 'new_application' then 'applications'
    when new.type = 'new_request' then 'requests'
    when new.type = 'new_course' then 'available'
    when new.type in ('payment','payment_failed') then 'paiement'
    when new.type = 'new_account' then 'transporters'
    when new.type in ('tracking','delivered','course_assigned','cancellation') then 'courses'
    else 'courses'
  end;
  new.event_key := coalesce(new.event_key, 'notification:' || new.id::text);
  return new;
end;
$function$;

CREATE OR REPLACE FUNCTION public.secoto_prepare_delivery_payment(p_mission_id uuid, p_idempotency_key uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_user_id uuid := secoto_private.assert_authenticated();
  v_existing jsonb;
  v_mission public.missions%rowtype;
  v_payment public.payments%rowtype;
begin
  v_existing := secoto_private.lock_operation('prepare_delivery_payment', p_idempotency_key);
  if v_existing is not null then return v_existing; end if;

  select * into v_mission from public.missions m where m.id = p_mission_id;
  if not found then raise exception 'Mission introuvable.'; end if;
  if v_mission.type::text <> 'convoyage' then
    raise exception 'Paiement a la livraison reserve au convoyage.';
  end if;

  -- Le convoyeur n'encaisse JAMAIS en direct : il ne fait que declencher le
  -- lien de paiement, dont le produit arrive integralement chez SECOTO.
  if not (
    secoto_private.is_admin(v_user_id)
    or v_mission.assigned_transporter_id = v_user_id
    or v_mission.client_account_id = v_user_id
  ) then
    raise exception 'Action non autorisee sur cette mission.';
  end if;
  if coalesce(v_mission.client_price, 0) <= 0 then
    raise exception 'Montant de la mission indisponible.';
  end if;
  if v_mission.client_account_id is null then
    raise exception 'Cette mission n''est reliee a aucun compte client.';
  end if;

  select * into v_payment from public.payments p
   where p.mission_id = p_mission_id
     and p.purpose = 'convoyage_livraison'
     and p.status in ('pending', 'processing', 'paid', 'refund_pending');

  if not found then
    insert into public.payments(
      mission_id, account_id, purpose, amount_cents, status, waiver_required
    )
    values (
      p_mission_id, v_mission.client_account_id, 'convoyage_livraison',
      (round(
        (v_mission.client_price + coalesce((
          select sum(f.montant) from public.frais f
          where f.mission_id = p_mission_id and f.statut::text = 'valide'
        ), 0)) * 100))::integer,
      'pending', false
    )
    returning * into v_payment;

    update public.missions set payment_status = 'awaiting_payment' where id = p_mission_id;
  end if;

  return secoto_private.finish_operation(
    'prepare_delivery_payment',
    p_idempotency_key,
    jsonb_build_object(
      'payment_id',   v_payment.id,
      'status',       v_payment.status,
      'amount_cents', v_payment.amount_cents
    )
  );
end;
$function$;

-- §3 — tables ajoutées
drop table if exists public.mission_live_eta, public.mission_live_positions, public.mission_live_sessions cascade;
alter table public.payments drop constraint if exists payments_order_id_fkey;
alter table public.payments drop column if exists subscription_extension_id;
drop table if exists public.subscription_extensions, public.subscription_reservations, public.subscription_billing_events,
  public.subscriptions, public.subscription_proposals, public.eligibility_files, public.eligibility_history_rows,
  public.eligibility_applications cascade;
drop table if exists public.partner_payouts, public.transport_offers, public.transport_orders, public.transport_quotes,
  public.partner_dispatch_preferences, public.pricing_grids, public.business_members, public.business_accounts,
  public.secoto_audit_log, public.secoto_feature_flags cascade;
delete from public.app_settings where key in ('dispatch_policy', 'subscription_policy', 'live_tracking_policy');

-- §4 — contraintes de paiement : retour aux valeurs d'origine UNIQUEMENT si
-- aucune ligne n'utilise les nouvelles valeurs (sinon on conserve l'élargi).
do $restore$
begin
  if not exists (select 1 from public.payments where purpose not in ('commission_plateau', 'convoyage_livraison')
                 or status not in ('pending','processing','paid','failed','refund_pending','refunded','cancelled')) then
    alter table public.payments drop constraint if exists payments_purpose_check;
    alter table public.payments add constraint payments_purpose_check check (purpose in ('commission_plateau', 'convoyage_livraison'));
    alter table public.payments drop constraint if exists payments_status_check;
    alter table public.payments add constraint payments_status_check
      check (status in ('pending','processing','paid','failed','refund_pending','refunded','cancelled'));
  else
    raise notice 'Des paiements utilisent les nouvelles valeurs : contraintes élargies conservées.';
  end if;
  alter table public.payments drop constraint if exists payments_target_check;
  alter table public.payments drop constraint if exists payments_capture_method_check;
  drop index if exists public.payments_order_live_key;
  if not exists (select 1 from public.payments where mission_id is null) then
    alter table public.payments alter column mission_id set not null;
  end if;
end
$restore$;

-- §5 — fonctions ajoutées
drop function if exists public.secoto_admin_accounting_export(date,date) cascade;
drop function if exists public.secoto_admin_activate_grid(uuid) cascade;
drop function if exists public.secoto_admin_audit_log(text,text,integer) cascade;
drop function if exists public.secoto_admin_create_grid_version(text,jsonb,text) cascade;
drop function if exists public.secoto_admin_eligibility_list() cascade;
drop function if exists public.secoto_admin_eligibility_summary(uuid) cascade;
drop function if exists public.secoto_admin_mark_payout_paid(uuid,text) cascade;
drop function if exists public.secoto_admin_od_cancel_order(uuid,text,boolean) cascade;
drop function if exists public.secoto_admin_od_lock_for_partner(uuid,uuid) cascade;
drop function if exists public.secoto_admin_od_orders(text) cascade;
drop function if exists public.secoto_admin_od_rebroadcast(uuid) cascade;
drop function if exists public.secoto_admin_od_replace_partner(uuid,text) cascade;
drop function if exists public.secoto_admin_od_set_partner_pay(uuid,integer,boolean,text) cascade;
drop function if exists public.secoto_admin_partner_compliance() cascade;
drop function if exists public.secoto_admin_partner_payouts(text) cascade;
drop function if exists public.secoto_admin_price_extension(uuid,integer,integer) cascade;
drop function if exists public.secoto_admin_price_quote(uuid,integer,integer,integer,text,boolean) cascade;
drop function if exists public.secoto_admin_pricing_grids() cascade;
drop function if exists public.secoto_admin_quotes(text) cascade;
drop function if exists public.secoto_admin_save_proposal(jsonb) cascade;
drop function if exists public.secoto_admin_send_proposal(uuid) cascade;
drop function if exists public.secoto_admin_set_application_status(uuid,text,text) cascade;
drop function if exists public.secoto_admin_set_document_validity(uuid,date) cascade;
drop function if exists public.secoto_admin_set_feature_flag(text,boolean) cascade;
drop function if exists public.secoto_admin_simulate_price(uuid,numeric,jsonb,numeric) cascade;
drop function if exists public.secoto_admin_subscriptions() cascade;
drop function if exists public.secoto_business_ensure(text,text) cascade;
drop function if exists public.secoto_eligibility_register_file(uuid,text,text,text,text,bigint) cascade;
drop function if exists public.secoto_eligibility_replace_rows(uuid,jsonb) cascade;
drop function if exists public.secoto_eligibility_rows(uuid) cascade;
drop function if exists public.secoto_eligibility_save_questionnaire(uuid,jsonb) cascade;
drop function if exists public.secoto_eligibility_start(text,text) cascade;
drop function if exists public.secoto_eligibility_submit(uuid) cascade;
drop function if exists public.secoto_feature_flags() cascade;
drop function if exists public.secoto_live_eta_targets() cascade;
drop function if exists public.secoto_live_purge() cascade;
drop function if exists public.secoto_live_push_positions(uuid,jsonb) cascade;
drop function if exists public.secoto_live_set_eta(uuid,timestamp with time zone,numeric,text,timestamp with time zone,boolean) cascade;
drop function if exists public.secoto_live_start(uuid,boolean) cascade;
drop function if exists public.secoto_live_stop(uuid) cascade;
drop function if exists public.secoto_live_view(uuid) cascade;
drop function if exists public.secoto_my_businesses() cascade;
drop function if exists public.secoto_my_dispatch_preferences() cascade;
drop function if exists public.secoto_my_offers() cascade;
drop function if exists public.secoto_my_quotes() cascade;
drop function if exists public.secoto_od_apply_payment_event(uuid,text,text,text,integer,timestamp with time zone,text) cascade;
drop function if exists public.secoto_od_book_quote(uuid,boolean,uuid) cascade;
drop function if exists public.secoto_od_cancel_order(uuid,uuid) cascade;
drop function if exists public.secoto_od_capture_result(uuid,boolean,text) cascade;
drop function if exists public.secoto_od_maintenance_tick() cascade;
drop function if exists public.secoto_od_my_orders() cascade;
drop function if exists public.secoto_od_payment_action_result(uuid,text,boolean,text) cascade;
drop function if exists public.secoto_offer_accept(uuid,uuid) cascade;
drop function if exists public.secoto_offer_decline(uuid) cascade;
drop function if exists public.secoto_offer_get(uuid) cascade;
drop function if exists public.secoto_offer_mark_seen(uuid) cascade;
drop function if exists secoto_private.assert_application_editable(uuid) cascade;
drop function if exists secoto_private.audit(text,text,text,jsonb) cascade;
drop function if exists secoto_private.department_of(text) cascade;
drop function if exists secoto_private.flag(text) cascade;
drop function if exists secoto_private.is_business_member(uuid,uuid) cascade;
drop function if exists secoto_private.live_num(text,numeric) cascade;
drop function if exists secoto_private.live_stop(uuid,text) cascade;
drop function if exists secoto_private.new_order_ref() cascade;
drop function if exists secoto_private.notify_admins_event(text,text,text,text,text,uuid) cascade;
drop function if exists secoto_private.notify_event(uuid,text,text,text,uuid,text,text,uuid) cascade;
drop function if exists secoto_private.od_broadcast(uuid) cascade;
drop function if exists secoto_private.od_confirm(uuid) cascade;
drop function if exists secoto_private.od_open_dispatch(uuid) cascade;
drop function if exists secoto_private.od_partner_eligible(uuid,uuid) cascade;
drop function if exists secoto_private.od_release_lock(uuid,text) cascade;
drop function if exists secoto_private.od_stop_order(uuid,text,text) cascade;
drop function if exists secoto_private.od_try_accept(uuid,uuid,uuid) cascade;
drop function if exists secoto_private.offer_partner_json(transport_offers) cascade;
drop function if exists secoto_private.order_client_json(transport_orders) cascade;
drop function if exists secoto_private.partner_documents_valid(uuid) cascade;
drop function if exists secoto_private.policy_num(text,numeric) cascade;
drop function if exists secoto_private.price_with_grid(text,jsonb,numeric,jsonb,numeric) cascade;
drop function if exists secoto_private.proposal_client_json(subscription_proposals) cascade;
drop function if exists secoto_private.quote_client_json(transport_quotes) cascade;
drop function if exists secoto_private.sub_attach_mission(uuid,uuid) cascade;
drop function if exists secoto_private.sub_consume_for_order(uuid) cascade;
drop function if exists secoto_private.sub_policy_num(text,numeric) cascade;
drop function if exists secoto_private.sub_release_for_order(uuid,text) cascade;
drop function if exists secoto_private.sub_reserve_for_order(uuid) cascade;
drop function if exists secoto_private.sub_usage(subscriptions) cascade;
drop function if exists secoto_private.sub_worst_case(integer,jsonb,integer,integer) cascade;
drop function if exists secoto_private.trg_extension_payment() cascade;
drop function if exists secoto_private.trg_live_autostop() cascade;
drop function if exists secoto_private.trg_od_sync_from_mission() cascade;
drop function if exists secoto_private.validate_grid_params(text,jsonb) cascade;
drop function if exists public.secoto_quote_create(uuid,jsonb,jsonb) cascade;
drop function if exists public.secoto_sub_accept_extension(uuid) cascade;
drop function if exists public.secoto_sub_accept_proposal(uuid) cascade;
drop function if exists public.secoto_sub_apply_billing_event(uuid,text,text,text,timestamp with time zone,timestamp with time zone) cascade;
drop function if exists public.secoto_sub_decline_proposal(uuid) cascade;
drop function if exists public.secoto_sub_maintenance_tick() cascade;
drop function if exists public.secoto_sub_my_overview() cascade;
drop function if exists public.secoto_sub_request_cancel(uuid) cascade;
drop function if exists public.secoto_sub_request_extension(uuid,text,integer,integer,text) cascade;
drop function if exists public.secoto_update_dispatch_preferences(jsonb) cascade;

-- Le bucket « business-private » n'est pas supprimé automatiquement :
-- videz-le depuis la console Storage après export, puis supprimez-le.

notify pgrst, 'reload schema';
commit;
