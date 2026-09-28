-- ============================================================================
-- SECOTO — 060 : ESPACE ENTREPRISE DE TRANSPORT
-- ----------------------------------------------------------------------------
-- Une entreprise de transport inscrit ses convoyeurs dans l'application.
--
-- QUATRE REGLES, DECIDEES LE 28/09/2026
--   1. Les versements vont UNIQUEMENT a l'entreprise. Jamais a un employe.
--   2. Seul un gerant accepte une mission. Un employe peut la suggerer.
--   3. Un employe ne voit AUCUN montant : ni le prix client, ni la
--      remuneration de son entreprise.
--   4. Une entreprise peut avoir plusieurs gerants, pour qu'elle ne soit
--      jamais bloquee par l'indisponibilite d'une seule personne.
--
-- COMMENT LA REGLE 1 EST GARANTIE
--   Pas par la bonne tenue des ecrans : par un declencheur sur les missions.
--   Des qu'une mission est attribuee a un membre d'une entreprise, le
--   beneficiaire est réécrit vers le compte de versement de l'entreprise, et
--   l'employe devient l'executant designe. Un employe attribue directement est
--   refuse. Aucun chemin d'attribution — admin, acceptation d'offre, reprise
--   manuelle — ne peut contourner cela, puisque tous passent par la table.
--
-- L'entreprise reutilise business_accounts, qui servait jusqu'ici aux
-- entreprises CLIENTES. La colonne kind separe les deux usages.
-- ============================================================================

-- 1. L'entreprise -------------------------------------------------------------
alter table public.business_accounts
  add column if not exists kind text not null default 'client',
  add column if not exists payout_account_id uuid references public.accounts(id);

do $contrainte$
begin
  if not exists (
    select 1 from pg_constraint where conname = 'business_accounts_kind_check')
  then
    alter table public.business_accounts
      add constraint business_accounts_kind_check
      check (kind in ('client', 'transporteur'));
  end if;
end
$contrainte$;

comment on column public.business_accounts.kind is
  'client : entreprise qui commande des transports. transporteur : entreprise '
  'de transport qui emploie des convoyeurs.';
comment on column public.business_accounts.payout_account_id is
  'Compte qui recoit TOUS les versements de l''entreprise. Jamais un employe.';

alter table public.missions
  add column if not exists carrier_company_id uuid references public.business_accounts(id),
  add column if not exists carrier_employee_id uuid references public.accounts(id);

create index if not exists missions_carrier_company_idx
  on public.missions(carrier_company_id) where carrier_company_id is not null;
create index if not exists missions_carrier_employee_idx
  on public.missions(carrier_employee_id) where carrier_employee_id is not null;

comment on column public.missions.carrier_employee_id is
  'Convoyeur designe pour executer la mission. Il n''en est jamais le '
  'beneficiaire : le versement va au compte de versement de l''entreprise.';

-- 2. Invitations --------------------------------------------------------------
create table if not exists public.carrier_invitations (
  id          uuid primary key default gen_random_uuid(),
  company_id  uuid not null references public.business_accounts(id) on delete cascade,
  email       text not null check (email ~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$'),
  token       text not null unique,
  status      text not null default 'pending' check (status in ('pending', 'accepted', 'revoked')),
  invited_by  uuid not null references public.accounts(id),
  accepted_by uuid references public.accounts(id),
  accepted_at timestamptz,
  created_at  timestamptz not null default now()
);
create index if not exists carrier_invitations_company_idx on public.carrier_invitations(company_id, status);
alter table public.carrier_invitations enable row level security;
revoke all on table public.carrier_invitations from public, anon, authenticated;

-- 3. Suggestions des employes -------------------------------------------------
create table if not exists public.carrier_suggestions (
  id          uuid primary key default gen_random_uuid(),
  company_id  uuid not null references public.business_accounts(id) on delete cascade,
  mission_id  uuid not null references public.missions(id) on delete cascade,
  employee_id uuid not null references public.accounts(id),
  note        text check (note is null or length(note) <= 500),
  status      text not null default 'pending' check (status in ('pending', 'retenue', 'ecartee')),
  created_at  timestamptz not null default now(),
  unique (mission_id, employee_id)
);
create index if not exists carrier_suggestions_company_idx on public.carrier_suggestions(company_id, status, created_at desc);
alter table public.carrier_suggestions enable row level security;
revoke all on table public.carrier_suggestions from public, anon, authenticated;

-- 4. Qui est quoi -------------------------------------------------------------
create or replace function secoto_private.carrier_of(p_account uuid default auth.uid())
returns uuid language sql stable security definer set search_path = ''
as $f$
  select bm.business_id
  from public.business_members bm
  join public.business_accounts b on b.id = bm.business_id
  where bm.account_id = p_account and b.kind = 'transporteur'
  order by bm.created_at
  limit 1;
$f$;

create or replace function secoto_private.is_carrier_owner(p_company uuid, p_account uuid default auth.uid())
returns boolean language sql stable security definer set search_path = ''
as $f$
  select p_company is not null and exists (
    select 1 from public.business_members bm
    join public.business_accounts b on b.id = bm.business_id
    where bm.business_id = p_company and bm.account_id = p_account
      and bm.role = 'owner' and b.kind = 'transporteur');
$f$;

-- 4 bis. CLOISONNEMENT : une societe cliente n'est pas une societe de transport
-- is_business_member sert partout au parcours CLIENT (devis, commandes,
-- abonnements, documents de la societe). Sans filtre sur kind, un gerant
-- pourrait presenter son entreprise de transport comme la societe cliente d'un
-- devis. Les deux mondes sont desormais separes : le client passe par
-- is_business_member, le transporteur par carrier_of et is_carrier_owner.
create or replace function secoto_private.is_business_member(p_business_id uuid, p_account uuid default auth.uid())
returns boolean language sql stable security definer set search_path = ''
as $f$
  select exists (
    select 1 from public.business_members bm
    join public.business_accounts b on b.id = bm.business_id
    where bm.business_id = p_business_id and bm.account_id = p_account
      and b.kind = 'client');
$f$;

-- 5. LA GARANTIE : le versement ne peut aller qu'a l'entreprise ---------------
create or replace function secoto_private.trg_carrier_payee()
returns trigger language plpgsql security definer set search_path = ''
as $f$
declare
  v_company uuid;
  v_role    text;
  v_payout  uuid;
begin
  if new.assigned_transporter_id is null then
    return new;
  end if;
  if tg_op = 'UPDATE'
     and new.assigned_transporter_id is not distinct from old.assigned_transporter_id then
    return new;
  end if;

  select bm.business_id, bm.role into v_company, v_role
  from public.business_members bm
  join public.business_accounts b on b.id = bm.business_id
  where bm.account_id = new.assigned_transporter_id and b.kind = 'transporteur'
  order by bm.created_at
  limit 1;

  if v_company is null then
    return new;  -- transporteur independant : rien ne change.
  end if;

  if v_role <> 'owner' then
    raise exception 'Seul un gerant peut accepter une mission pour son entreprise.'
      using errcode = '42501';
  end if;

  select b.payout_account_id into v_payout
  from public.business_accounts b where b.id = v_company;

  new.carrier_company_id := v_company;

  -- Le beneficiaire est TOUJOURS le compte de versement de l'entreprise.
  if v_payout is not null and v_payout <> new.assigned_transporter_id then
    new.assigned_transporter_id := v_payout;
    select coalesce(a.company_name, a.full_name) into new.assigned_transporter_name
    from public.accounts a where a.id = v_payout;
  end if;

  return new;
end;
$f$;

drop trigger if exists trg_secoto_carrier_payee on public.missions;
create trigger trg_secoto_carrier_payee
  before insert or update of assigned_transporter_id on public.missions
  for each row execute function secoto_private.trg_carrier_payee();

-- 5 bis. Le meme verrou sur les commandes ------------------------------------
-- L'indemnite d'annulation tardive ne lit pas la mission : elle lit
-- transport_orders.assigned_partner_id. Sans ce second declencheur, elle
-- aurait ete versee au gerant a titre personnel et non a l'entreprise.
create or replace function secoto_private.trg_carrier_payee_order()
returns trigger language plpgsql security definer set search_path = ''
as $f$
declare
  v_payout uuid;
begin
  if new.assigned_partner_id is null then
    return new;
  end if;
  if tg_op = 'UPDATE'
     and new.assigned_partner_id is not distinct from old.assigned_partner_id then
    return new;
  end if;

  select b.payout_account_id into v_payout
  from public.business_members bm
  join public.business_accounts b on b.id = bm.business_id
  where bm.account_id = new.assigned_partner_id and b.kind = 'transporteur'
  order by bm.created_at
  limit 1;

  if v_payout is not null and v_payout <> new.assigned_partner_id then
    new.assigned_partner_id := v_payout;
  end if;

  return new;
end;
$f$;

drop trigger if exists trg_secoto_carrier_payee_order on public.transport_orders;
create trigger trg_secoto_carrier_payee_order
  before insert or update of assigned_partner_id on public.transport_orders
  for each row execute function secoto_private.trg_carrier_payee_order();

-- 6. Creer l'entreprise -------------------------------------------------------
create or replace function public.secoto_carrier_create(p_name text, p_siren text default null)
returns jsonb language plpgsql volatile security definer set search_path = ''
as $f$
declare
  v_user uuid := secoto_private.assert_authenticated();
  v_id   uuid;
begin
  if not (secoto_private.is_verified_transporter(v_user) or secoto_private.is_admin(v_user)) then
    raise exception 'Reserve aux transporteurs verifies.' using errcode = '42501';
  end if;
  if length(btrim(coalesce(p_name, ''))) not between 2 and 160 then
    raise exception 'Indiquez le nom de l''entreprise.';
  end if;

  v_id := secoto_private.carrier_of(v_user);
  if v_id is not null then
    raise exception 'Vous appartenez deja a une entreprise de transport.';
  end if;

  insert into public.business_accounts(name, siren, created_by, kind, payout_account_id)
  values (btrim(p_name),
          nullif(regexp_replace(coalesce(p_siren, ''), '\s', '', 'g'), ''),
          v_user, 'transporteur', v_user)
  returning id into v_id;

  insert into public.business_members(business_id, account_id, role)
  values (v_id, v_user, 'owner');

  perform secoto_private.audit('carrier_company_created', 'business_account', v_id::text,
    jsonb_build_object('name', btrim(p_name)));

  return jsonb_build_object('id', v_id, 'name', btrim(p_name));
end;
$f$;

-- 7. Inviter un convoyeur -----------------------------------------------------
create or replace function public.secoto_carrier_invite(p_email text)
returns jsonb language plpgsql volatile security definer set search_path = ''
as $f$
declare
  v_user    uuid := secoto_private.assert_authenticated();
  v_company uuid := secoto_private.carrier_of(v_user);
  v_token   text;
begin
  if not secoto_private.is_carrier_owner(v_company, v_user) then
    raise exception 'Reserve aux gerants de l''entreprise.' using errcode = '42501';
  end if;
  if coalesce(p_email, '') !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' then
    raise exception 'Adresse e-mail invalide.';
  end if;

  v_token := secoto_private.new_link_token();

  insert into public.carrier_invitations(company_id, email, token, invited_by)
  values (v_company, lower(btrim(p_email)), v_token, v_user);

  return jsonb_build_object('token', v_token, 'email', lower(btrim(p_email)));
end;
$f$;

create or replace function public.secoto_carrier_accept_invite(p_token text)
returns jsonb language plpgsql volatile security definer set search_path = ''
as $f$
declare
  v_user uuid := secoto_private.assert_authenticated();
  v_inv  public.carrier_invitations%rowtype;
begin
  select * into v_inv from public.carrier_invitations i
   where i.token = p_token and i.status = 'pending' for update;
  if not found then
    raise exception 'Invitation introuvable ou deja utilisee.';
  end if;
  if secoto_private.carrier_of(v_user) is not null then
    raise exception 'Vous appartenez deja a une entreprise de transport.';
  end if;

  insert into public.business_members(business_id, account_id, role)
  values (v_inv.company_id, v_user, 'member')
  on conflict (business_id, account_id) do nothing;

  update public.carrier_invitations
     set status = 'accepted', accepted_by = v_user, accepted_at = now()
   where id = v_inv.id;

  return jsonb_build_object('company_id', v_inv.company_id);
end;
$f$;

-- 8. Gerer l'equipe -----------------------------------------------------------
create or replace function public.secoto_carrier_set_role(p_account_id uuid, p_role text)
returns jsonb language plpgsql volatile security definer set search_path = ''
as $f$
declare
  v_user    uuid := secoto_private.assert_authenticated();
  v_company uuid := secoto_private.carrier_of(v_user);
  v_gerants integer;
begin
  if not secoto_private.is_carrier_owner(v_company, v_user) then
    raise exception 'Reserve aux gerants de l''entreprise.' using errcode = '42501';
  end if;
  if p_role not in ('owner', 'member') then
    raise exception 'Role inconnu.';
  end if;

  -- Une entreprise ne peut pas se retrouver sans gerant.
  if p_role = 'member' then
    select count(*) into v_gerants from public.business_members bm
     where bm.business_id = v_company and bm.role = 'owner';
    if v_gerants <= 1 then
      raise exception 'L''entreprise doit garder au moins un gerant.';
    end if;
  end if;

  update public.business_members set role = p_role
   where business_id = v_company and account_id = p_account_id;
  if not found then
    raise exception 'Ce compte ne fait pas partie de l''entreprise.';
  end if;

  return jsonb_build_object('account_id', p_account_id, 'role', p_role);
end;
$f$;

create or replace function public.secoto_carrier_remove_member(p_account_id uuid)
returns jsonb language plpgsql volatile security definer set search_path = ''
as $f$
declare
  v_user    uuid := secoto_private.assert_authenticated();
  v_company uuid := secoto_private.carrier_of(v_user);
  v_payout  uuid;
  v_encours integer;
begin
  if not secoto_private.is_carrier_owner(v_company, v_user) then
    raise exception 'Reserve aux gerants de l''entreprise.' using errcode = '42501';
  end if;

  select b.payout_account_id into v_payout
  from public.business_accounts b where b.id = v_company;
  if p_account_id = v_payout then
    raise exception 'Designez d''abord un autre compte de versement.';
  end if;

  -- Un convoyeur qui part ne doit pas laisser de mission sans executant.
  select count(*) into v_encours from public.missions m
   where m.carrier_employee_id = p_account_id
     and m.status::text not in ('completed', 'cancelled');
  if v_encours > 0 then
    raise exception 'Ce convoyeur a % mission(s) en cours : reaffectez-les d''abord.', v_encours;
  end if;

  delete from public.business_members
   where business_id = v_company and account_id = p_account_id and role <> 'owner';
  if not found then
    raise exception 'Retrait impossible : compte absent, ou gerant a retrograder d''abord.';
  end if;

  return jsonb_build_object('account_id', p_account_id, 'removed', true);
end;
$f$;

-- 9. Suggestion d'un employe, decision d'un gerant ----------------------------
create or replace function public.secoto_carrier_suggest(p_mission_id uuid, p_note text default null)
returns jsonb language plpgsql volatile security definer set search_path = ''
as $f$
declare
  v_user    uuid := secoto_private.assert_authenticated();
  v_company uuid := secoto_private.carrier_of(v_user);
  v_gerant  record;
  v_mission public.missions%rowtype;
begin
  if v_company is null then
    raise exception 'Vous n''appartenez a aucune entreprise de transport.' using errcode = '42501';
  end if;
  select * into v_mission from public.missions m where m.id = p_mission_id;
  if not found or v_mission.status::text <> 'published' then
    raise exception 'Cette mission n''est plus proposee.';
  end if;

  insert into public.carrier_suggestions(company_id, mission_id, employee_id, note)
  values (v_company, p_mission_id, v_user, nullif(btrim(coalesce(p_note, '')), ''))
  on conflict (mission_id, employee_id) do nothing;

  for v_gerant in
    select bm.account_id from public.business_members bm
     where bm.business_id = v_company and bm.role = 'owner'
  loop
    perform secoto_private.notify_event(
      v_gerant.account_id, 'course_assigned', 'Mission suggeree par un convoyeur',
      format('%s vers %s : un convoyeur de votre equipe propose cette mission.',
        v_mission.from_city, v_mission.to_city),
      p_mission_id, 'courses',
      'carrier-suggestion:' || p_mission_id::text || ':' || v_user::text, p_mission_id);
  end loop;

  return jsonb_build_object('mission_id', p_mission_id, 'suggested', true);
end;
$f$;

create or replace function public.secoto_carrier_assign_employee(p_mission_id uuid, p_account_id uuid)
returns jsonb language plpgsql volatile security definer set search_path = ''
as $f$
declare
  v_user    uuid := secoto_private.assert_authenticated();
  v_company uuid := secoto_private.carrier_of(v_user);
  v_mission public.missions%rowtype;
begin
  if not secoto_private.is_carrier_owner(v_company, v_user) then
    raise exception 'Reserve aux gerants de l''entreprise.' using errcode = '42501';
  end if;

  select * into v_mission from public.missions m
   where m.id = p_mission_id and m.carrier_company_id = v_company for update;
  if not found then
    raise exception 'Cette mission n''appartient pas a votre entreprise.' using errcode = '42501';
  end if;

  if p_account_id is not null and not exists (
    select 1 from public.business_members bm
     where bm.business_id = v_company and bm.account_id = p_account_id)
  then
    raise exception 'Ce compte ne fait pas partie de l''entreprise.';
  end if;

  update public.missions set carrier_employee_id = p_account_id where id = p_mission_id;

  update public.carrier_suggestions
     set status = case when employee_id = p_account_id then 'retenue' else 'ecartee' end
   where mission_id = p_mission_id and status = 'pending';

  if p_account_id is not null then
    perform secoto_private.notify_event(
      p_account_id, 'course_assigned', 'Vous etes designe sur une mission',
      format('%s vers %s.', v_mission.from_city, v_mission.to_city),
      p_mission_id, 'courses', 'carrier-assign:' || p_mission_id::text, p_mission_id);
  end if;

  return jsonb_build_object('mission_id', p_mission_id, 'employee_id', p_account_id);
end;
$f$;

-- 10. Le tableau de l'entreprise ----------------------------------------------
-- Un gerant voit l'equipe, les missions et l'argent. Un employe voit son
-- entreprise et ses missions, AUCUN montant.
create or replace function public.secoto_carrier_overview()
returns jsonb language plpgsql stable security definer set search_path = ''
as $f$
declare
  v_user    uuid := secoto_private.assert_authenticated();
  v_company uuid := secoto_private.carrier_of(v_user);
  v_owner   boolean;
  v_b       public.business_accounts%rowtype;
begin
  if v_company is null then
    return jsonb_build_object('company', null);
  end if;

  v_owner := secoto_private.is_carrier_owner(v_company, v_user);
  select * into v_b from public.business_accounts b where b.id = v_company;

  if not v_owner then
    -- Employe : sa societe, ses missions, pas un euro.
    return jsonb_build_object(
      'company', jsonb_build_object('id', v_b.id, 'name', v_b.name, 'role', 'member'),
      'missions', coalesce((
        select jsonb_agg(jsonb_build_object(
          'id', m.id, 'public_ref', m.public_ref, 'status', m.status,
          'progress_status', m.progress_status,
          'from_city', m.from_city, 'to_city', m.to_city,
          'mission_date', m.mission_date, 'vehicle', m.vehicle)
          order by m.mission_date)
        from public.missions m
        where m.carrier_employee_id = v_user
          and m.status::text not in ('cancelled')), '[]'::jsonb));
  end if;

  return jsonb_build_object(
    'company', jsonb_build_object(
      'id', v_b.id, 'name', v_b.name, 'siren', v_b.siren, 'role', 'owner',
      'payout_account_id', v_b.payout_account_id),
    'members', coalesce((
      select jsonb_agg(jsonb_build_object(
        'account_id', a.id, 'name', coalesce(a.company_name, a.full_name),
        'email', a.email, 'role', bm.role,
        'missions_en_cours', (
          select count(*) from public.missions m
           where m.carrier_employee_id = a.id
             and m.status::text not in ('completed', 'cancelled')))
        order by bm.role, a.full_name)
      from public.business_members bm join public.accounts a on a.id = bm.account_id
      where bm.business_id = v_company), '[]'::jsonb),
    'invitations', coalesce((
      select jsonb_agg(jsonb_build_object('id', i.id, 'email', i.email, 'token', i.token, 'created_at', i.created_at)
        order by i.created_at desc)
      from public.carrier_invitations i
      where i.company_id = v_company and i.status = 'pending'), '[]'::jsonb),
    'suggestions', coalesce((
      select jsonb_agg(jsonb_build_object(
        'mission_id', s.mission_id, 'employee_id', s.employee_id,
        'employee_name', coalesce(a.company_name, a.full_name),
        'note', s.note, 'created_at', s.created_at,
        'from_city', m.from_city, 'to_city', m.to_city, 'mission_date', m.mission_date)
        order by s.created_at desc)
      from public.carrier_suggestions s
      join public.accounts a on a.id = s.employee_id
      join public.missions m on m.id = s.mission_id
      where s.company_id = v_company and s.status = 'pending'), '[]'::jsonb),
    'missions', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', m.id, 'public_ref', m.public_ref, 'status', m.status,
        'progress_status', m.progress_status,
        'from_city', m.from_city, 'to_city', m.to_city,
        'mission_date', m.mission_date, 'vehicle', m.vehicle,
        'carrier_pay', m.carrier_pay,
        'employee_id', m.carrier_employee_id)
        order by m.mission_date desc)
      from public.missions m
      where m.carrier_company_id = v_company), '[]'::jsonb),
    'comptabilite', (
      select jsonb_build_object(
        'missions_livrees', count(*) filter (where m.status::text = 'completed'),
        'verse_total_eur', coalesce(sum(m.carrier_pay) filter (where m.status::text = 'completed'), 0),
        'en_attente_eur', coalesce(sum(m.carrier_pay) filter (where m.status::text <> 'completed'), 0),
        'depuis', min(m.created_at))
      from public.missions m where m.carrier_company_id = v_company));
end;
$f$;

-- 11. Droits ------------------------------------------------------------------
do $droits$
declare v_f text;
begin
  foreach v_f in array array[
    'public.secoto_carrier_create(text, text)',
    'public.secoto_carrier_invite(text)',
    'public.secoto_carrier_accept_invite(text)',
    'public.secoto_carrier_set_role(uuid, text)',
    'public.secoto_carrier_remove_member(uuid)',
    'public.secoto_carrier_suggest(uuid, text)',
    'public.secoto_carrier_assign_employee(uuid, uuid)',
    'public.secoto_carrier_overview()'
  ] loop
    execute format('revoke all on function %s from public, anon', v_f);
    execute format('grant execute on function %s to authenticated', v_f);
  end loop;
end
$droits$;

-- 12. La vue transporteur : l'employe voit sa mission, jamais les montants ----
-- create or replace view n'accepte ni de renommer, ni de reordonner, ni de
-- retirer une colonne : on ne peut qu'en ajouter a la fin. Si la vue deployee
-- n'est pas celle attendue, mieux vaut un message clair qu'une erreur Postgres
-- au milieu de la migration.
do $verif_vue$
declare
  v_deployee text;
  v_attendue text :=
    'id,public_ref,type,status,progress_status,from_city,to_city,pickup_address,'
    'delivery_address,mission_date,vehicle,plate,distance_km,carrier_cost,carrier_pay,'
    'client_name,client_contact,client_phone,payment_method,notes,'
    'assigned_transporter_id,assigned_transporter_name,created_at,vehicle_category,'
    'payment_status,cancelled_at,cancellation_reason,capacity_units,window_start,'
    'window_end,carrier_company_id,carrier_employee_id,groupage_order_id,groupage_rank';
begin
  select string_agg(column_name, ',' order by ordinal_position) into v_deployee
  from information_schema.columns
  where table_schema = 'public' and table_name = 'secoto_missions_transporter_v2';

  if v_deployee is null then
    raise exception 'La vue secoto_missions_transporter_v2 est absente : appliquez d''abord la migration 009.';
  end if;

  -- La vue deployee doit etre le debut exact de la vue attendue : on n'ajoute
  -- que des colonnes, jamais on n'en deplace.
  if position(v_deployee in v_attendue) <> 1 then
    raise exception 'La vue transporteur deployee ne correspond pas a celle attendue. Deployee : %', v_deployee;
  end if;
end
$verif_vue$;

create or replace view public.secoto_missions_transporter_v2
with (security_barrier = true, security_invoker = false)
as
select
  m.id, m.public_ref, m.type, m.status, m.progress_status,
  m.from_city, m.to_city, m.pickup_address, m.delivery_address,
  m.mission_date, m.vehicle, m.plate, m.distance_km,
  -- Le beneficiaire et les gerants voient la remuneration. L'employe designe,
  -- jamais : il execute, il n'encaisse pas.
  case when m.assigned_transporter_id = auth.uid()
         or secoto_private.is_carrier_owner(m.carrier_company_id, auth.uid())
       then m.carrier_cost end as carrier_cost,
  case when m.assigned_transporter_id = auth.uid()
         or secoto_private.is_carrier_owner(m.carrier_company_id, auth.uid())
       then m.carrier_pay end as carrier_pay,
  m.client_name, m.client_contact, m.client_phone,
  m.payment_method, m.notes,
  m.assigned_transporter_id, m.assigned_transporter_name, m.created_at,
  m.vehicle_category,
  m.payment_status,
  m.cancelled_at, m.cancellation_reason,
  m.capacity_units, m.window_start, m.window_end,
  m.carrier_company_id, m.carrier_employee_id,
  m.groupage_order_id, m.groupage_rank
from public.missions m
where m.assigned_transporter_id = auth.uid()
   or m.carrier_employee_id = auth.uid()
   or secoto_private.is_carrier_owner(m.carrier_company_id, auth.uid());

revoke all on table public.secoto_missions_transporter_v2 from public, anon;
grant select on table public.secoto_missions_transporter_v2 to authenticated;

-- 13. Controles bloquants -----------------------------------------------------
do $controles$
declare
  v_src text;
begin
  if to_regclass('public.carrier_invitations') is null
     or to_regclass('public.carrier_suggestions') is null then
    raise exception 'Les tables de l''espace entreprise n''ont pas ete creees';
  end if;

  if not exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'missions'
      and column_name = 'carrier_employee_id')
  then
    raise exception 'La colonne missions.carrier_employee_id n''a pas ete creee';
  end if;

  if not exists (
    select 1 from pg_trigger
    where tgname = 'trg_secoto_carrier_payee'
      and tgrelid = 'public.missions'::regclass)
  then
    raise exception 'Le declencheur qui protege les versements n''est pas pose';
  end if;

  select pg_get_functiondef(p.oid) into v_src
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'secoto_private' and p.proname = 'trg_carrier_payee';
  if position('Seul un gerant peut accepter' in v_src) = 0
     or position('new.assigned_transporter_id := v_payout' in v_src) = 0 then
    raise exception 'Le declencheur ne porte pas les deux regles de versement';
  end if;

  if not exists (
    select 1 from pg_trigger
    where tgname = 'trg_secoto_carrier_payee_order'
      and tgrelid = 'public.transport_orders'::regclass)
  then
    raise exception 'Le declencheur qui protege l''indemnite d''annulation n''est pas pose';
  end if;

  select pg_get_functiondef(p.oid) into v_src
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'secoto_private' and p.proname = 'is_business_member';
  if position('b.kind = ''client''' in v_src) = 0 then
    raise exception 'Les societes clientes et les entreprises de transport ne sont pas cloisonnees';
  end if;

  if exists (
    select 1 from public.transport_quotes q
    join public.business_accounts b on b.id = q.business_id
    where b.kind <> 'client')
  then
    raise exception 'Des devis sont rattaches a une entreprise qui n''est pas une societe cliente';
  end if;

  if has_table_privilege('anon', 'public.secoto_missions_transporter_v2', 'SELECT') then
    raise exception 'La vue transporteur est lisible par anon';
  end if;

  raise notice 'OK : espace entreprise en place. Versements a l''entreprise uniquement, employe sans montant.';
end
$controles$;
