-- ============================================================================
-- SECOTO — MIGRATION 142 : CHAT EN DIRECT CLIENT ↔ TRANSPORTEUR (PAR MISSION)
-- ----------------------------------------------------------------------------
-- Demandé par Nawfal le 13/11/2026, sur le modèle de SECOTO Rénovation.
-- Le client et le transporteur retenu échangent directement dans l'app, au
-- sujet de leur transport (heure d'enlèvement, accès, clés…).
--
-- Règles :
--   · un fil par mission ; participants : le client de la commande, le
--     transporteur attribué (et son salarié affecté), l'admin SECOTO ;
--   · écriture possible dès qu'un transporteur est attribué, jusqu'à 7 jours
--     après la livraison ; lecture de l'historique ensuite ;
--   · chaque message peut être signalé (exigence Apple 1.2) : l'admin est
--     prévenu ;
--   · notification (cloche + push) à l'autre partie, au plus une toutes les
--     10 minutes par fil pour ne pas spammer ;
--   · tout passe par des fonctions (aucun accès direct à la table).
-- ADDITIF, rejouable. Aucun impact sur les paiements.
-- ============================================================================

create table if not exists public.mission_messages (
  id          uuid primary key default gen_random_uuid(),
  mission_id  uuid not null references public.missions(id) on delete cascade,
  auteur_id   uuid not null,
  auteur_role text not null check (auteur_role in ('client', 'transporteur', 'admin')),
  texte       text not null check (length(texte) between 1 and 2000),
  signale_le  timestamptz,
  signale_par uuid,
  cree_le     timestamptz not null default now()
);
create index if not exists idx_mission_messages_fil on public.mission_messages(mission_id, cree_le);
alter table public.mission_messages enable row level security;
revoke all on table public.mission_messages from public, anon, authenticated;

-- Dernière lecture de chaque participant (pastille « non lu »).
create table if not exists public.mission_messages_lus (
  mission_id uuid not null references public.missions(id) on delete cascade,
  account_id uuid not null,
  lu_le      timestamptz not null default now(),
  primary key (mission_id, account_id)
);
alter table public.mission_messages_lus enable row level security;
revoke all on table public.mission_messages_lus from public, anon, authenticated;

-- Rôle de l'utilisateur dans le fil d'une mission (null : aucun accès).
create or replace function secoto_private.chat_role(p_mission uuid, p_user uuid default auth.uid())
returns text language sql stable security definer set search_path = '' as $$
  select case
    when p_user is null then null
    when secoto_private.is_admin(p_user) then 'admin'
    when exists (select 1 from public.missions m where m.id = p_mission
                   and (m.assigned_transporter_id = p_user or m.carrier_employee_id = p_user)) then 'transporteur'
    when exists (select 1 from public.missions m where m.id = p_mission and m.client_account_id = p_user)
      or exists (select 1 from public.transport_orders o where o.mission_id = p_mission and o.account_id = p_user) then 'client'
  end;
$$;
revoke all on function secoto_private.chat_role(uuid, uuid) from public, anon, authenticated;

-- Le fil est ouvert à l'écriture : transporteur attribué, mission non annulée,
-- jusqu'à 7 jours après la livraison.
create or replace function secoto_private.chat_ouvert(p_mission uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.missions m
     where m.id = p_mission and m.assigned_transporter_id is not null
       and m.status::text not in ('cancelled', 'published')
       and (m.status::text <> 'completed' or coalesce(m.last_tracking_event_at, m.updated_at) > now() - interval '7 days'));
$$;
revoke all on function secoto_private.chat_ouvert(uuid) from public, anon, authenticated;

-- Lire le fil (et le marquer lu).
create or replace function public.secoto_chat_messages(p_mission uuid)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare
  v_role text := secoto_private.chat_role(p_mission);
  v_messages jsonb;
begin
  if v_role is null then raise exception 'Accès refusé.'; end if;
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', mm.id, 'auteur_role', mm.auteur_role, 'moi', mm.auteur_id = auth.uid(),
           'texte', mm.texte, 'cree_le', mm.cree_le, 'signale', mm.signale_le is not null)
         order by mm.cree_le), '[]'::jsonb)
    into v_messages
    from public.mission_messages mm where mm.mission_id = p_mission;
  if v_role <> 'admin' then
    insert into public.mission_messages_lus(mission_id, account_id, lu_le) values (p_mission, auth.uid(), now())
    on conflict (mission_id, account_id) do update set lu_le = excluded.lu_le;
  end if;
  return jsonb_build_object('role', v_role, 'ouvert', secoto_private.chat_ouvert(p_mission), 'messages', v_messages);
end;
$$;

-- Envoyer un message.
create or replace function public.secoto_chat_envoyer(p_mission uuid, p_texte text)
returns uuid language plpgsql security definer set search_path = '' as $$
declare
  v_role text := secoto_private.chat_role(p_mission);
  v_texte text := left(btrim(coalesce(p_texte, '')), 2000);
  v_id uuid;
  m public.missions%rowtype;
  v_client uuid;
  v_dest uuid[];
  d uuid;
  v_titre text;
begin
  if v_role is null then raise exception 'Accès refusé.'; end if;
  if v_texte = '' then raise exception 'Message vide.'; end if;
  if not secoto_private.chat_ouvert(p_mission) then raise exception 'Cette conversation est fermée.'; end if;
  -- Anti-abus simple : 30 messages par 10 minutes et par personne.
  if (select count(*) from public.mission_messages
       where auteur_id = auth.uid() and cree_le > now() - interval '10 minutes') >= 30 then
    raise exception 'Trop de messages en peu de temps, réessayez dans quelques minutes.';
  end if;

  insert into public.mission_messages(mission_id, auteur_id, auteur_role, texte)
  values (p_mission, auth.uid(), v_role, v_texte) returning id into v_id;

  -- Notification à l'autre partie (au plus une toutes les 10 minutes par fil et par destinataire).
  select * into m from public.missions where id = p_mission;
  select coalesce(m.client_account_id, (select o.account_id from public.transport_orders o where o.mission_id = p_mission limit 1)) into v_client;
  v_dest := case v_role
    when 'client' then array_remove(array[m.assigned_transporter_id, m.carrier_employee_id], null)
    when 'transporteur' then array_remove(array[v_client], null)
    else array_remove(array[v_client, m.assigned_transporter_id, m.carrier_employee_id], null) end;
  v_titre := case v_role when 'client' then 'Nouveau message du client'
                         when 'transporteur' then 'Nouveau message du transporteur'
                         else 'Nouveau message de SECOTO' end;
  foreach d in array v_dest loop
    continue when d = auth.uid();
    perform secoto_private.notify_event(d, 'order_update', v_titre || ' · ' || coalesce(m.public_ref, ''),
      left(v_texte, 140), p_mission, case when d = v_client then 'courses' else 'offre' end,
      'chat:' || p_mission::text || ':' || d::text || ':' || floor(extract(epoch from now()) / 600)::bigint::text, p_mission);
  end loop;
  return v_id;
end;
$$;

-- Signaler un message (contenu inapproprié) : l'admin est prévenu.
create or replace function public.secoto_chat_signaler(p_message uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare
  mm public.mission_messages%rowtype;
begin
  select * into mm from public.mission_messages where id = p_message;
  if mm.id is null or secoto_private.chat_role(mm.mission_id) is null then raise exception 'Accès refusé.'; end if;
  if mm.auteur_id = auth.uid() then raise exception 'Vous ne pouvez pas signaler votre propre message.'; end if;
  update public.mission_messages set signale_le = coalesce(signale_le, now()), signale_par = coalesce(signale_par, auth.uid())
   where id = p_message;
  perform secoto_private.notify_admins_event('order_update', 'Message signalé dans un chat',
    (select coalesce(public_ref, '') from public.missions where id = mm.mission_id) || ' : ' || left(mm.texte, 140),
    'requests', 'chat-signale:' || p_message::text, mm.mission_id);
end;
$$;

-- Nombre de messages non lus par mission, pour l'utilisateur connecté.
create or replace function public.secoto_chat_non_lus()
returns jsonb language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_object_agg(x.mission_id, x.n), '{}'::jsonb) from (
    select mm.mission_id, count(*) n
      from public.mission_messages mm
      left join public.mission_messages_lus l on l.mission_id = mm.mission_id and l.account_id = auth.uid()
     where mm.auteur_id <> auth.uid()
       and mm.cree_le > coalesce(l.lu_le, '-infinity'::timestamptz)
       and mm.cree_le > now() - interval '60 days'
       and secoto_private.chat_role(mm.mission_id) in ('client', 'transporteur')
     group by mm.mission_id) x;
$$;

do $$
declare f text;
begin
  foreach f in array array['secoto_chat_messages(uuid)', 'secoto_chat_envoyer(uuid,text)', 'secoto_chat_signaler(uuid)', 'secoto_chat_non_lus()'] loop
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
end $$;

notify pgrst, 'reload schema';
