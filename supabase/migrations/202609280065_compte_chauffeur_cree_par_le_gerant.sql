-- ============================================================================
-- SECOTO — 065 : UN CHAUFFEUR PEUT NE RIEN AVOIR A CREER
-- ----------------------------------------------------------------------------
-- Jusqu'ici, rejoindre une entreprise supposait que le chauffeur cree lui-meme
-- son compte, puis clique un lien. Pour un convoyeur qui n'a jamais utilise
-- l'application, cela fait deux obstacles avant la premiere mission.
--
-- Le gerant peut desormais creer le compte a sa place, avec un mot de passe
-- provisoire qu'il lui transmet. Ce mot de passe ne vaut qu'une fois : tant
-- qu'il n'est pas remplace, le chauffeur ne voit qu'un seul ecran.
--
-- La creation elle-meme se fait cote serveur (fonction Netlify
-- « carrier-employee »), seule autorisee a creer un compte d'authentification.
-- Cette migration pose ce dont la base a besoin : le drapeau, et le moyen de
-- le lever.
-- ============================================================================

alter table public.accounts
  add column if not exists must_change_password boolean not null default false;

comment on column public.accounts.must_change_password is
  'Compte cree par un tiers avec un mot de passe provisoire. Tant que ce '
  'drapeau est leve, l''application n''affiche que le changement de mot de '
  'passe : le mot de passe transmis par un gerant ne doit jamais rester actif.';

-- Le chauffeur leve le drapeau lui-meme, apres avoir change son mot de passe.
-- Rien d'autre ne peut le lever : ni un gerant, ni un autre compte.
create or replace function public.secoto_password_changed()
returns jsonb language plpgsql volatile security definer set search_path = ''
as $f$
declare
  v_user uuid := secoto_private.assert_authenticated();
begin
  update public.accounts
     set must_change_password = false
   where id = v_user;

  return jsonb_build_object('must_change_password', false);
end;
$f$;

revoke all on function public.secoto_password_changed() from public, anon;
grant execute on function public.secoto_password_changed() to authenticated;

-- Rattacher le compte cree a l'entreprise, en une seule operation verifiee.
-- Appelee par la fonction serveur, avec l'identite du gerant qui a demande la
-- creation : les regles restent en base, pas dans le serveur.
create or replace function public.secoto_carrier_attach_employee(
  p_owner_id uuid, p_account_id uuid)
returns jsonb language plpgsql volatile security definer set search_path = ''
as $f$
declare
  v_company uuid := secoto_private.carrier_of(p_owner_id);
begin
  if not secoto_private.is_carrier_owner(v_company, p_owner_id) then
    raise exception 'Reserve aux gerants de l''entreprise.' using errcode = '42501';
  end if;
  if secoto_private.carrier_of(p_account_id) is not null then
    raise exception 'Ce compte appartient deja a une entreprise de transport.';
  end if;

  insert into public.business_members(business_id, account_id, role)
  values (v_company, p_account_id, 'member')
  on conflict (business_id, account_id) do nothing;

  update public.accounts
     set must_change_password = true
   where id = p_account_id;

  perform secoto_private.audit('carrier_employee_created', 'business_account', v_company::text,
    jsonb_build_object('account_id', p_account_id, 'by', p_owner_id));

  return jsonb_build_object('company_id', v_company, 'account_id', p_account_id);
end;
$f$;

-- Reservee au serveur : un client authentifie ne doit pas pouvoir rattacher un
-- compte en se faisant passer pour un gerant.
revoke all on function public.secoto_carrier_attach_employee(uuid, uuid)
  from public, anon, authenticated;

-- Controles bloquants --------------------------------------------------------
do $controles$
declare v_src text;
begin
  if not exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'accounts'
      and column_name = 'must_change_password')
  then
    raise exception 'La colonne accounts.must_change_password n''a pas ete creee';
  end if;

  -- Personne ne doit pouvoir lever le drapeau d'un autre compte.
  select pg_get_functiondef(p.oid) into v_src
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname = 'secoto_password_changed';
  if position('where id = v_user' in v_src) = 0 then
    raise exception 'secoto_password_changed pourrait lever le drapeau d''un autre compte';
  end if;

  -- Le rattachement reste hors de portee d'un client authentifie.
  if has_function_privilege('authenticated',
      'public.secoto_carrier_attach_employee(uuid, uuid)', 'EXECUTE') then
    raise exception 'secoto_carrier_attach_employee est appelable depuis l''application';
  end if;

  raise notice 'OK : un gerant peut faire creer le compte d''un chauffeur, avec mot de passe a changer.';
end
$controles$;
