-- ============================================================================
-- SECOTO — MIGRATION 151 : AUTOMATISATION (TRANSPORTEURS, CLIENTS, PAIEMENTS)
-- ----------------------------------------------------------------------------
-- Demandé par Nawfal le 17/11/2026 : « l'application doit tout automatiser ».
-- Une seule fonction, appelée chaque minute par od-maintenance :
--   1. Commandes sans transporteur :
--      · rappel aux transporteurs qui n'ont pas répondu (notification + e-mail)
--        4 h après la diffusion ;
--      · SMS (file d'envoi, Brevo) 12 h après, si le départ est à moins de 7 j ;
--      · coup de pouce : 24 h après, départ à moins de 5 j, la rémunération
--        monte de 10 %, sans jamais laisser moins de 50 € nets à SECOTO
--        (URSSAF et frais de paiement déduits) — une seule fois ;
--      · alerte à SECOTO 18 h après, départ à moins de 3 j, avec la liste des
--        transporteurs à appeler (écran Piloter).
--   2. Clients : point d'étape toutes les 12 h tant qu'aucun transporteur n'a
--      confirmé (4 au maximum), e-mail + notification.
--   3. Transporteurs sans compte de paiement (ni Stripe ni coordonnées
--      bancaires) : relance hebdomadaire (6 au maximum).
-- Pause la nuit (21 h – 7 h, heure de Paris), sauf alerte à SECOTO.
-- Écran Piloter : liste des transporteurs à appeler (SECOTO + Google) et suivi
-- des appels (table od_appels).
-- Réglages : app_settings['automatisation'] (tout est désactivable).
-- ADDITIF, rejouable. Ne touche à aucun interrupteur Apple. Aucun prix client
-- modifié.
-- ============================================================================

insert into public.app_settings(key, value)
values ('automatisation', jsonb_build_object(
  'actif', true,
  'nuit_debut_h', 21, 'nuit_fin_h', 7,
  'rappel_transporteurs_h', 4,
  'sms_transporteurs_h', 12, 'sms_si_depart_jours', 7,
  'coup_de_pouce_actif', true, 'coup_de_pouce_h', 24, 'coup_de_pouce_si_depart_jours', 5,
  'coup_de_pouce_pct', 10, 'coup_de_pouce_net_min_eur', 50,
  'alerte_admin_h', 18, 'alerte_si_depart_jours', 3,
  'point_client_h', 12, 'point_client_max', 4,
  'relance_paiement_jours', 7, 'relance_paiement_max', 6))
on conflict (key) do nothing;

create or replace function secoto_private.automatisation_reglages()
returns jsonb language sql stable security definer set search_path = '' as $$
  select coalesce((select value from public.app_settings where key = 'automatisation'), '{}'::jsonb);
$$;
revoke all on function secoto_private.automatisation_reglages() from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- SMS : file d'envoi (envoyée par od-maintenance via Brevo quand la clé existe).
-- ---------------------------------------------------------------------------
create table if not exists public.sms_outbox (
  id          uuid primary key default gen_random_uuid(),
  account_id  uuid references public.accounts(id),
  to_phone    text not null,
  body        text not null,
  event_key   text not null unique,
  status      text not null default 'pending' check (status in ('pending', 'sending', 'sent', 'failed', 'skipped')),
  error       text,
  created_at  timestamptz not null default now(),
  sent_at     timestamptz
);
alter table public.sms_outbox enable row level security;
revoke all on table public.sms_outbox from public, anon, authenticated;
create index if not exists sms_outbox_pending_idx on public.sms_outbox(created_at) where status = 'pending';

-- Numéro français au format international (+33…), ou null.
create or replace function secoto_private.tel_international(p_tel text)
returns text language sql immutable set search_path = '' as $$
  select case
    when d ~ '^33[1-9][0-9]{8}$' then '+' || d
    when d ~ '^0[1-9][0-9]{8}$' then '+33' || substr(d, 2)
    when d ~ '^[1-9][0-9]{7,14}$' and p_tel like '+%' then '+' || d
  end
  from (select regexp_replace(coalesce(p_tel, ''), '[^0-9]', '', 'g') as d) x;
$$;

create or replace function secoto_private.queue_sms(p_account_id uuid, p_phone text, p_body text, p_event_key text)
returns boolean language plpgsql volatile security definer set search_path = '' as $$
declare v_tel text := secoto_private.tel_international(p_phone);
begin
  if v_tel is null or coalesce(btrim(p_body), '') = '' then return false; end if;
  insert into public.sms_outbox(account_id, to_phone, body, event_key)
  values (p_account_id, v_tel, left(p_body, 600), p_event_key)
  on conflict (event_key) do nothing;
  return found;
end;
$$;
revoke all on function secoto_private.queue_sms(uuid, text, text, text) from public, anon, authenticated;

-- Lot à envoyer (réservé au serveur) : les SMS de plus de 12 h non envoyés sont abandonnés.
create or replace function public.secoto_sms_a_envoyer(p_limit integer default 20)
returns setof public.sms_outbox language plpgsql volatile security definer set search_path = '' as $$
begin
  update public.sms_outbox set status = 'skipped', error = 'trop ancien'
   where status = 'pending' and created_at < now() - interval '12 hours';
  return query
    update public.sms_outbox s set status = 'sending'
     where s.id in (select id from public.sms_outbox where status = 'pending' order by created_at
                     limit greatest(1, least(coalesce(p_limit, 20), 100)) for update skip locked)
    returning s.*;
end;
$$;
revoke all on function public.secoto_sms_a_envoyer(integer) from public, anon, authenticated;
grant execute on function public.secoto_sms_a_envoyer(integer) to service_role;

create or replace function public.secoto_sms_resultat(p_id uuid, p_ok boolean, p_error text default null)
returns void language sql volatile security definer set search_path = '' as $$
  update public.sms_outbox
     set status = case when p_ok then 'sent' when p_error = 'sans_cle' then 'pending' else 'failed' end,
         sent_at = case when p_ok then now() end, error = left(p_error, 300)
   where id = p_id;
$$;
revoke all on function public.secoto_sms_resultat(uuid, boolean, text) from public, anon, authenticated;
grant execute on function public.secoto_sms_resultat(uuid, boolean, text) to service_role;

-- ---------------------------------------------------------------------------
-- Journal des actions automatiques (une seule fois par commande et par étape).
-- ---------------------------------------------------------------------------
create table if not exists public.automatisation_journal (
  event_key  text primary key,
  order_id   uuid,
  action     text not null,
  detail     jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);
alter table public.automatisation_journal enable row level security;
revoke all on table public.automatisation_journal from public, anon, authenticated;

-- Rémunération maximale qui laisse au moins p_net € nets à SECOTO (URSSAF + frais de paiement).
create or replace function secoto_private.pay_max_cents(p_client_cents integer, p_mode text, p_net_eur numeric)
returns integer language sql immutable set search_path = '' as $$
  select floor(p_client_cents
               - (p_net_eur * 100
                  + case p_mode when 'klarna' then 0.05 * p_client_cents
                                when 'virement' then 0 when 'especes' then 0
                                else 0.015 * p_client_cents + 25 end) / (1 - 0.212))::int;
$$;

-- ---------------------------------------------------------------------------
-- La tâche automatique.
-- ---------------------------------------------------------------------------
create or replace function public.secoto_automatisation_tick()
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare
  s jsonb := secoto_private.automatisation_reglages();
  v_heure integer := extract(hour from now() at time zone 'Europe/Paris')::int;
  v_nuit boolean;
  o record;
  t record;
  v_debut timestamptz;
  v_age interval;
  v_depart interval;
  v_new integer;
  v_max integer;
  v_k integer;
  v_n integer;
  v_rappels integer := 0; v_sms integer := 0; v_boosts integer := 0; v_alertes integer := 0;
  v_points integer := 0; v_paiement integer := 0;
begin
  if not coalesce((s ->> 'actif')::boolean, false) then return jsonb_build_object('actif', false); end if;
  v_nuit := v_heure >= coalesce((s ->> 'nuit_debut_h')::int, 21) or v_heure < coalesce((s ->> 'nuit_fin_h')::int, 7);

  for o in
    select x.*, q.pickup ->> 'city' as ville_a, q.delivery ->> 'city' as ville_b,
           coalesce(nullif(q.vehicle ->> 'model', ''), 'Véhicule') as modele
      from public.transport_orders x
      join public.transport_quotes q on q.id = x.quote_id
     where x.status = 'searching_partner' and x.lock_partner_id is null
       and not coalesce(x.is_test, false) and x.pickup_at > now()
  loop
    select min(t2.created_at) into v_debut from public.transport_offers t2
     where t2.order_id = o.id and t2.round = o.dispatch_round;
    continue when v_debut is null;
    v_age := now() - v_debut;
    v_depart := o.pickup_at - now();

    if not v_nuit then
      -- 1a. Rappel aux transporteurs qui n'ont pas répondu.
      if v_age >= make_interval(hours => coalesce((s ->> 'rappel_transporteurs_h')::int, 4)) then
        for t in select t2.id, t2.partner_id, t2.partner_pay_cents from public.transport_offers t2
                  where t2.order_id = o.id and t2.round = o.dispatch_round and t2.status = 'sent' and t2.responded_at is null loop
          if secoto_private.notify_event(t.partner_id, 'mission_offer', 'Mission toujours disponible',
               format('%s · %s → %s · %s € pour vous. Acceptez-la dans l''application avant qu''un autre transporteur ne la prenne.',
                      o.modele, o.ville_a, o.ville_b, to_char(t.partner_pay_cents / 100.0, 'FM999990D00')),
               null, 'offre', 'od-rappel:' || t.id::text || ':' || o.dispatch_round, t.id) is not null then
            v_rappels := v_rappels + 1;
          end if;
        end loop;
      end if;

      -- 1b. SMS si le départ approche.
      if v_age >= make_interval(hours => coalesce((s ->> 'sms_transporteurs_h')::int, 12))
         and v_depart <= make_interval(days => coalesce((s ->> 'sms_si_depart_jours')::int, 7)) then
        for t in select t2.partner_id, t2.partner_pay_cents, a.phone from public.transport_offers t2
                   join public.accounts a on a.id = t2.partner_id
                  where t2.order_id = o.id and t2.round = o.dispatch_round and t2.status = 'sent' and t2.responded_at is null loop
          if secoto_private.queue_sms(t.partner_id, t.phone,
               format('SECOTO : mission %s → %s le %s, %s € pour vous. A accepter dans l''app SECOTO : app.secoto-transport.fr',
                      o.ville_a, o.ville_b, to_char(o.pickup_at at time zone 'Europe/Paris', 'DD/MM'),
                      to_char(t.partner_pay_cents / 100.0, 'FM999990')),
               'od-sms:' || o.id::text || ':' || o.dispatch_round || ':' || t.partner_id::text) then
            v_sms := v_sms + 1;
          end if;
        end loop;
      end if;

      -- 1c. Coup de pouce (une fois par commande), dans la limite de la marge.
      if coalesce((s ->> 'coup_de_pouce_actif')::boolean, false)
         and o.payment_circuit is null
         and v_age >= make_interval(hours => coalesce((s ->> 'coup_de_pouce_h')::int, 24))
         and v_depart <= make_interval(days => coalesce((s ->> 'coup_de_pouce_si_depart_jours')::int, 5))
         and not exists (select 1 from public.automatisation_journal j where j.event_key = 'boost:' || o.id::text) then
        v_max := secoto_private.pay_max_cents(o.client_price_cents, o.mode_reglement, coalesce((s ->> 'coup_de_pouce_net_min_eur')::numeric, 50));
        v_new := least(round(o.partner_pay_cents * (1 + coalesce((s ->> 'coup_de_pouce_pct')::numeric, 10) / 100))::int, v_max);
        insert into public.automatisation_journal(event_key, order_id, action, detail)
        values ('boost:' || o.id::text, o.id, 'coup_de_pouce',
                jsonb_build_object('avant', o.partner_pay_cents, 'apres', greatest(v_new, o.partner_pay_cents), 'max', v_max));
        if v_new > o.partner_pay_cents then
          update public.transport_orders set partner_pay_cents = v_new, updated_at = now() where id = o.id;
          update public.transport_offers set partner_pay_cents = v_new
           where order_id = o.id and round = o.dispatch_round and status = 'sent';
          perform secoto_private.audit('order_partner_pay_changed', 'transport_order', o.id::text,
            jsonb_build_object('from', o.partner_pay_cents, 'to', v_new, 'margin_cents', o.client_price_cents - v_new,
                               'note', 'Coup de pouce automatique (151)'));
          for t in select t2.id, t2.partner_id from public.transport_offers t2
                    where t2.order_id = o.id and t2.round = o.dispatch_round and t2.status = 'sent' loop
            perform secoto_private.notify_event(t.partner_id, 'mission_offer', 'Rémunération augmentée',
              format('%s → %s : %s € pour vous (au lieu de %s €).', o.ville_a, o.ville_b,
                     to_char(v_new / 100.0, 'FM999990D00'), to_char(o.partner_pay_cents / 100.0, 'FM999990D00')),
              null, 'offre', 'od-boost:' || t.id::text, t.id);
          end loop;
          v_boosts := v_boosts + 1;
        end if;
      end if;

      -- 2. Point d'étape au client.
      v_k := floor(extract(epoch from v_age) / 3600 / coalesce((s ->> 'point_client_h')::numeric, 12))::int;
      if v_k >= 1 and v_k <= coalesce((s ->> 'point_client_max')::int, 4)
         and not exists (select 1 from public.automatisation_journal j where j.event_key = 'point:' || o.id::text || ':' || v_k) then
        select count(*) into v_n from public.transport_offers t2 where t2.order_id = o.id and t2.round = o.dispatch_round;
        insert into public.automatisation_journal(event_key, order_id, action) values ('point:' || o.id::text || ':' || v_k, o.id, 'point_client');
        perform secoto_private.queue_email(o.account_id,
          format('Votre commande %s : nous recherchons votre transporteur', o.public_ref),
          concat_ws(E'\n',
            'Bonjour,', '',
            format('Votre transport %s → %s du %s est en cours d''attribution : votre demande a été envoyée à %s transporteurs validés par SECOTO, et nous les relançons.',
                   o.ville_a, o.ville_b, to_char(o.pickup_at at time zone 'Europe/Paris', 'DD/MM/YYYY'), v_n),
            'Rien n''est débité tant qu''aucun transporteur n''a confirmé.', '',
            'Votre date est flexible, ou vous êtes pressé ? Répondez à cet e-mail ou appelez-nous au 07 83 27 82 31 : nous pouvons décaler la date ou passer votre commande en Express (prise en charge sous 48 h).', '',
            'L''Équipe SECOTO'),
          o.mission_id, 'od-point-client:' || o.id::text || ':' || v_k);
        perform secoto_private.notify_event(o.account_id, 'order_update', 'Recherche de votre transporteur en cours',
          format('%s → %s : demande envoyée à %s transporteurs, relances en cours. Rien n''est débité avant confirmation.', o.ville_a, o.ville_b, v_n),
          o.mission_id, 'suivi', 'od-point-client-push:' || o.id::text || ':' || v_k, o.id);
        v_points := v_points + 1;
      end if;
    end if;

    -- 1d. Alerte à SECOTO (même la nuit), une fois par commande.
    if v_age >= make_interval(hours => coalesce((s ->> 'alerte_admin_h')::int, 18))
       and v_depart <= make_interval(days => coalesce((s ->> 'alerte_si_depart_jours')::int, 3))
       and not exists (select 1 from public.automatisation_journal j where j.event_key = 'alerte:' || o.id::text) then
      insert into public.automatisation_journal(event_key, order_id, action) values ('alerte:' || o.id::text, o.id, 'alerte_admin');
      perform secoto_private.notify_admins_event('new_request', 'Commande sans transporteur',
        format('%s · %s → %s, départ le %s : aucun transporteur malgré les relances. Ouvrez « Piloter » : liste des transporteurs à appeler.',
               o.public_ref, o.ville_a, o.ville_b, to_char(o.pickup_at at time zone 'Europe/Paris', 'DD/MM HH24:MI')),
        'requests', 'od-alerte-admin:' || o.id::text, o.id);
      v_alertes := v_alertes + 1;
    end if;
  end loop;

  -- 3. Transporteurs sans compte de paiement : relance hebdomadaire.
  if not v_nuit then
    for t in
      select a.id, a.email, coalesce(nullif(split_part(btrim(coalesce(a.full_name, '')), ' ', 1), ''), '') as prenom
        from public.accounts a
       where a.role::text = 'transporter' and a.deleted_at is null and not coalesce(a.is_internal, false)
         and a.is_verified and coalesce(a.email, '') like '%@%'
         and not coalesce(a.stripe_transfers_enabled, false) and not coalesce(a.bank_details_completed, false)
         and not exists (select 1 from public.automatisation_journal j
                          where j.event_key like 'paiement:' || a.id::text || ':%'
                            and j.created_at > now() - make_interval(days => coalesce((s ->> 'relance_paiement_jours')::int, 7)))
         and (select count(*) from public.automatisation_journal j where j.event_key like 'paiement:' || a.id::text || ':%')
             < coalesce((s ->> 'relance_paiement_max')::int, 6)
       limit 30
    loop
      insert into public.automatisation_journal(event_key, action) values ('paiement:' || t.id::text || ':' || to_char(now(), 'IYYY-IW'), 'relance_paiement')
      on conflict (event_key) do nothing;
      perform secoto_private.queue_email(t.id, 'SECOTO : renseignez vos coordonnées de paiement pour être payé',
        concat_ws(E'\n',
          'Bonjour' || case when t.prenom <> '' then ' ' || t.prenom else '' end || ',', '',
          'Des missions vous sont proposées sur SECOTO, mais votre compte de paiement n''est pas encore renseigné : sans lui, vos rémunérations ne peuvent pas vous être versées.', '',
          'Dans l''application : Compte > Coordonnées bancaires. Cela prend 2 minutes.', '',
          'https://app.secoto-transport.fr', '',
          'Une question ? Appelez-nous au 07 83 27 82 31.', '',
          'L''Équipe SECOTO'),
        null, 'relance-paiement:' || t.id::text || ':' || to_char(now(), 'IYYY-IW'));
      perform secoto_private.notify_event(t.id, 'payment', 'Renseignez vos coordonnées de paiement',
        'Pour être payé après vos missions : Compte > Coordonnées bancaires.', null, null,
        'relance-paiement-push:' || t.id::text || ':' || to_char(now(), 'IYYY-IW'), null);
      v_paiement := v_paiement + 1;
    end loop;
  end if;

  return jsonb_build_object('rappels', v_rappels, 'sms', v_sms, 'coups_de_pouce', v_boosts, 'alertes', v_alertes,
                            'points_clients', v_points, 'relances_paiement', v_paiement, 'nuit', v_nuit);
end;
$$;
revoke all on function public.secoto_automatisation_tick() from public, anon, authenticated;
grant execute on function public.secoto_automatisation_tick() to service_role;

-- ---------------------------------------------------------------------------
-- Piloter : transporteurs à appeler, et suivi des appels.
-- ---------------------------------------------------------------------------
create table if not exists public.od_appels (
  order_id   uuid not null references public.transport_orders(id),
  cle        text not null,                 -- id du compte SECOTO, ou identifiant Google
  source     text not null default 'secoto' check (source in ('secoto', 'google')),
  nom        text,
  telephone  text,
  statut     text not null default 'a_appeler' check (statut in ('a_appeler', 'appele', 'pas_de_reponse', 'interesse', 'refus')),
  note       text,
  updated_at timestamptz not null default now(),
  primary key (order_id, cle)
);
alter table public.od_appels enable row level security;
revoke all on table public.od_appels from public, anon, authenticated;

create or replace function public.secoto_admin_transporteurs_a_appeler(p_order_id uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_order public.transport_orders%rowtype;
  v_quote public.transport_quotes%rowtype;
  v_dep_a text;
  v_dep_b text;
begin
  perform secoto_private.assert_admin();
  select * into v_order from public.transport_orders where id = p_order_id;
  if not found then raise exception 'Commande introuvable.'; end if;
  select * into v_quote from public.transport_quotes where id = v_order.quote_id;
  v_dep_a := secoto_private.department_of(v_quote.pickup ->> 'postcode');
  v_dep_b := secoto_private.department_of(v_quote.delivery ->> 'postcode');
  return jsonb_build_object(
    'commande', jsonb_build_object('ref', v_order.public_ref, 'mode', v_order.mode, 'depart', v_quote.pickup ->> 'city',
      'arrivee', v_quote.delivery ->> 'city', 'dep_depart', v_dep_a, 'dep_arrivee', v_dep_b,
      'lat', (v_quote.pickup ->> 'lat')::numeric, 'lng', (v_quote.pickup ->> 'lng')::numeric,
      'vehicule', v_quote.vehicle ->> 'model', 'remuneration_cents', v_order.partner_pay_cents),
    'transporteurs', coalesce((select jsonb_agg(x order by x.rang, x.missions desc, x.nom) from (
      select a.id, coalesce(nullif(a.company_name, ''), a.full_name) as nom, a.full_name as contact, a.phone as telephone,
             a.city as ville, a.transporter_type as type,
             coalesce(p.departements_base, '{}') as departements,
             (v_dep_a = any(coalesce(p.departements_base, '{}')) or v_dep_b = any(coalesce(p.departements_base, '{}'))) as proche,
             t.status as offre, t.seen_at is not null as vue,
             (select count(*) from public.missions m where m.assigned_transporter_id = a.id and m.status::text in ('completed', 'delivered')) as missions,
             coalesce(a.stripe_transfers_enabled, false) or coalesce(a.bank_details_completed, false) as payable,
             ap.statut as appel, ap.note as note_appel,
             case when (v_dep_a = any(coalesce(p.departements_base, '{}'))) then 0
                  when (v_dep_b = any(coalesce(p.departements_base, '{}'))) then 1
                  when t.seen_at is not null then 2 else 3 end as rang
        from public.accounts a
        left join public.partner_dispatch_preferences p on p.account_id = a.id
        left join public.transport_offers t on t.order_id = v_order.id and t.partner_id = a.id and t.round = v_order.dispatch_round
        left join public.od_appels ap on ap.order_id = v_order.id and ap.cle = a.id::text
       where a.role::text = 'transporter' and a.deleted_at is null and not coalesce(a.is_internal, false)
         and coalesce(a.phone, '') <> ''
         and (v_order.mode <> 'plateau' or a.transporter_type::text in ('vl', 'pl'))
         and (v_order.mode <> 'convoyage' or a.transporter_type::text = 'convoyeur')
         and coalesce(t.status, '') <> 'declined'
       limit 60) x), '[]'::jsonb),
    'appels_externes', coalesce((select jsonb_agg(jsonb_build_object('cle', ap.cle, 'nom', ap.nom, 'telephone', ap.telephone,
                                    'statut', ap.statut, 'note', ap.note) order by ap.updated_at desc)
                                   from public.od_appels ap where ap.order_id = v_order.id and ap.source = 'google'), '[]'::jsonb));
end;
$$;
revoke all on function public.secoto_admin_transporteurs_a_appeler(uuid) from public, anon;
grant execute on function public.secoto_admin_transporteurs_a_appeler(uuid) to authenticated;

create or replace function public.secoto_admin_appel_maj(p_order_id uuid, p_cle text, p_source text, p_nom text,
                                                        p_telephone text, p_statut text, p_note text)
returns void language plpgsql volatile security definer set search_path = '' as $$
begin
  perform secoto_private.assert_admin();
  insert into public.od_appels(order_id, cle, source, nom, telephone, statut, note, updated_at)
  values (p_order_id, left(p_cle, 200), coalesce(p_source, 'secoto'), left(p_nom, 200), left(p_telephone, 40),
          coalesce(p_statut, 'a_appeler'), left(p_note, 500), now())
  on conflict (order_id, cle) do update
    set statut = excluded.statut, note = coalesce(excluded.note, public.od_appels.note),
        nom = coalesce(excluded.nom, public.od_appels.nom), telephone = coalesce(excluded.telephone, public.od_appels.telephone),
        updated_at = now();
end;
$$;
revoke all on function public.secoto_admin_appel_maj(uuid, text, text, text, text, text, text) from public, anon;
grant execute on function public.secoto_admin_appel_maj(uuid, text, text, text, text, text, text) to authenticated;

notify pgrst, 'reload schema';
