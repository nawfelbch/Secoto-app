-- 071 — Demande d'avis automatique apres livraison.
--
-- Le lendemain de la livraison a 10 h (heure de Paris), le client recoit un
-- e-mail avec un lien vers l'avis Google, et vers l'App Store des que
-- l'identifiant de l'app est renseigne dans review_policy. Une seule demande
-- par mission.
--
-- Tous les clients livres sont sollicites, sans tri sur leur satisfaction :
-- Google et Apple interdisent de ne solliciter que les clients contents. Seuls
-- sont ecartes les cas ou la course elle-meme a deraille (incident signale,
-- commande annulee, paiement rembourse) : c'est l'etat de la course qui decide,
-- jamais l'opinion du client.
--
-- La demande est preparee a la livraison, et son eligibilite est reverifiee au
-- moment de l'envoi : une annulation ou un remboursement survenu entre-temps
-- l'ecarte. Rien ici ne peut empecher de cloturer une livraison.

-- 1. Garder la trace d'un incident, meme une fois la livraison terminee -------
alter table public.missions add column if not exists had_incident boolean not null default false;

create or replace function secoto_private.trg_mission_had_incident()
returns trigger language plpgsql security definer set search_path = ''
as $f$
begin
  if new.progress_status = 'incident_reported' then
    new.had_incident := true;
  end if;
  return new;
end;
$f$;

drop trigger if exists trg_secoto_mission_had_incident on public.missions;
create trigger trg_secoto_mission_had_incident
  before insert or update of progress_status on public.missions
  for each row execute function secoto_private.trg_mission_had_incident();

-- 2. Reglages, modifiables sans deploiement -----------------------------------
insert into public.app_settings (key, value)
values ('review_policy', jsonb_build_object(
  'enabled', true,
  'google_url', 'https://g.page/r/Cfniz85kFWKNECE/review',
  'appstore_url', null,
  'send_hour', 10))
on conflict (key) do nothing;

-- 3. File des demandes ----------------------------------------------------------
create table if not exists public.review_requests (
  id          uuid primary key default gen_random_uuid(),
  mission_id  uuid not null unique references public.missions(id) on delete cascade,
  to_email    text not null,
  due_at      timestamptz not null,
  status      text not null default 'pending' check (status in ('pending', 'sent', 'skipped')),
  skip_reason text,
  sent_at     timestamptz,
  created_at  timestamptz not null default now()
);
create index if not exists review_requests_due_idx on public.review_requests (status, due_at);
alter table public.review_requests enable row level security;
-- Aucune policy : table reservee au service_role.

-- 4. Preparation au moment de la livraison --------------------------------------
create or replace function secoto_private.trg_mission_review_request()
returns trigger language plpgsql security definer set search_path = ''
as $f$
declare
  v_done_new boolean;
  v_done_old boolean;
  v_email    text;
  v_heure    integer;
begin
  v_done_new := coalesce(new.progress_status, '') in ('delivery_completed', 'completed') or new.status::text = 'completed';
  v_done_old := coalesce(old.progress_status, '') in ('delivery_completed', 'completed') or old.status::text = 'completed';
  if not v_done_new or v_done_old then return new; end if;
  if coalesce(new.had_incident, false) then return new; end if;

  select a.email into v_email
    from public.accounts a
   where a.id = new.client_account_id and a.deleted_at is null;
  v_email := coalesce(nullif(btrim(v_email), ''),
    case when btrim(coalesce(new.client_contact, '')) ~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$'
         then btrim(new.client_contact) end);
  if v_email is null then return new; end if;

  v_heure := coalesce((select (s.value ->> 'send_hour')::integer
                         from public.app_settings s where s.key = 'review_policy'), 10);

  insert into public.review_requests (mission_id, to_email, due_at)
  values (new.id, lower(v_email),
          (((now() at time zone 'Europe/Paris')::date + 1) + make_time(v_heure, 0, 0)) at time zone 'Europe/Paris')
  on conflict (mission_id) do nothing;
  return new;
exception when others then
  -- Une demande d'avis ne doit jamais empecher de cloturer une livraison.
  return new;
end;
$f$;

drop trigger if exists trg_secoto_mission_review_request on public.missions;
create trigger trg_secoto_mission_review_request
  after update of status, progress_status on public.missions
  for each row execute function secoto_private.trg_mission_review_request();

-- 5. Envoi des demandes echues (appele chaque minute par od-maintenance) -------
create or replace function public.secoto_review_requests_tick(p_limit integer default 20)
returns jsonb language plpgsql volatile security definer set search_path = ''
as $f$
declare
  v_policy   jsonb;
  v_google   text;
  v_appstore text;
  r          record;
  v_raison   text;
  v_corps    text;
  v_envoyes  integer := 0;
  v_ecartes  integer := 0;
begin
  select s.value into v_policy from public.app_settings s where s.key = 'review_policy';
  if not coalesce((v_policy ->> 'enabled')::boolean, false) then
    return jsonb_build_object('enabled', false);
  end if;
  v_google   := nullif(btrim(coalesce(v_policy ->> 'google_url', '')), '');
  v_appstore := nullif(btrim(coalesce(v_policy ->> 'appstore_url', '')), '');
  if v_google is null and v_appstore is null then
    return jsonb_build_object('enabled', true, 'error', 'aucun_lien');
  end if;

  for r in
    select rr.id, rr.mission_id, rr.to_email, m.client_name, m.vehicle, m.to_city,
           coalesce(m.had_incident, false) as had_incident, m.status::text as m_status
      from public.review_requests rr
      join public.missions m on m.id = rr.mission_id
     where rr.status = 'pending' and rr.due_at <= now()
     order by rr.due_at
     limit greatest(1, least(coalesce(p_limit, 20), 100))
     for update of rr skip locked
  loop
    v_raison := case
      when r.had_incident then 'incident'
      when r.m_status = 'cancelled' then 'mission_annulee'
      when exists (select 1 from public.transport_orders o
                    where o.mission_id = r.mission_id and o.status = 'cancelled') then 'commande_annulee'
      when exists (select 1 from public.payments p
                    where p.mission_id = r.mission_id and p.status = 'refunded') then 'rembourse'
    end;

    if v_raison is not null then
      update public.review_requests set status = 'skipped', skip_reason = v_raison where id = r.id;
      v_ecartes := v_ecartes + 1;
      continue;
    end if;

    v_corps :=
      case when nullif(btrim(coalesce(r.client_name, '')), '') is not null
           then 'Bonjour ' || btrim(r.client_name) || ',' else 'Bonjour,' end
      || E'\n\n'
      || 'Votre véhicule' || coalesce(' (' || nullif(btrim(coalesce(r.vehicle, '')), '') || ')', '')
      || ' a bien été livré' || coalesce(' à ' || nullif(btrim(coalesce(r.to_city, '')), ''), '')
      || '. Merci de nous avoir fait confiance.'
      || E'\n\n'
      || 'Si vous avez deux minutes, votre avis aide d''autres clients à nous choisir :'
      || E'\n' || coalesce(v_google, v_appstore)
      || E'\n\n'
      || case when v_google is not null and v_appstore is not null
              then 'Vous utilisez l''application SECOTO sur iPhone ? Vous pouvez aussi la noter ici :'
                   || E'\n' || v_appstore || E'\n\n'
              else '' end
      || 'L''équipe SECOTO' || E'\n' || '07 83 27 82 31';

    insert into public.email_outbox (to_email, subject, body_text, mission_id, event_key)
    values (r.to_email, 'Votre véhicule est bien arrivé — votre avis sur SECOTO',
            v_corps, r.mission_id, 'review:' || r.mission_id::text)
    on conflict (event_key) do nothing;

    update public.review_requests set status = 'sent', sent_at = now() where id = r.id;
    v_envoyes := v_envoyes + 1;
  end loop;

  return jsonb_build_object('enabled', true, 'sent', v_envoyes, 'skipped', v_ecartes);
end;
$f$;

revoke all on function public.secoto_review_requests_tick(integer) from public, anon, authenticated;
grant execute on function public.secoto_review_requests_tick(integer) to service_role;

-- 6. Controles ------------------------------------------------------------------
do $$
begin
  if not exists (select 1 from pg_trigger where tgname = 'trg_secoto_mission_review_request') then
    raise exception 'Declencheur de demande d''avis absent.';
  end if;
  if not exists (select 1 from pg_trigger where tgname = 'trg_secoto_mission_had_incident') then
    raise exception 'Declencheur d''incident absent.';
  end if;
  if (select value ->> 'google_url' from public.app_settings where key = 'review_policy') is null then
    raise exception 'Lien d''avis Google absent de review_policy.';
  end if;
  if has_function_privilege('anon', 'public.secoto_review_requests_tick(integer)', 'execute')
     or has_function_privilege('authenticated', 'public.secoto_review_requests_tick(integer)', 'execute') then
    raise exception 'secoto_review_requests_tick ne doit pas etre appelable depuis l''app.';
  end if;
  -- Calcul de l'echeance : lendemain 10 h, heure de Paris.
  if extract(hour from ((((timestamptz '2026-10-05 14:00+02' at time zone 'Europe/Paris')::date + 1)
        + make_time(10, 0, 0)) at time zone 'Europe/Paris') at time zone 'Europe/Paris') <> 10 then
    raise exception 'Echeance mal calculee.';
  end if;
end $$;
