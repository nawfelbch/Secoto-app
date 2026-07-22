-- ============================================================
-- SECOTO — Migration refonte : clients, sous-types transporteurs,
-- notifications temps réel et abonnements push.
-- À exécuter dans Supabase → SQL Editor. Idempotent (ré-exécutable).
-- ============================================================

-- 1) COMPTES : sous-type transporteur + type de client -------
--    transporter_type : 'convoyeur' | 'pl' | 'vl'  (NULL pour non-transporteurs)
--    client_type      : 'pro' | 'particulier'      (NULL pour non-clients)
alter table public.accounts
  add column if not exists transporter_type text,
  add column if not exists client_type text;

-- Le rôle accepte désormais 'admin' | 'transporter' | 'client'.
-- Si une contrainte CHECK stricte existe sur accounts.role, on l'assouplit.
do $$
begin
  if exists (
    select 1 from information_schema.constraint_column_usage
    where table_name = 'accounts' and column_name = 'role'
      and constraint_name = 'accounts_role_check'
  ) then
    alter table public.accounts drop constraint accounts_role_check;
  end if;
exception when others then null;
end $$;

-- 2) MISSIONS : rattacher une course au compte client qui la poste
alter table public.missions
  add column if not exists client_account_id uuid references public.accounts(id) on delete set null;

-- Idem sur les demandes (au cas où)
alter table public.mission_requests
  add column if not exists client_account_id uuid references public.accounts(id) on delete set null;

-- 3) NOTIFICATIONS (temps réel dans l'app) -------------------
create table if not exists public.notifications (
  id          uuid primary key default gen_random_uuid(),
  account_id  uuid not null references public.accounts(id) on delete cascade,
  type        text not null default 'info',           -- new_course | course_assigned | tracking_update | delivered | system
  title       text not null,
  body        text,
  mission_id  uuid,
  audience    text,                                   -- transporter | client | admin (informatif)
  is_read     boolean not null default false,
  created_at  timestamptz not null default now()
);

create index if not exists notifications_account_idx on public.notifications (account_id, created_at desc);
create index if not exists notifications_unread_idx  on public.notifications (account_id) where is_read = false;

alter table public.notifications enable row level security;

drop policy if exists "notif_select_own" on public.notifications;
create policy "notif_select_own" on public.notifications
  for select using (account_id = auth.uid());

drop policy if exists "notif_update_own" on public.notifications;
create policy "notif_update_own" on public.notifications
  for update using (account_id = auth.uid()) with check (account_id = auth.uid());

-- Tout utilisateur authentifié peut créer une notification destinée à autrui
-- (ex : un client poste une course => notification pour les transporteurs).
drop policy if exists "notif_insert_auth" on public.notifications;
create policy "notif_insert_auth" on public.notifications
  for insert to authenticated with check (true);

-- 4) ABONNEMENTS PUSH (scaffold web-push) --------------------
create table if not exists public.push_subscriptions (
  id          uuid primary key default gen_random_uuid(),
  account_id  uuid not null references public.accounts(id) on delete cascade,
  role        text,
  endpoint    text not null unique,
  p256dh      text not null,
  auth        text not null,
  user_agent  text,
  created_at  timestamptz not null default now()
);

create index if not exists push_sub_account_idx on public.push_subscriptions (account_id);
create index if not exists push_sub_role_idx    on public.push_subscriptions (role);

alter table public.push_subscriptions enable row level security;

drop policy if exists "push_manage_own" on public.push_subscriptions;
create policy "push_manage_own" on public.push_subscriptions
  for all using (account_id = auth.uid()) with check (account_id = auth.uid());

-- 5) MISSIONS : autoriser un client à publier / lire ses courses
--    (adapter selon vos policies existantes ; ces ajouts sont non destructifs)
drop policy if exists "missions_insert_client" on public.missions;
create policy "missions_insert_client" on public.missions
  for insert to authenticated
  with check (
    client_account_id = auth.uid()
    or exists (select 1 from public.accounts a where a.id = auth.uid() and a.role in ('admin','client'))
  );

drop policy if exists "missions_select_client_own" on public.missions;
create policy "missions_select_client_own" on public.missions
  for select using (
    client_account_id = auth.uid()
    or exists (select 1 from public.accounts a where a.id = auth.uid() and a.role in ('admin','transporter'))
  );

-- 6) SUIVI : un client peut lire les étapes de SES missions
drop policy if exists "tracking_select_client" on public.mission_tracking_events;
create policy "tracking_select_client" on public.mission_tracking_events
  for select using (
    exists (
      select 1 from public.missions m
      where m.id = mission_id
        and (m.client_account_id = auth.uid()
             or exists (select 1 from public.accounts a where a.id = auth.uid() and a.role in ('admin','transporter')))
    )
  );

drop policy if exists "tracking_photos_select_client" on public.mission_tracking_photos;
create policy "tracking_photos_select_client" on public.mission_tracking_photos
  for select using (
    exists (
      select 1 from public.missions m
      where m.id = mission_id
        and (m.client_account_id = auth.uid()
             or exists (select 1 from public.accounts a where a.id = auth.uid() and a.role in ('admin','transporter')))
    )
  );

-- 7) REALTIME : diffuser les changements de notifications
do $$
begin
  begin
    alter publication supabase_realtime add table public.notifications;
  exception when duplicate_object then null;
  end;
  begin
    alter publication supabase_realtime add table public.missions;
  exception when duplicate_object then null;
  end;
end $$;

-- ============================================================
-- Rappel : le trigger qui crée automatiquement une ligne dans
-- public.accounts à l'inscription (handle_new_user) doit recopier
-- role, full_name, company_name, phone, city, transporter_type,
-- client_type depuis raw_user_meta_data. Voir handle_new_user.sql.
-- ============================================================
