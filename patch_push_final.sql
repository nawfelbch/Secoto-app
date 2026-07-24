-- ============================================================================
-- SECOTO — Notification systeme (ecran verrouille) + ouverture sur « Mes documents »
-- ----------------------------------------------------------------------------
-- A coller dans Supabase > SQL Editor > Run. Idempotent. Remplace le
-- declencheur precedent. Lisez le tableau de resultats a la fin : il indique
-- la reponse REELLE du service d'envoi (c'est la qu'on voit ce qui bloque).
-- ============================================================================

create extension if not exists pg_net with schema extensions;

insert into public.app_settings (key, value)
values ('push_endpoint', to_jsonb(
  'https://app.secoto-transport.fr/.netlify/functions/send-mission-notifications'::text))
on conflict (key) do update set value = excluded.value;

-- ----------------------------------------------------------------------------
-- Envoi systeme a chaque notification, avec lien direct vers le bon ecran.
-- ----------------------------------------------------------------------------
create or replace function public.secoto_trg_notification_push()
returns trigger
language plpgsql
security definer
set search_path = public, extensions, net
as $$
declare
  v_url  text;
  v_link text;
begin
  select trim(both '"' from value #>> '{}') into v_url
  from public.app_settings where key = 'push_endpoint';
  if coalesce(v_url, '') = '' then return new; end if;

  -- Lien ouvert au clic sur la notification du telephone.
  v_link := case
    when new.type = 'document' then '/?ecran=documents'
    when new.type in ('frais', 'frais_status') then '/?ecran=frais'
    else '/'
  end;
  if new.mission_id is not null then
    v_link := v_link || case when position('?' in v_link) > 0 then '&' else '?' end
              || 'mission=' || new.mission_id::text;
  end if;

  perform net.http_post(
    url     := v_url,
    headers := jsonb_build_object('Content-Type', 'application/json'),
    body    := jsonb_build_object(
      'accountId', new.account_id,
      'title',     new.title,
      'body',      coalesce(new.body, ''),
      'url',       v_link,
      'missionId', new.mission_id
    ),
    timeout_milliseconds := 8000
  );
  return new;
exception when others then
  return new;   -- un envoi rate ne doit jamais bloquer l'alerte dans l'app
end $$;

drop trigger if exists trg_secoto_notification_push on public.notifications;
create trigger trg_secoto_notification_push
  after insert on public.notifications
  for each row execute function public.secoto_trg_notification_push();

-- ----------------------------------------------------------------------------
-- DIAGNOSTIC : reponses reelles du service d'envoi (10 dernieres).
--   200 + {"sent":N}          -> tout va bien
--   200 + {"skipped":true}    -> cles VAPID absentes cote Netlify
--   200 + {"sent":0,"total":0}-> aucun appareil abonne POUR CE COMPTE
--   404 / 500 / timeout       -> adresse du service incorrecte ou indisponible
-- ----------------------------------------------------------------------------
select created         as le,
       status_code     as code_http,
       left(coalesce(content, error_msg, ''), 200) as reponse
from net._http_response
order by created desc
limit 10;

-- Qui est reellement abonne aux notifications systeme ?
select a.full_name, a.role, count(p.id) as appareils
from public.accounts a
left join public.push_subscriptions p on p.account_id = a.id
group by a.full_name, a.role
order by appareils desc, a.role;

notify pgrst, 'reload schema';
