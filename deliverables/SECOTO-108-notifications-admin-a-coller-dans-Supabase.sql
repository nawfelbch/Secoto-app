-- ============================================================================
-- SECOTO — MIGRATION 108 : L'ADMIN REÇOIT TOUT, ET CHAQUE NOTIFICATION MÈNE
--                          AU BON ONGLET (sans nouveau build de l'application)
-- ----------------------------------------------------------------------------
-- Demande de Nawfal du 20/10/2026 :
--   · chaque client INSCRIT qui obtient un prix (il arrive au bouton de
--     paiement) -> notification détaillée « Nouvelle demande » ;
--   · carte enregistrée, recherche de transporteur lancée -> « Réservation
--     confirmée » ;
--   · devis sans compte -> la notification classique existante (« Nouveau
--     contact devis ») est conservée ;
--   · l'admin reçoit TOUT : missions, documents et frais ne sont plus muets ;
--   · chemin : les notifications de devis / commandes à la demande ouvraient
--     l'ancien onglet « Demandes » (supprimé en 103). Elles ouvrent désormais
--     « À la demande » (écran « offre », déjà reconnu par l'application 2.3.7).
-- ADDITIF, rejouable. Aucun paiement, aucune commande modifiés.
-- ============================================================================

-- 1. L'admin reçoit tout.
insert into public.notification_preferences(account_id, push_enabled, email_enabled, mute_missions, mute_documents, mute_frais, updated_at)
select a.id, true, true, false, false, false, now()
  from public.accounts a where a.role::text = 'admin' and a.deleted_at is null
on conflict (account_id) do update
   set push_enabled = true, mute_missions = false, mute_documents = false, mute_frais = false, updated_at = now();

-- 2. Chemin : pour un admin, une notification de devis / commande (sans
--    mission) ouvre « À la demande ».
create or replace function secoto_private.prepare_notification()
returns trigger language plpgsql security definer set search_path = ''
as $f$
begin
  new.push_screen := case
    when new.push_screen in (
      'courses','documents','frais','available','assigned',
      'applications','requests','paiement','transporters',
      -- Migration 030.
      'offre','suivi','abonnement'
    ) then new.push_screen
    when new.type = 'document' then 'documents'
    when new.type in ('frais','frais_status') then 'frais'
    when new.type = 'new_application' then 'applications'
    when new.type = 'new_request' then 'requests'
    when new.type = 'new_course' then 'available'
    when new.type = 'mission_offer' then 'offre'
    when new.type in ('live_tracking') then 'suivi'
    when new.type in ('subscription') then 'abonnement'
    when new.type in ('payment','payment_failed') then 'paiement'
    when new.type = 'new_account' then 'transporters'
    when new.type in ('tracking','delivered','course_assigned','cancellation','order_update') then 'courses'
    else 'courses'
  end;
  -- 108 : l'onglet « Demandes » n'existe plus côté admin.
  if new.mission_id is null
     and new.push_screen in ('requests', 'paiement', 'courses')
     and new.type in ('new_request', 'payment', 'payment_failed', 'order_update', 'cancellation', 'course_assigned')
     and coalesce(new.audience, (select a.role::text from public.accounts a where a.id = new.account_id)) = 'admin' then
    new.push_screen := 'offre';
  end if;
  new.event_key := coalesce(new.event_key, 'notification:' || new.id::text);
  return new;
end;
$f$;

-- 3. Texte détaillé commun : trajet, mode, véhicule(s), date, prix, marge, contact.
create or replace function secoto_private.admin_resume_demande(q public.transport_quotes)
returns text language sql stable security definer set search_path = ''
as $f$
  select concat_ws(' · ',
    coalesce(q.pickup ->> 'city', '?') || ' (' || coalesce(left(q.pickup ->> 'postcode', 2), '') || ') → '
      || coalesce(q.delivery ->> 'city', '?') || ' (' || coalesce(left(q.delivery ->> 'postcode', 2), '') || ')',
    case q.mode when 'plateau' then 'plateau' else 'convoyage' end,
    case when jsonb_typeof(q.vehicles) = 'array' and jsonb_array_length(q.vehicles) > 1
         then jsonb_array_length(q.vehicles) || ' véhicules'
         else nullif(btrim(coalesce(q.vehicle ->> 'model', '')), '')
              || case when coalesce((q.vehicle ->> 'rolling')::boolean, true) then '' else ' (NON ROULANT)' end end,
    to_char(q.pickup_at at time zone 'Europe/Paris', 'DD/MM'),
    replace(to_char(q.client_price_cents / 100.0, 'FM999G990D00'), '.', ',') || ' €'
      || coalesce(' (marge ' || replace(to_char(q.margin_cents / 100.0, 'FM999G990'), '.', ',') || ' €)', ''),
    nullif(btrim(coalesce(a.full_name, '')), ''),
    coalesce(nullif(btrim(coalesce(a.phone, '')), ''), q.contact_phone, a.email))
  from (select 1) x
  left join public.accounts a on a.id = q.account_id;
$f$;

-- 4. Client inscrit avec un prix = il est au bouton de paiement.
create or replace function secoto_private.trg_admin_nouvelle_demande()
returns trigger language plpgsql security definer set search_path = ''
as $f$
begin
  if new.account_id is not null
     and new.status in ('priced', 'manual_priced')
     and coalesce(new.client_price_cents, 0) > 0
     and coalesce(new.is_test, false) = false
     and not exists (select 1 from public.accounts a where a.id = new.account_id and a.role::text = 'admin') then
    perform secoto_private.notify_admins_event('new_request', 'Nouvelle demande · client inscrit',
      secoto_private.admin_resume_demande(new), 'offre', 'admin-demande:' || new.id::text, new.id);
  end if;
  return new;
exception when others then
  return new;  -- une notification ne bloque jamais un devis
end;
$f$;

-- 5. Carte enregistrée : la recherche de transporteur démarre.
create or replace function secoto_private.trg_admin_reservation_confirmee()
returns trigger language plpgsql security definer set search_path = ''
as $f$
declare v_quote public.transport_quotes%rowtype;
begin
  if new.status = 'searching_partner' and old.status = 'awaiting_payment' and not coalesce(new.is_test, false) then
    select * into v_quote from public.transport_quotes q where q.id = new.quote_id;
    perform secoto_private.notify_admins_event('new_request', 'Réservation confirmée · ' || new.public_ref,
      'Carte enregistrée, recherche de transporteur lancée · ' || coalesce(secoto_private.admin_resume_demande(v_quote), ''),
      'offre', 'admin-reservation:' || new.id::text, new.id);
  end if;
  return new;
exception when others then
  return new;
end;
$f$;

do $$
begin
  if not exists (select 1 from information_schema.columns
                  where table_schema = 'public' and table_name = 'transport_quotes' and column_name = 'is_test') then
    -- Sans colonne is_test sur les devis : on retire simplement ce filtre.
    perform secoto_private.mig074_patch('secoto_private.trg_admin_nouvelle_demande()'::regprocedure,
      'and coalesce(new.is_test, false) = false', '/* 108 */');
  end if;
end $$;

drop trigger if exists trg_secoto_admin_nouvelle_demande on public.transport_quotes;
create trigger trg_secoto_admin_nouvelle_demande
  after insert or update of account_id, status, client_price_cents on public.transport_quotes
  for each row execute function secoto_private.trg_admin_nouvelle_demande();

drop trigger if exists trg_secoto_admin_reservation_confirmee on public.transport_orders;
create trigger trg_secoto_admin_reservation_confirmee
  after update of status on public.transport_orders
  for each row execute function secoto_private.trg_admin_reservation_confirmee();

notify pgrst, 'reload schema';
