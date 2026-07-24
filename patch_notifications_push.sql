-- ============================================================================
-- SECOTO — Patch « notifications sur l'ecran de veille »
-- ----------------------------------------------------------------------------
-- A coller dans Supabase > SQL Editor > Run. Idempotent.
-- A lancer APRES patch_temps_reel.sql, patch_documents_signature.sql et
-- patch_devis_automatique.sql.
--
-- CE QUE FAIT CE PATCH
-- Jusqu'ici, une alerte n'apparaissait QUE dans l'application (cloche). Les
-- notifications systeme (ecran verrouille) n'etaient envoyees que par le
-- navigateur de celui qui declenchait l'action — donc jamais pour les etapes
-- automatiques (devis, bon de mission, facture, frais, candidatures...).
--
-- Desormais : CHAQUE ligne creee dans public.notifications declenche aussi
-- l'envoi d'une notification systeme au destinataire. Une seule regle couvre
-- donc TOUTES les etapes, presentes et futures.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1) Extension reseau (permet a la base d'appeler le service d'envoi)
-- ----------------------------------------------------------------------------
create extension if not exists pg_net with schema extensions;

-- ----------------------------------------------------------------------------
-- 2) Adresse du service d'envoi, modifiable sans toucher au code
-- ----------------------------------------------------------------------------
insert into public.app_settings (key, value)
values ('push_endpoint', to_jsonb(
  'https://app.secoto-transport.fr/.netlify/functions/send-mission-notifications'::text))
on conflict (key) do nothing;

-- ----------------------------------------------------------------------------
-- 3) Envoi systeme a chaque notification creee
-- ----------------------------------------------------------------------------
create or replace function public.secoto_trg_notification_push()
returns trigger
language plpgsql
security definer
set search_path = public, extensions, net
as $$
declare
  v_url text;
begin
  select trim(both '"' from value::text) into v_url
  from public.app_settings where key = 'push_endpoint';

  if v_url is null or v_url = '' then
    return new;
  end if;

  perform net.http_post(
    url     := v_url,
    headers := jsonb_build_object('Content-Type', 'application/json'),
    body    := jsonb_build_object(
      'accountId', new.account_id,
      'title',     new.title,
      'body',      coalesce(new.body, ''),
      'url',       '/',
      'missionId', new.mission_id
    )
  );
  return new;
exception when others then
  -- Un envoi qui echoue ne doit JAMAIS empecher l'alerte dans l'application.
  return new;
end $$;

drop trigger if exists trg_secoto_notification_push on public.notifications;
create trigger trg_secoto_notification_push
  after insert on public.notifications
  for each row execute function public.secoto_trg_notification_push();

-- ----------------------------------------------------------------------------
-- 4) VERIFICATION — a lire apres l'execution
-- ----------------------------------------------------------------------------
select 'Extension reseau pg_net' as element,
       case when exists (select 1 from pg_extension where extname = 'pg_net')
            then 'OK' else 'MANQUANTE (activez-la dans Database > Extensions)' end as verdict
union all
select 'Declencheur d''envoi systeme',
       case when exists (select 1 from pg_trigger where tgname = 'trg_secoto_notification_push')
            then 'OK' else 'MANQUANT' end
union all
select 'Appareils abonnes aux notifications',
       coalesce((select count(*)::text || ' appareil(s)' from public.push_subscriptions), '0')
       || ' — si 0, activez les notifications depuis l''application sur chaque appareil';

notify pgrst, 'reload schema';
