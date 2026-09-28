-- ============================================================================
-- SECOTO — 066 : ANNULER UNE INVITATION, RETIRER UN CHAUFFEUR
-- ----------------------------------------------------------------------------
-- Une invitation envoyee par erreur restait valable indefiniment, sans aucun
-- moyen de l'annuler : n'importe qui recevant le lien pouvait entrer dans
-- l'entreprise. C'est le trou le plus direct de l'espace entreprise.
--
-- Le retrait d'un chauffeur, lui, existait deja (migration 060) avec ses
-- garde-fous : on ne retire pas le compte qui recoit les versements, ni un
-- chauffeur ayant des missions en cours. Cette migration y ajoute de quoi
-- savoir si le compte retire peut etre supprime : un compte cree par
-- l'entreprise et jamais active n'est qu'une erreur de saisie, il n'appartient
-- a personne. Un compte que son titulaire a deja ouvert lui appartient, et
-- n'est jamais supprime.
-- ============================================================================

create or replace function public.secoto_carrier_revoke_invitation(p_invitation_id uuid)
returns jsonb language plpgsql volatile security definer set search_path = ''
as $f$
declare
  v_user    uuid := secoto_private.assert_authenticated();
  v_company uuid := secoto_private.carrier_of(v_user);
  v_email   text;
begin
  if not secoto_private.is_carrier_owner(v_company, v_user) then
    raise exception 'Reserve aux gerants de l''entreprise.' using errcode = '42501';
  end if;

  update public.carrier_invitations
     set status = 'revoked'
   where id = p_invitation_id
     and company_id = v_company
     and status = 'pending'
  returning email into v_email;

  if v_email is null then
    raise exception 'Invitation introuvable ou deja utilisee.';
  end if;

  perform secoto_private.audit('carrier_invitation_revoked', 'business_account', v_company::text,
    jsonb_build_object('email', v_email, 'by', v_user));

  return jsonb_build_object('revoked', true, 'email', v_email);
end;
$f$;

revoke all on function public.secoto_carrier_revoke_invitation(uuid) from public, anon;
grant execute on function public.secoto_carrier_revoke_invitation(uuid) to authenticated;

-- Le retrait renvoie desormais de quoi decider du sort du compte.
create or replace function public.secoto_carrier_remove_member(p_account_id uuid)
returns jsonb language plpgsql volatile security definer set search_path = ''
as $f$
declare
  v_user     uuid := secoto_private.assert_authenticated();
  v_company  uuid := secoto_private.carrier_of(v_user);
  v_payout   uuid;
  v_encours  integer;
  v_jamais_active boolean;
begin
  if not secoto_private.is_carrier_owner(v_company, v_user) then
    raise exception 'Reserve aux gerants de l''entreprise.' using errcode = '42501';
  end if;

  select b.payout_account_id into v_payout
  from public.business_accounts b where b.id = v_company;
  if p_account_id = v_payout then
    raise exception 'Designez d''abord un autre compte de versement.';
  end if;

  select count(*) into v_encours from public.missions m
   where m.carrier_employee_id = p_account_id
     and m.status::text not in ('completed', 'cancelled');
  if v_encours > 0 then
    raise exception 'Ce chauffeur a % mission(s) en cours : reaffectez-les d''abord.', v_encours;
  end if;

  -- Compte cree par l'entreprise et jamais ouvert par son titulaire : le mot de
  -- passe provisoire n'a jamais ete remplace. Ce n'est une erreur de saisie que
  -- dans ce cas, et c'est le seul ou le serveur pourra le supprimer.
  select coalesce(a.must_change_password, false) into v_jamais_active
  from public.accounts a where a.id = p_account_id;

  delete from public.business_members
   where business_id = v_company and account_id = p_account_id and role <> 'owner';
  if not found then
    raise exception 'Retrait impossible : compte absent, ou gerant a retrograder d''abord.';
  end if;

  perform secoto_private.audit('carrier_member_removed', 'business_account', v_company::text,
    jsonb_build_object('account_id', p_account_id, 'by', v_user));

  return jsonb_build_object(
    'account_id', p_account_id,
    'removed', true,
    'compte_supprimable', coalesce(v_jamais_active, false));
end;
$f$;

revoke all on function public.secoto_carrier_remove_member(uuid) from public, anon;
grant execute on function public.secoto_carrier_remove_member(uuid) to authenticated;

-- Controles bloquants --------------------------------------------------------
do $controles$
declare v_src text;
begin
  select pg_get_functiondef(p.oid) into v_src
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname = 'secoto_carrier_revoke_invitation';
  if v_src is null then
    raise exception 'L''annulation d''invitation n''a pas ete creee';
  end if;
  -- Une invitation ne s'annule que dans sa propre entreprise.
  if position('and company_id = v_company' in v_src) = 0 then
    raise exception 'Une invitation d''une autre entreprise pourrait etre annulee';
  end if;

  select pg_get_functiondef(p.oid) into v_src
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname = 'secoto_carrier_remove_member';
  if position('compte_supprimable' in v_src) = 0 then
    raise exception 'Le retrait ne dit pas si le compte peut etre supprime';
  end if;
  -- Les garde-fous du retrait restent en place.
  if position('Designez d''''abord un autre compte de versement.' in v_src) = 0
     or position('mission(s) en cours' in v_src) = 0 then
    raise exception 'Les garde-fous du retrait d''un chauffeur ont disparu';
  end if;

  raise notice 'OK : une invitation s''annule, un chauffeur se retire, et un compte jamais ouvert peut etre supprime.';
end
$controles$;
