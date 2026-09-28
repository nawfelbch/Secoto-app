-- ============================================================================
-- SECOTO — 062 : QUITTER OU DISSOUDRE UNE ENTREPRISE DE TRANSPORT
-- ----------------------------------------------------------------------------
-- La migration 060 permettait de creer une entreprise et d'y entrer, jamais
-- d'en sortir. Un compte rattache l'etait definitivement, et un gerant ne
-- pouvait pas se retirer lui-meme : impossible de corriger une erreur, meme
-- un simple essai.
--
-- UNE ENTREPRISE N'EST JAMAIS SUPPRIMEE, ELLE EST ARCHIVEE
--   Ses missions passees gardent leur rattachement : la comptabilite et la
--   tracabilite des versements restent intactes. Une entreprise archivee
--   n'existe plus pour personne — ni pour carrier_of, ni pour les droits de
--   gerant, ni pour le declencheur qui protege les versements — de sorte que
--   ses anciens membres redeviennent des transporteurs independants.
--
-- CE QUI RESTE INTERDIT
--   - partir en laissant des missions en cours, les siennes ou celles de
--     l'entreprise ;
--   - laisser une entreprise sans gerant ;
--   - retirer le compte qui recoit les versements sans en designer un autre.
-- ============================================================================

alter table public.business_accounts
  add column if not exists archived_at timestamptz;

comment on column public.business_accounts.archived_at is
  'Entreprise dissoute. Les missions passees gardent leur rattachement pour la '
  'comptabilite, mais l''entreprise n''a plus ni membres ni effet sur les '
  'versements.';

-- 1. Une entreprise archivee n'existe plus pour personne ----------------------
create or replace function secoto_private.carrier_of(p_account uuid default auth.uid())
returns uuid language sql stable security definer set search_path = ''
as $f$
  select bm.business_id
  from public.business_members bm
  join public.business_accounts b on b.id = bm.business_id
  where bm.account_id = p_account
    and b.kind = 'transporteur'
    and b.archived_at is null
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
      and bm.role = 'owner'
      and b.kind = 'transporteur'
      and b.archived_at is null);
$f$;

-- Le declencheur qui protege les versements doit ignorer, lui aussi, une
-- entreprise dissoute : sinon un ancien membre resterait paye a travers elle.
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
  where bm.account_id = new.assigned_transporter_id
    and b.kind = 'transporteur'
    and b.archived_at is null
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

  if v_payout is not null and v_payout <> new.assigned_transporter_id then
    new.assigned_transporter_id := v_payout;
    select coalesce(a.company_name, a.full_name) into new.assigned_transporter_name
    from public.accounts a where a.id = v_payout;
  end if;

  return new;
end;
$f$;

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
  where bm.account_id = new.assigned_partner_id
    and b.kind = 'transporteur'
    and b.archived_at is null
  order by bm.created_at
  limit 1;

  if v_payout is not null and v_payout <> new.assigned_partner_id then
    new.assigned_partner_id := v_payout;
  end if;

  return new;
end;
$f$;

-- 2. Passer la main sur les versements ----------------------------------------
-- Sans cela, le compte qui recoit l'argent ne pourrait jamais partir.
create or replace function public.secoto_carrier_set_payout_account(p_account_id uuid)
returns jsonb language plpgsql volatile security definer set search_path = ''
as $f$
declare
  v_user    uuid := secoto_private.assert_authenticated();
  v_company uuid := secoto_private.carrier_of(v_user);
begin
  if not secoto_private.is_carrier_owner(v_company, v_user) then
    raise exception 'Reserve aux gerants de l''entreprise.' using errcode = '42501';
  end if;
  if not secoto_private.is_carrier_owner(v_company, p_account_id) then
    raise exception 'Les versements ne peuvent aller qu''a un gerant de l''entreprise.';
  end if;

  update public.business_accounts
     set payout_account_id = p_account_id
   where id = v_company;

  perform secoto_private.audit('carrier_payout_account_changed', 'business_account', v_company::text,
    jsonb_build_object('account_id', p_account_id));

  return jsonb_build_object('payout_account_id', p_account_id);
end;
$f$;

-- 3. Quitter l'entreprise ------------------------------------------------------
create or replace function public.secoto_carrier_leave()
returns jsonb language plpgsql volatile security definer set search_path = ''
as $f$
declare
  v_user    uuid := secoto_private.assert_authenticated();
  v_company uuid := secoto_private.carrier_of(v_user);
  v_role    text;
  v_payout  uuid;
  v_gerants integer;
  v_encours integer;
begin
  if v_company is null then
    raise exception 'Vous n''appartenez a aucune entreprise de transport.';
  end if;

  select bm.role into v_role from public.business_members bm
   where bm.business_id = v_company and bm.account_id = v_user;

  select b.payout_account_id into v_payout
  from public.business_accounts b where b.id = v_company;

  if v_payout = v_user then
    raise exception 'Vous recevez les versements de l''entreprise : designez d''abord un autre gerant pour les recevoir.';
  end if;

  if v_role = 'owner' then
    select count(*) into v_gerants from public.business_members bm
     where bm.business_id = v_company and bm.role = 'owner';
    if v_gerants <= 1 then
      raise exception 'Vous etes le seul gerant : nommez un autre gerant, ou dissolvez l''entreprise.';
    end if;
  end if;

  select count(*) into v_encours from public.missions m
   where (m.carrier_employee_id = v_user or m.assigned_transporter_id = v_user)
     and m.status::text not in ('completed', 'cancelled');
  if v_encours > 0 then
    raise exception 'Vous avez % mission(s) en cours : terminez-les ou faites-les reaffecter avant de partir.', v_encours;
  end if;

  delete from public.business_members
   where business_id = v_company and account_id = v_user;

  perform secoto_private.audit('carrier_member_left', 'business_account', v_company::text,
    jsonb_build_object('account_id', v_user, 'role', v_role));

  return jsonb_build_object('left', true);
end;
$f$;

-- 4. Dissoudre l'entreprise, et fermer ce qui reste ouvert -------------------
-- Une invitation emise avant la dissolution ne doit plus etre acceptable :
-- sinon le convoyeur rejoindrait une entreprise qui n'existe plus.
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

  if not exists (
    select 1 from public.business_accounts b
    where b.id = v_inv.company_id and b.kind = 'transporteur' and b.archived_at is null)
  then
    raise exception 'Cette entreprise n''existe plus.';
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

-- La dissolution revoque aussi les invitations restees en attente.
create or replace function public.secoto_carrier_dissolve()
returns jsonb language plpgsql volatile security definer set search_path = ''
as $f$
declare
  v_user    uuid := secoto_private.assert_authenticated();
  v_company uuid := secoto_private.carrier_of(v_user);
  v_encours integer;
  v_membres integer;
begin
  if not secoto_private.is_carrier_owner(v_company, v_user) then
    raise exception 'Reserve aux gerants de l''entreprise.' using errcode = '42501';
  end if;

  select count(*) into v_encours from public.missions m
   where m.carrier_company_id = v_company
     and m.status::text not in ('completed', 'cancelled');
  if v_encours > 0 then
    raise exception 'L''entreprise a % mission(s) en cours : elles doivent etre terminees ou annulees avant la dissolution.', v_encours;
  end if;

  select count(*) into v_membres from public.business_members bm
   where bm.business_id = v_company;

  update public.business_accounts
     set archived_at = now(), payout_account_id = null
   where id = v_company;

  delete from public.business_members where business_id = v_company;

  update public.carrier_invitations
     set status = 'revoked'
   where company_id = v_company and status = 'pending';

  perform secoto_private.audit('carrier_company_dissolved', 'business_account', v_company::text,
    jsonb_build_object('membres', v_membres));

  return jsonb_build_object('dissolved', true, 'membres_liberes', v_membres);
end;
$f$;

-- 5. Droits --------------------------------------------------------------------
do $droits$
declare v_f text;
begin
  foreach v_f in array array[
    'public.secoto_carrier_set_payout_account(uuid)',
    'public.secoto_carrier_leave()',
    'public.secoto_carrier_dissolve()',
    'public.secoto_carrier_accept_invite(text)'
  ] loop
    execute format('revoke all on function %s from public, anon', v_f);
    execute format('grant execute on function %s to authenticated', v_f);
  end loop;
end
$droits$;

-- 6. Controles bloquants -------------------------------------------------------
do $controles$
declare
  v_src      text;
  v_fonction text;
begin
  if not exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'business_accounts'
      and column_name = 'archived_at')
  then
    raise exception 'La colonne business_accounts.archived_at n''a pas ete creee';
  end if;

  -- Une entreprise dissoute ne doit plus exister pour aucune de ces quatre
  -- fonctions, sinon ses anciens membres resteraient prisonniers.
  foreach v_fonction in array array[
    'carrier_of', 'is_carrier_owner', 'trg_carrier_payee', 'trg_carrier_payee_order'
  ] loop
    select pg_get_functiondef(p.oid) into v_src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'secoto_private' and p.proname = v_fonction;

    if v_src is null then
      raise exception 'secoto_private.% est introuvable', v_fonction;
    end if;
    if position('archived_at is null' in v_src) = 0 then
      raise exception 'secoto_private.% ignore encore l''archivage des entreprises', v_fonction;
    end if;
  end loop;

  select pg_get_functiondef(p.oid) into v_src
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname = 'secoto_carrier_accept_invite';
  if position('Cette entreprise n''existe plus.' in v_src) = 0 then
    raise exception 'Une invitation d''entreprise dissoute reste acceptable';
  end if;

  if to_regprocedure('public.secoto_carrier_leave()') is null
     or to_regprocedure('public.secoto_carrier_dissolve()') is null
     or to_regprocedure('public.secoto_carrier_set_payout_account(uuid)') is null
  then
    raise exception 'Les fonctions de sortie d''entreprise n''ont pas ete creees';
  end if;

  raise notice 'OK : on peut desormais quitter ou dissoudre une entreprise, sans perdre la comptabilite.';
end
$controles$;
