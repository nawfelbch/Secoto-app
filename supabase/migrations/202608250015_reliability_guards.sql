-- ============================================================================
-- SECOTO — migration 015 : garde-fous de fiabilité RPC et paiement.
-- ----------------------------------------------------------------------------
-- 1. Incident du 25/08/2026 : deux surcharges de secoto_apply_to_mission
--    coexistaient (mêmes paramètres, ordre différent) → PostgREST refusait de
--    choisir et TOUTE candidature transporteur échouait. `create or replace`
--    ne remplace pas une fonction dont l'ordre des paramètres a changé : il en
--    AJOUTE une. On supprime donc explicitement toutes les surcharges avant de
--    recréer l'unique signature canonique.
-- 2. Le webhook Stripe peut recevoir les événements dans le désordre : un
--    « failed » retardataire ne doit jamais écraser un paiement encaissé.
-- 3. Garde de déploiement : aucune fonction public.secoto_% ne doit exister
--    en plusieurs exemplaires — sinon la migration échoue immédiatement.
-- Transactionnel, idempotent, aucune donnée modifiée.
-- ============================================================================

begin;

-- ----------------------------------------------------------------------------
-- 1. Une seule signature pour secoto_apply_to_mission
-- ----------------------------------------------------------------------------

do $dedupe$
declare
  v_fn record;
begin
  for v_fn in
    select p.oid::regprocedure as signature
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname = 'secoto_apply_to_mission'
  loop
    execute format('drop function %s', v_fn.signature);
  end loop;
end
$dedupe$;

-- Recréation de la signature canonique — identique à la migration 013.
-- Règle définitive : ne JAMAIS réordonner les paramètres d'une fonction
-- exposée via PostgREST ; tout nouveau paramètre s'ajoute À LA FIN avec un
-- DEFAULT.
create or replace function public.secoto_apply_to_mission(
  p_mission_id uuid,
  p_proposed_price numeric,
  p_message text,
  p_idempotency_key uuid,
  p_pickup_earliest_at timestamptz,
  p_pickup_latest_at timestamptz,
  p_delivery_earliest_at timestamptz,
  p_delivery_latest_at timestamptz,
  p_proposed_price_grouped numeric
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $function$
declare
  v_user_id uuid := secoto_private.assert_authenticated();
  v_account public.accounts%rowtype;
  v_mission public.missions%rowtype;
  v_application public.mission_applications%rowtype;
  v_existing jsonb;
begin
  if not secoto_private.is_verified_transporter(v_user_id) then
    raise exception 'Compte transporteur vérifié requis.';
  end if;
  if p_proposed_price is null
     or p_proposed_price <= 0
     or p_proposed_price > 1000000 then
    raise exception 'Tarif proposé invalide.';
  end if;
  if p_proposed_price_grouped is not null
     and (p_proposed_price_grouped <= 0 or p_proposed_price_grouped > 1000000) then
    raise exception 'Tarif groupé invalide.';
  end if;
  if p_pickup_earliest_at is null or p_pickup_latest_at is null
     or p_delivery_earliest_at is null or p_delivery_latest_at is null then
    raise exception 'Toutes les disponibilités sont obligatoires.';
  end if;
  if p_pickup_earliest_at > p_pickup_latest_at then
    raise exception 'La disponibilité d''enlèvement est invalide.';
  end if;
  if p_delivery_earliest_at > p_delivery_latest_at then
    raise exception 'La disponibilité de livraison est invalide.';
  end if;
  if p_message is not null and length(p_message) > 2000 then
    raise exception 'Message de candidature trop long.';
  end if;

  v_existing := secoto_private.lock_operation(
    'apply_to_mission', p_idempotency_key
  );
  if v_existing is not null then return v_existing; end if;

  select * into v_mission
  from public.missions m
  where m.id = p_mission_id
  for update;
  if not found
     or v_mission.status::text <> 'published'
     or v_mission.assigned_transporter_id is not null then
    raise exception 'Cette mission n''accepte plus de candidature.';
  end if;
  if not secoto_private.transporter_matches_mission(v_user_id, p_mission_id) then
    raise exception 'Cette mission ne correspond pas à vos capacités transport validées.'
      using errcode = '42501';
  end if;

  select * into v_account from public.accounts a where a.id = v_user_id;

  insert into public.mission_applications(
    mission_id, transporter_id, transporter_name, transporter_company,
    transporter_status, message, proposed_price, proposed_price_grouped,
    pickup_earliest_at, pickup_latest_at,
    delivery_earliest_at, delivery_latest_at,
    price_note, status
  ) values (
    p_mission_id, v_user_id, v_account.full_name, v_account.company_name,
    'verified', nullif(btrim(p_message), ''), round(p_proposed_price, 2),
    case when p_proposed_price_grouped is null then null
         else round(p_proposed_price_grouped, 2) end,
    p_pickup_earliest_at, p_pickup_latest_at,
    p_delivery_earliest_at, p_delivery_latest_at,
    null, 'pending'
  ) returning * into v_application;

  perform secoto_private.notify_admins(
    'new_application', p_mission_id, 'applications',
    'application:' || v_application.id::text
  );

  return secoto_private.finish_operation(
    'apply_to_mission', p_idempotency_key, to_jsonb(v_application)
  );
exception
  when unique_violation then
    raise exception using
      errcode = '23505',
      message = 'Vous avez déjà candidaté à cette mission.';
end;
$function$;


revoke all on function public.secoto_apply_to_mission(
  uuid, numeric, text, uuid, timestamptz, timestamptz,
  timestamptz, timestamptz, numeric
) from public, anon;
grant execute on function public.secoto_apply_to_mission(
  uuid, numeric, text, uuid, timestamptz, timestamptz,
  timestamptz, timestamptz, numeric
) to authenticated;

-- ----------------------------------------------------------------------------
-- 2. Un paiement encaissé est définitif (sauf remboursement)
-- ----------------------------------------------------------------------------

create or replace function public.secoto_settle_payment(
  p_payment_id uuid,
  p_provider_intent_id text,
  p_status text,
  p_provider_event_id text,
  p_error text
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $function$
declare
  v_payment public.payments%rowtype;
  v_mission public.missions%rowtype;
  v_released text := '';
begin
  if p_status not in ('processing', 'paid', 'failed', 'refunded', 'cancelled') then
    raise exception 'Statut de paiement non autorise.';
  end if;

  select * into v_payment from public.payments p where p.id = p_payment_id for update;
  if not found then raise exception 'Paiement introuvable.'; end if;

  -- Idempotence stricte : un événement Stripe rejoué ne rejoue rien.
  if p_provider_event_id is not null
     and exists (
       select 1 from public.payment_events e
       where e.provider_event_id = p_provider_event_id
     ) then
    return jsonb_build_object('skipped', true, 'reason', 'event_already_processed');
  end if;

  if v_payment.status = 'paid' and p_status = 'paid' then
    return jsonb_build_object('skipped', true, 'reason', 'already_paid');
  end if;

  -- Stripe ne garantit pas l'ordre d'arrivée des événements : un « failed »,
  -- « cancelled » ou « processing » retardataire ne doit JAMAIS écraser un
  -- paiement déjà encaissé (le bon de mission est déjà parti). Seul un
  -- remboursement peut suivre un encaissement.
  if v_payment.status = 'paid' and p_status <> 'refunded' then
    return jsonb_build_object('skipped', true, 'reason', 'paid_is_final');
  end if;

  update public.payments
     set status             = p_status,
         provider_intent_id = coalesce(p_provider_intent_id, provider_intent_id),
         paid_at            = case when p_status = 'paid' then now() else paid_at end,
         failed_at          = case when p_status = 'failed' then now() else failed_at end,
         last_error         = case when p_status = 'failed' then left(coalesce(p_error, ''), 500) else last_error end,
         refunded_amount_cents = case when p_status = 'refunded' then amount_cents else refunded_amount_cents end,
         updated_at         = now()
   where id = p_payment_id
  returning * into v_payment;

  insert into public.payment_events(payment_id, event_type, provider_event_id, payload)
  values (
    p_payment_id, p_status, p_provider_event_id,
    jsonb_build_object('intent', p_provider_intent_id, 'error', p_error)
  )
  on conflict (provider_event_id) where provider_event_id is not null do nothing;

  select * into v_mission from public.missions m where m.id = v_payment.mission_id;

  if p_status = 'paid' then
    update public.missions
       set payment_status = 'paid',
           commission_paid_at = case
             when v_payment.purpose = 'commission_plateau' then now()
             else commission_paid_at end
     where id = v_payment.mission_id;

    -- ⚑ LE VERROU. Jusqu'ici le bon partait dès la signature du devis.
    if v_payment.purpose = 'commission_plateau' then
      v_released := public.secoto_release_mission_order(v_payment.mission_id);
    end if;

    perform secoto_private.notify_admins(
      'payment', v_payment.mission_id, 'paiement',
      'payment:' || p_payment_id::text || ':paid'
    );
    perform secoto_private.notify_one(
      v_payment.account_id, 'payment', v_payment.mission_id, 'paiement',
      'payment:' || p_payment_id::text || ':paid:client'
    );
    perform secoto_private.queue_email(
      v_payment.account_id,
      'SECOTO — confirmation de votre reservation',
      'Votre reservation de creneau est confirmee.' || chr(10) || chr(10)
      || 'Frais de reservation SECOTO (20 %) : '
      || public.secoto_fmt_amount(v_payment.amount_cents / 100.0) || chr(10)
      || 'Prix du transport, regle directement au transporteur : '
      || public.secoto_fmt_amount(coalesce(v_mission.transport_amount, 0)) || chr(10) || chr(10)
      || (select value ->> 'commission_notice' from public.app_settings where key = 'legal_texts')
      || chr(10) || chr(10)
      || 'Vous avez demande expressement l''execution immediate de la prestation '
      || 'de mise en relation et renonce a votre droit de retractation de 14 jours.'
      || chr(10) || chr(10)
      || (select value ->> 'refund_policy' from public.app_settings where key = 'legal_texts'),
      v_payment.mission_id,
      'email:payment:' || p_payment_id::text || ':paid'
    );

  elsif p_status = 'failed' then
    update public.missions set payment_status = 'failed' where id = v_payment.mission_id;
    perform secoto_private.notify_admins(
      'payment_failed', v_payment.mission_id, 'paiement',
      'payment:' || p_payment_id::text || ':failed'
    );
    perform secoto_private.notify_one(
      v_payment.account_id, 'payment_failed', v_payment.mission_id, 'paiement',
      'payment:' || p_payment_id::text || ':failed:client'
    );
    perform secoto_private.queue_email(
      v_payment.account_id,
      'SECOTO — votre paiement n''a pas abouti',
      'Votre paiement n''a pas pu etre encaisse. Votre creneau n''est pas '
      || 'reserve tant que la commission n''est pas reglee. Vous pouvez '
      || 'reessayer depuis l''application SECOTO.',
      v_payment.mission_id,
      'email:payment:' || p_payment_id::text || ':failed'
    );

  elsif p_status = 'refunded' then
    update public.missions set payment_status = 'refunded' where id = v_payment.mission_id;
    perform secoto_private.notify_one(
      v_payment.account_id, 'payment', v_payment.mission_id, 'paiement',
      'payment:' || p_payment_id::text || ':refunded:client'
    );
  end if;

  return jsonb_build_object(
    'payment_id', p_payment_id,
    'status', p_status,
    'released', v_released
  );
end;
$function$;


revoke all on function public.secoto_settle_payment(uuid, text, text, text, text)
  from public, anon, authenticated;
grant execute on function public.secoto_settle_payment(uuid, text, text, text, text)
  to service_role;

-- ----------------------------------------------------------------------------
-- 3. Garde de déploiement : zéro doublon de fonction exposée
-- ----------------------------------------------------------------------------

do $guard$
declare
  v_dup record;
begin
  for v_dup in
    select p.proname, count(*) as copies
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname like 'secoto\_%'
    group by p.proname
    having count(*) > 1
  loop
    raise exception
      'Fonction public.% présente en % exemplaires : surcharge ambiguë pour PostgREST, dédoublonner avant de continuer.',
      v_dup.proname, v_dup.copies;
  end loop;
end
$guard$;

notify pgrst, 'reload schema';

commit;
