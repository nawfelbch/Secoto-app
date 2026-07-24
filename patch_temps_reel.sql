-- ============================================================================
-- SECOTO — Patch « temps reel + fiabilite des alertes »
-- ----------------------------------------------------------------------------
-- A coller tel quel dans Supabase > SQL Editor > Run. Idempotent : peut etre
-- relance sans risque.
--
-- Ce patch :
--   1. Diffuse EN TEMPS REEL toutes les tables utiles (missions, candidatures,
--      demandes, frais, suivi, notifications) -> l'app recoit les changements
--      instantanement au lieu d'attendre un rafraichissement manuel.
--   2. Cree des DECLENCHEURS cote base : chaque candidature, chaque frais,
--      chaque demande genere AUTOMATIQUEMENT une notification pour l'admin,
--      meme si l'application de l'expediteur est fermee ou hors ligne.
--      C'est ce qui garantit que plus aucun frais ne se « perd ».
--   3. Corrige le depot de frais : un transporteur peut declarer ses frais
--      sur une mission qui lui est attribuee OU dont sa candidature a ete
--      acceptee.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 0) RAPPEL (sans effet si deja applique) : suppression en cascade des courses
--    + lecture des comptes clients par l'admin.
-- ----------------------------------------------------------------------------
do $$
declare
  t text;
  cname text;
  child_tables text[] := array[
    'mission_applications','mission_tracking_events',
    'mission_tracking_photos','documents','frais'
  ];
begin
  foreach t in array child_tables loop
    if to_regclass('public.'||t) is null then continue; end if;

    select tc.constraint_name into cname
    from information_schema.table_constraints tc
    join information_schema.key_column_usage kcu
      on tc.constraint_name = kcu.constraint_name and tc.table_schema = kcu.table_schema
    join information_schema.constraint_column_usage ccu
      on tc.constraint_name = ccu.constraint_name and tc.table_schema = ccu.table_schema
    where tc.constraint_type = 'FOREIGN KEY' and tc.table_schema = 'public'
      and tc.table_name = t and kcu.column_name = 'mission_id'
      and ccu.table_name = 'missions'
    limit 1;
    if cname is not null then
      execute format('alter table public.%I drop constraint %I', t, cname);
    end if;

    if exists (select 1 from information_schema.columns
               where table_schema='public' and table_name=t and column_name='mission_id') then
      execute format(
        'alter table public.%I add constraint %I foreign key (mission_id) references public.missions(id) on delete cascade',
        t, t||'_mission_id_fkey');
    end if;
  end loop;
end $$;

drop policy if exists accounts_admin_read on public.accounts;
create policy accounts_admin_read on public.accounts
  for select to authenticated
  using (public.secoto_is_admin() or id = auth.uid());

-- ----------------------------------------------------------------------------
-- 0.5) TABLE NOTIFICATIONS : creation / mise a niveau des colonnes manquantes.
--      (Sur certaines bases, la table existait sans la colonne « body ».)
-- ----------------------------------------------------------------------------
create table if not exists public.notifications (
  id          uuid primary key default gen_random_uuid(),
  account_id  uuid not null references public.accounts(id) on delete cascade,
  type        text not null default 'info',
  title       text not null,
  body        text,
  mission_id  uuid,
  audience    text,
  is_read     boolean not null default false,
  created_at  timestamptz not null default now()
);

alter table public.notifications add column if not exists type       text not null default 'info';
alter table public.notifications add column if not exists title      text;
alter table public.notifications add column if not exists body       text;
alter table public.notifications add column if not exists mission_id uuid;
alter table public.notifications add column if not exists audience   text;
alter table public.notifications add column if not exists is_read    boolean not null default false;
alter table public.notifications add column if not exists created_at timestamptz not null default now();

create index if not exists notifications_account_idx
  on public.notifications (account_id, created_at desc);

alter table public.notifications enable row level security;

drop policy if exists notif_select_own on public.notifications;
create policy notif_select_own on public.notifications
  for select to authenticated using (account_id = auth.uid());

drop policy if exists notif_update_own on public.notifications;
create policy notif_update_own on public.notifications
  for update to authenticated
  using (account_id = auth.uid()) with check (account_id = auth.uid());

drop policy if exists notif_insert_auth on public.notifications;
create policy notif_insert_auth on public.notifications
  for insert to authenticated with check (true);

-- ----------------------------------------------------------------------------
-- 1) TEMPS REEL : publication + identite complete des lignes
-- ----------------------------------------------------------------------------
-- REPLICA IDENTITY FULL : les evenements UPDATE/DELETE transportent la ligne
-- entiere (sinon une suppression arrive « vide » et l'app ne sait pas quoi
-- retirer de l'ecran).
do $$
declare
  t text;
  tables text[] := array[
    'missions', 'mission_requests', 'mission_applications',
    'frais', 'notifications', 'mission_tracking_events',
    'mission_tracking_photos', 'documents', 'accounts'
  ];
begin
  foreach t in array tables loop
    if to_regclass('public.' || t) is null then continue; end if;

    execute format('alter table public.%I replica identity full', t);

    begin
      execute format('alter publication supabase_realtime add table public.%I', t);
    exception
      when duplicate_object then null;   -- deja publiee
      when undefined_object then null;   -- publication absente (rare)
    end;
  end loop;
end $$;

-- ----------------------------------------------------------------------------
-- 2) NOTIFICATIONS AUTOMATIQUES COTE BASE
-- ----------------------------------------------------------------------------

-- 2.1 Envoi a tous les comptes admin.
create or replace function public.secoto_notify_admins(
  p_type text, p_title text, p_body text, p_mission uuid
)
returns void
language sql
security definer
set search_path = public
as $$
  insert into public.notifications (account_id, type, title, body, mission_id, audience)
  select a.id, p_type, p_title, p_body, p_mission, 'admin'
  from public.accounts a
  where a.role = 'admin';
$$;

-- 2.2 Envoi a un compte precis.
create or replace function public.secoto_notify_one(
  p_account uuid, p_type text, p_title text, p_body text, p_mission uuid
)
returns void
language sql
security definer
set search_path = public
as $$
  insert into public.notifications (account_id, type, title, body, mission_id, audience)
  select p_account, p_type, p_title, p_body, p_mission, null
  where p_account is not null;
$$;

grant execute on function public.secoto_notify_admins(text, text, text, uuid) to authenticated;
grant execute on function public.secoto_notify_one(uuid, text, text, text, uuid) to authenticated;

-- 2.3 Nouvelle CANDIDATURE -> alerte admin (avec le tarif propose).
create or replace function public.secoto_trg_application_notify()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_from text; v_to text;
begin
  select m.from_city, m.to_city into v_from, v_to
  from public.missions m where m.id = new.mission_id;

  perform public.secoto_notify_admins(
    'new_application',
    'Nouvelle candidature',
    coalesce(new.transporter_name, 'Un transporteur')
      || ' propose '
      || coalesce(trim(to_char(new.proposed_price, 'FM999999990')) || ' EUR', 'un tarif non renseigne')
      || ' - ' || coalesce(v_from, 'Depart') || ' vers ' || coalesce(v_to, 'Arrivee'),
    new.mission_id
  );
  return new;
end $$;

drop trigger if exists trg_secoto_application_notify on public.mission_applications;
create trigger trg_secoto_application_notify
  after insert on public.mission_applications
  for each row execute function public.secoto_trg_application_notify();

-- 2.4 Nouveau FRAIS -> alerte admin (c'est le correctif du frais « jamais recu »).
create or replace function public.secoto_trg_frais_notify()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_ref text; v_name text;
begin
  select m.public_ref into v_ref from public.missions m where m.id = new.mission_id;
  select a.full_name into v_name from public.accounts a where a.id = new.transporter_id;

  perform public.secoto_notify_admins(
    'frais',
    'Nouveau frais a valider',
    coalesce(v_name, 'Un transporteur')
      || ' a declare ' || trim(to_char(new.montant, 'FM999999990D00')) || ' EUR ('
      || new.type::text || ')'
      || coalesce(' sur ' || v_ref, ''),
    new.mission_id
  );
  return new;
end $$;

drop trigger if exists trg_secoto_frais_notify on public.frais;
create trigger trg_secoto_frais_notify
  after insert on public.frais
  for each row execute function public.secoto_trg_frais_notify();

-- 2.5 Frais VALIDE / REFUSE -> retour au transporteur.
create or replace function public.secoto_trg_frais_status_notify()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.statut is distinct from old.statut then
    perform public.secoto_notify_one(
      new.transporter_id,
      'frais_status',
      case when new.statut::text = 'valide' then 'Frais valide' else 'Frais refuse' end,
      trim(to_char(new.montant, 'FM999999990D00')) || ' EUR - '
        || case when new.statut::text = 'valide'
                then 'remboursement en cours.'
                else coalesce('motif : ' || new.motif_refus, 'frais refuse.') end,
      new.mission_id
    );
  end if;
  return new;
end $$;

drop trigger if exists trg_secoto_frais_status_notify on public.frais;
create trigger trg_secoto_frais_status_notify
  after update on public.frais
  for each row execute function public.secoto_trg_frais_status_notify();

-- 2.6 Nouvelle DEMANDE (client web ou transporteur) -> alerte admin.
create or replace function public.secoto_trg_request_notify()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.secoto_notify_admins(
    'new_request',
    'Nouvelle demande de transport',
    coalesce(new.from_city, 'Depart') || ' vers ' || coalesce(new.to_city, 'Arrivee')
      || coalesce(' - ' || new.client_phone, ''),
    null
  );
  return new;
end $$;

drop trigger if exists trg_secoto_request_notify on public.mission_requests;
create trigger trg_secoto_request_notify
  after insert on public.mission_requests
  for each row execute function public.secoto_trg_request_notify();

-- 2.7 Nouvelle COURSE PUBLIEE -> alerte a tous les transporteurs verifies.
--     (Auparavant la notification n'etait creee que si le transporteur avait
--      l'application ouverte au moment exact de la publication.)
create or replace function public.secoto_trg_mission_published_notify()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.status::text = 'published' then
    insert into public.notifications (account_id, type, title, body, mission_id, audience)
    select a.id, 'new_course', 'Nouvelle course disponible',
           coalesce(new.from_city, 'Depart') || ' vers ' || coalesce(new.to_city, 'Arrivee'),
           new.id, 'transporter'
    from public.accounts a
    where a.role = 'transporter' and coalesce(a.is_verified, false) = true;
  end if;
  return new;
end $$;

drop trigger if exists trg_secoto_mission_published_notify on public.missions;
create trigger trg_secoto_mission_published_notify
  after insert on public.missions
  for each row execute function public.secoto_trg_mission_published_notify();

-- ----------------------------------------------------------------------------
-- 3) DEPOT DE FRAIS : regle d'ecriture elargie
-- ----------------------------------------------------------------------------
-- Avant : la mission devait avoir assigned_transporter_id = moi.
-- Maintenant : cela reste valable, MAIS une candidature acceptee suffit aussi
-- (cas des missions attribuees avant la mise en place du champ).
drop policy if exists frais_transporter_insert on public.frais;
create policy frais_transporter_insert on public.frais
  for insert to authenticated
  with check (
    transporter_id = auth.uid()
    and statut = 'en_attente'
    and exists (
      select 1 from public.missions m
      where m.id = mission_id
        and (
          m.assigned_transporter_id = auth.uid()
          or exists (
            select 1 from public.mission_applications ma
            where ma.mission_id = m.id
              and ma.transporter_id = auth.uid()
              and ma.status = 'accepted'
          )
        )
    )
  );

-- Le transporteur relit ses propres frais (rappel, idempotent).
drop policy if exists frais_transporter_select on public.frais;
create policy frais_transporter_select on public.frais
  for select to authenticated
  using (transporter_id = auth.uid());

-- ----------------------------------------------------------------------------
-- 4) INDEX utiles au tri par prix et au flux de notifications
-- ----------------------------------------------------------------------------
create index if not exists idx_applications_mission_price
  on public.mission_applications (mission_id, proposed_price asc nulls last);

create index if not exists idx_notifications_mission
  on public.notifications (mission_id);

-- ----------------------------------------------------------------------------
-- 5) Rechargement du cache de schema PostgREST
-- ----------------------------------------------------------------------------
notify pgrst, 'reload schema';
