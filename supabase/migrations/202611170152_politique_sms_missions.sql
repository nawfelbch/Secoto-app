-- ============================================================================
-- SECOTO — MIGRATION 152 : POLITIQUE SMS ET LISTE À APPELER DES MISSIONS
-- ----------------------------------------------------------------------------
-- Décidé par Nawfal le 17/11/2026. À coller APRÈS la 151.
-- 1. Transporteurs SECOTO : plus de SMS. La relance prévue par SMS (12 h,
--    départ < 7 j) part par E-MAIL. La notification dans l'app reste.
-- 2. Clients : UN SEUL SMS, 1 h après l'affichage du prix, si la demande n'est
--    pas réservée (lien de reprise, prix garanti jusqu'à…). Confirmations :
--    par e-mail uniquement (inchangé).
-- 3. Transporteurs NON affiliés (trouvés par Google dans « Transporteurs à
--    appeler ») : SMS d'invitation à rejoindre SECOTO, envoyé par SECOTO en un
--    clic, une seule fois par numéro, avec mention STOP (SMS de prospection).
-- 4. Missions publiées à la main : même liste « Transporteurs à appeler »
--    (SECOTO + Google) et suivi des appels (table mission_appels).
-- ADDITIF, rejouable. Aucun prix modifié. Aucun interrupteur Apple.
-- ============================================================================

update public.app_settings
   set value = value || jsonb_build_object('sms_devis_actif', true, 'sms_devis_apres_min', 60)
 where key = 'automatisation' and not (value ? 'sms_devis_actif');

alter table public.sms_outbox add column if not exists sms_type text not null default 'transactional';
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'sms_outbox_sms_type_check') then
    alter table public.sms_outbox add constraint sms_outbox_sms_type_check check (sms_type in ('transactional', 'marketing'));
  end if;
end $$;

-- Tâche automatique : transporteurs par e-mail, un SMS de relance au client.
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
  v_points integer := 0; v_paiement integer := 0; v_devis_sms integer := 0;
  v_token text;
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

      -- 1b. 152 : relance par E-MAIL (plus de SMS aux transporteurs SECOTO) si le départ approche.
      if v_age >= make_interval(hours => coalesce((s ->> 'sms_transporteurs_h')::int, 12))
         and v_depart <= make_interval(days => coalesce((s ->> 'sms_si_depart_jours')::int, 7)) then
        for t in select t2.partner_id, t2.partner_pay_cents, a.full_name from public.transport_offers t2
                   join public.accounts a on a.id = t2.partner_id
                  where t2.order_id = o.id and t2.round = o.dispatch_round and t2.status = 'sent' and t2.responded_at is null
                    and not exists (select 1 from public.email_outbox e
                                     where e.event_key = 'od-relance-mail:' || o.id::text || ':' || o.dispatch_round || ':' || t2.partner_id::text) loop
          perform secoto_private.queue_email(t.partner_id,
            format('Mission toujours disponible : %s → %s le %s, %s € pour vous', o.ville_a, o.ville_b,
                   to_char(o.pickup_at at time zone 'Europe/Paris', 'DD/MM'), to_char(t.partner_pay_cents / 100.0, 'FM999990')),
            concat_ws(E'\n',
              'Bonjour' || coalesce(' ' || nullif(split_part(btrim(coalesce(t.full_name, '')), ' ', 1), ''), '') || ',', '',
              'Une mission vous attend toujours sur SECOTO :', '',
              format('• %s · %s → %s', o.modele, o.ville_a, o.ville_b),
              format('• Prise en charge le %s', to_char(o.pickup_at at time zone 'Europe/Paris', 'DD/MM/YYYY')),
              format('• %s € pour vous', to_char(t.partner_pay_cents / 100.0, 'FM999990D00')), '',
              'Acceptez-la dans l''application, onglet « Missions disponibles » :', 'https://app.secoto-transport.fr', '',
              'Une question ? 07 83 27 82 31.', '', 'L''Équipe SECOTO'),
            null, 'od-relance-mail:' || o.id::text || ':' || o.dispatch_round || ':' || t.partner_id::text);
          v_sms := v_sms + 1;
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

  -- 4. 152 : un SMS au client 1 h après son prix, si la demande n'est pas réservée (une seule fois).
  if not v_nuit and coalesce((s ->> 'sms_devis_actif')::boolean, true) then
    for t in
      select q.id, q.client_price_cents, q.valid_until, q.anon_token,
             coalesce(nullif(q.contact_phone, ''), a.phone) as tel, q.account_id,
             q.pickup ->> 'city' as ville_a, q.delivery ->> 'city' as ville_b
        from public.transport_quotes q
        left join public.accounts a on a.id = q.account_id
       where q.status = 'priced' and q.offre_choisie is null and q.supprime_le is null
         and coalesce(q.client_price_cents, 0) > 0 and q.valid_until > now() + interval '1 hour'
         and q.created_at between now() - interval '24 hours' and now() - make_interval(mins => coalesce((s ->> 'sms_devis_apres_min')::int, 60))
         and not exists (select 1 from public.transport_orders x where x.quote_id = q.id)
         and not exists (select 1 from public.sms_outbox m where m.event_key = 'devis-sms:' || q.id::text)
         and secoto_private.tel_international(coalesce(nullif(q.contact_phone, ''), a.phone)) is not null
       limit 20
    loop
      v_token := t.anon_token;
      if v_token is null then
        update public.transport_quotes
           set anon_token = replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', '')
         where id = t.id
        returning anon_token into v_token;
      end if;
      if secoto_private.queue_sms(t.account_id, t.tel,
           format('SECOTO : votre prix pour %s → %s est prêt : %s €, garanti jusqu''au %s. Réservez en 1 minute : https://app.secoto-transport.fr/?reprendre=%s',
                  t.ville_a, t.ville_b, to_char(t.client_price_cents / 100.0, 'FM999990'),
                  to_char(t.valid_until at time zone 'Europe/Paris', 'DD/MM HH24"h"MI'), v_token),
           'devis-sms:' || t.id::text) then
        v_devis_sms := v_devis_sms + 1;
      end if;
    end loop;
  end if;

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

  return jsonb_build_object('rappels', v_rappels, 'relances_mail', v_sms, 'sms_devis', v_devis_sms, 'coups_de_pouce', v_boosts, 'alertes', v_alertes,
                            'points_clients', v_points, 'relances_paiement', v_paiement, 'nuit', v_nuit);
end;
$$;
revoke all on function public.secoto_automatisation_tick() from public, anon, authenticated;
grant execute on function public.secoto_automatisation_tick() to service_role;

-- Les SMS de transporteurs encore en attente (151) ne partent pas.
update public.sms_outbox set status = 'skipped', error = 'politique 152 : transporteurs par e-mail'
 where status = 'pending' and event_key like 'od-sms:%';

-- ---------------------------------------------------------------------------
-- Invitation d'un transporteur NON affilié (SMS de prospection, une fois par numéro).
-- ---------------------------------------------------------------------------
create or replace function public.secoto_admin_inviter_transporteur_sms(p_telephone text, p_nom text)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare
  v_tel text := secoto_private.tel_international(p_telephone);
  v_chiffres text;
begin
  perform secoto_private.assert_admin();
  if v_tel is null then return jsonb_build_object('envoye', false, 'raison', 'Numéro invalide.'); end if;
  v_chiffres := regexp_replace(v_tel, '[^0-9]', '', 'g');
  if exists (select 1 from public.accounts a where a.deleted_at is null
              and secoto_private.tel_international(a.phone) = v_tel) then
    return jsonb_build_object('envoye', false, 'raison', 'Ce numéro est déjà inscrit chez SECOTO.');
  end if;
  if exists (select 1 from public.sms_outbox m where m.event_key = 'invite:' || v_chiffres) then
    return jsonb_build_object('envoye', false, 'raison', 'Déjà invité par SMS.');
  end if;
  insert into public.sms_outbox(to_phone, body, event_key, sms_type)
  values (v_tel,
          'Bonjour, ici SECOTO, plateforme de transport de véhicules. Nous avons des missions plateau près de chez vous, payées après livraison. '
          || 'Inscription gratuite pour les recevoir : https://app.secoto-transport.fr (onglet Transporteur). L''Équipe SECOTO, 07 83 27 82 31. STOP : [STOP CODE]',
          'invite:' || v_chiffres, 'marketing')
  on conflict (event_key) do nothing;
  perform secoto_private.audit('transporteur_invite_sms', 'prospect', v_chiffres, jsonb_build_object('nom', left(p_nom, 200)));
  return jsonb_build_object('envoye', true);
end;
$$;
revoke all on function public.secoto_admin_inviter_transporteur_sms(text, text) from public, anon;
grant execute on function public.secoto_admin_inviter_transporteur_sms(text, text) to authenticated;

-- ---------------------------------------------------------------------------
-- Missions publiées : transporteurs à appeler et suivi des appels.
-- ---------------------------------------------------------------------------
create table if not exists public.mission_appels (
  mission_id uuid not null references public.missions(id),
  cle        text not null,
  source     text not null default 'secoto' check (source in ('secoto', 'google')),
  nom        text,
  telephone  text,
  statut     text not null default 'a_appeler' check (statut in ('a_appeler', 'appele', 'pas_de_reponse', 'interesse', 'refus')),
  note       text,
  updated_at timestamptz not null default now(),
  primary key (mission_id, cle)
);
alter table public.mission_appels enable row level security;
revoke all on table public.mission_appels from public, anon, authenticated;

create or replace function public.secoto_admin_transporteurs_a_appeler_mission(p_mission_id uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  m public.missions%rowtype;
  v_dep_a text;
  v_dep_b text;
begin
  perform secoto_private.assert_admin();
  select * into m from public.missions where id = p_mission_id;
  if not found then raise exception 'Mission introuvable.'; end if;
  v_dep_a := secoto_private.department_of(substring(coalesce(m.pickup_address, '') from '\d{5}'));
  v_dep_b := secoto_private.department_of(substring(coalesce(m.delivery_address, '') from '\d{5}'));
  return jsonb_build_object(
    'commande', jsonb_build_object('ref', m.public_ref, 'mode', m.type::text, 'depart', m.from_city, 'arrivee', m.to_city,
      'dep_depart', v_dep_a, 'dep_arrivee', v_dep_b, 'adresse_depart', m.pickup_address,
      'vehicule', m.vehicle, 'remuneration_cents', round(coalesce(m.carrier_pay, m.manual_carrier_pay, 0) * 100)::int),
    'transporteurs', coalesce((select jsonb_agg(x order by x.rang, x.missions desc, x.nom) from (
      select a.id, coalesce(nullif(a.company_name, ''), a.full_name) as nom, a.full_name as contact, a.phone as telephone,
             a.city as ville, a.transporter_type as type,
             (v_dep_a = any(coalesce(p.departements_base, '{}')) or v_dep_b = any(coalesce(p.departements_base, '{}'))) as proche,
             ap2.status as offre, false as vue,
             (select count(*) from public.missions m2 where m2.assigned_transporter_id = a.id and m2.status::text in ('completed', 'delivered')) as missions,
             coalesce(a.stripe_transfers_enabled, false) or coalesce(a.bank_details_completed, false) as payable,
             ap.statut as appel, ap.note as note_appel,
             case when (v_dep_a = any(coalesce(p.departements_base, '{}'))) then 0
                  when (v_dep_b = any(coalesce(p.departements_base, '{}'))) then 1 else 3 end as rang
        from public.accounts a
        left join public.partner_dispatch_preferences p on p.account_id = a.id
        left join public.mission_applications ap2 on ap2.mission_id = m.id and ap2.transporter_id = a.id
        left join public.mission_appels ap on ap.mission_id = m.id and ap.cle = a.id::text
       where a.role::text = 'transporter' and a.deleted_at is null and not coalesce(a.is_internal, false)
         and coalesce(a.phone, '') <> ''
         and (m.type::text <> 'plateau' or a.transporter_type::text in ('vl', 'pl'))
         and (m.type::text <> 'convoyage' or a.transporter_type::text = 'convoyeur')
         and not exists (select 1 from public.mission_declines d where d.mission_id = m.id and d.partner_id = a.id)
       limit 60) x), '[]'::jsonb),
    'appels_externes', coalesce((select jsonb_agg(jsonb_build_object('cle', ap.cle, 'nom', ap.nom, 'telephone', ap.telephone,
                                    'statut', ap.statut, 'note', ap.note) order by ap.updated_at desc)
                                   from public.mission_appels ap where ap.mission_id = m.id and ap.source = 'google'), '[]'::jsonb));
end;
$$;
revoke all on function public.secoto_admin_transporteurs_a_appeler_mission(uuid) from public, anon;
grant execute on function public.secoto_admin_transporteurs_a_appeler_mission(uuid) to authenticated;

create or replace function public.secoto_admin_appel_mission_maj(p_mission_id uuid, p_cle text, p_source text, p_nom text,
                                                                p_telephone text, p_statut text, p_note text)
returns void language plpgsql volatile security definer set search_path = '' as $$
begin
  perform secoto_private.assert_admin();
  insert into public.mission_appels(mission_id, cle, source, nom, telephone, statut, note, updated_at)
  values (p_mission_id, left(p_cle, 200), coalesce(p_source, 'secoto'), left(p_nom, 200), left(p_telephone, 40),
          coalesce(p_statut, 'a_appeler'), left(p_note, 500), now())
  on conflict (mission_id, cle) do update
    set statut = excluded.statut, note = coalesce(excluded.note, public.mission_appels.note),
        nom = coalesce(excluded.nom, public.mission_appels.nom), telephone = coalesce(excluded.telephone, public.mission_appels.telephone),
        updated_at = now();
end;
$$;
revoke all on function public.secoto_admin_appel_mission_maj(uuid, text, text, text, text, text, text) from public, anon;
grant execute on function public.secoto_admin_appel_mission_maj(uuid, text, text, text, text, text, text) to authenticated;

notify pgrst, 'reload schema';
