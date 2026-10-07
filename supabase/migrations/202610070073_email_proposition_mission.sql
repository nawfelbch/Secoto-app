-- 073 — Les propositions de mission partent aussi par e-mail.
--
-- Constat (07/10/2026) : 30 propositions envoyées sur une commande, 1 seule
-- vue. La notification de l'app n'atteint pas les transporteurs qui n'ont pas
-- installé l'app ou refusé les notifications. Chaque proposition est donc
-- doublée d'un e-mail, envoyé par la file existante (email_outbox → Resend).
--
-- Règles :
--   - uniquement aux transporteurs qui reçoivent la proposition, c'est-à-dire
--     compatibles avec la mission (la diffusion décide, pas cet e-mail) ;
--   - un seul e-mail par commande et par transporteur, même si la commande
--     est rediffusée en plusieurs tours ;
--   - jamais si le transporteur a coupé les e-mails ou les alertes de mission ;
--   - sa rémunération uniquement, jamais le prix client ;
--   - interrupteur sans déploiement : app_settings.offer_email_policy.enabled ;
--   - un e-mail raté ne bloque JAMAIS la diffusion de la proposition.

insert into public.app_settings (key, value)
values ('offer_email_policy', jsonb_build_object('enabled', true))
on conflict (key) do nothing;

create or replace function secoto_private.queue_offer_email(p_offer_id uuid)
returns boolean language plpgsql security definer set search_path = ''
as $f$
declare
  v_offer     public.transport_offers%rowtype;
  v_email     text;
  v_order     public.transport_orders%rowtype;
  v_quote     public.transport_quotes%rowtype;
  v_jours     text[] := array['dimanche','lundi','mardi','mercredi','jeudi','vendredi','samedi'];
  v_mois      text[] := array['janvier','février','mars','avril','mai','juin','juillet','août',
                              'septembre','octobre','novembre','décembre'];
  v_pickup    timestamp;
  v_expire    timestamp;
  v_trajet    text;
  v_vehicule  text;
  v_nb        integer;
  v_creneau   text;
  v_paie      text;
  v_km        text;
  v_corps     text;
begin
  select * into v_offer from public.transport_offers x where x.id = p_offer_id;
  if v_offer.id is null or v_offer.status <> 'sent' or v_offer.expires_at <= now() then return false; end if;
  if not coalesce((select (s.value ->> 'enabled')::boolean
                     from public.app_settings s where s.key = 'offer_email_policy'), false) then
    return false;
  end if;

  -- Destinataire : compte actif, e-mail connu, e-mails et alertes de mission acceptés.
  select nullif(btrim(a.email), '') into v_email
    from public.accounts a
    left join public.notification_preferences np on np.account_id = a.id
   where a.id = v_offer.partner_id
     and a.deleted_at is null
     and coalesce(np.email_enabled, true)
     and not coalesce(np.mute_missions, false);
  if v_email is null then return false; end if;

  select * into v_order from public.transport_orders o where o.id = v_offer.order_id;
  select * into v_quote from public.transport_quotes q where q.id = v_order.quote_id;
  if v_order.id is null or v_quote.id is null then return false; end if;

  v_trajet := concat_ws(' → ', v_quote.pickup ->> 'city', v_quote.delivery ->> 'city');

  v_pickup := v_order.pickup_at at time zone 'Europe/Paris';
  v_expire := v_offer.expires_at at time zone 'Europe/Paris';
  v_creneau := case v_quote.schedule ->> 'slot'
                 when 'matin' then 'matin' when 'apres_midi' then 'après-midi'
                 when 'journee' then 'dans la journée' end;

  v_nb := case when jsonb_typeof(v_quote.vehicles) = 'array' then jsonb_array_length(v_quote.vehicles) else 1 end;
  v_vehicule := case when v_nb > 1 then v_nb || ' véhicules'
                     else concat_ws(' · ', nullif(btrim(v_quote.vehicle ->> 'model'), ''),
                                    case when coalesce((v_quote.vehicle ->> 'rolling')::boolean, true)
                                         then 'roulant' else 'non roulant' end) end;

  v_paie := replace(to_char(v_offer.partner_pay_cents / 100.0, 'FM999990D00'), '.', ',') || ' €';
  v_km := case when (v_quote.route ->> 'distance_km') is not null
               then ' (environ ' || round((v_quote.route ->> 'distance_km')::numeric) || ' km)' end;

  v_corps :=
       'Bonjour,' || E'\n\n'
    || 'Une mission correspondant à votre profil est disponible sur SECOTO.' || E'\n\n'
    || 'Trajet : ' || v_trajet || coalesce(v_km, '') || E'\n'
    || 'Prise en charge : ' || v_jours[extract(dow from v_pickup)::int + 1] || ' '
       || extract(day from v_pickup)::int || ' ' || v_mois[extract(month from v_pickup)::int]
       || coalesce(', ' || v_creneau, '') || E'\n'
    || 'Transport : ' || case v_order.mode when 'plateau' then 'sur plateau' else 'convoyage' end
       || ' · ' || v_vehicule || E'\n'
    || 'Votre rémunération : ' || v_paie || E'\n\n'
    || 'La mission revient au premier transporteur qui l''accepte. Proposition valable jusqu''au '
       || v_jours[extract(dow from v_expire)::int + 1] || ' ' || extract(day from v_expire)::int || ' '
       || v_mois[extract(month from v_expire)::int] || ' à ' || to_char(v_expire, 'HH24"h"MI') || '.' || E'\n\n'
    || 'Voir et accepter la mission :' || E'\n'
    || 'https://app.secoto-transport.fr/?ecran=offre&offre=' || v_offer.id::text || E'\n\n'
    || 'SECOTO' || E'\n' || '07 83 27 82 31' || E'\n\n'
    || 'Vous recevez cet e-mail en tant que transporteur partenaire SECOTO. '
    || 'Pour ne plus recevoir ces alertes, désactivez les e-mails dans les réglages de notification de l''application.';

  insert into public.email_outbox (account_id, to_email, subject, body_text, event_key)
  values (v_offer.partner_id, v_email,
          'Mission disponible : ' || v_trajet || ' · ' || v_paie,
          v_corps,
          'offer-email:' || v_offer.order_id::text || ':' || v_offer.partner_id::text)
  on conflict (event_key) do nothing;
  return found;
exception when others then
  -- Un e-mail raté ne doit jamais empêcher une proposition de partir.
  return false;
end;
$f$;

revoke all on function secoto_private.queue_offer_email(uuid) from public;

create or replace function secoto_private.trg_offer_email()
returns trigger language plpgsql security definer set search_path = ''
as $f$
begin
  perform secoto_private.queue_offer_email(new.id);
  return new;
exception when others then
  return new;
end;
$f$;

drop trigger if exists trg_secoto_offer_email on public.transport_offers;
create trigger trg_secoto_offer_email
  after insert on public.transport_offers
  for each row execute function secoto_private.trg_offer_email();

do $$
begin
  if not exists (select 1 from pg_trigger where tgname = 'trg_secoto_offer_email') then
    raise exception 'Déclencheur d''e-mail de proposition absent.';
  end if;
end $$;
