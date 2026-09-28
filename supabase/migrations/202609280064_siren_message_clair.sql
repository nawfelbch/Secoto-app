-- ============================================================================
-- SECOTO — 064 : DIRE POURQUOI UN SIREN EST REFUSE
-- ----------------------------------------------------------------------------
-- Un SIREN mal saisi faisait echouer la contrainte de la table. L'application
-- ne recevait qu'un code Postgres (23514) et affichait « Une erreur est
-- survenue » : l'utilisateur n'avait aucun moyen de comprendre, ni de corriger.
--
-- Le numero est desormais verifie AVANT l'insertion, avec un message qui dit
-- quoi faire. Et le SIRET est accepte : c'est le numero que les entreprises ont
-- sous la main, et le SIREN en est simplement les neuf premiers chiffres —
-- autant le prendre plutot que de faire compter l'utilisateur.
-- ============================================================================

create or replace function public.secoto_carrier_create(p_name text, p_siren text default null)
returns jsonb language plpgsql volatile security definer set search_path = ''
as $f$
declare
  v_user   uuid := secoto_private.assert_authenticated();
  v_id     uuid;
  v_chiffres text;
  v_siren  text;
begin
  -- Verification exigee a l'acceptation d'une mission, pas ici.
  if not exists (
    select 1 from public.accounts a
    where a.id = v_user
      and a.role::text in ('transporter', 'admin')
      and a.deleted_at is null)
  then
    raise exception 'Reserve aux comptes transporteurs.' using errcode = '42501';
  end if;

  if length(btrim(coalesce(p_name, ''))) not between 2 and 160 then
    raise exception 'Indiquez le nom de l''entreprise.';
  end if;

  -- SIREN (9 chiffres) ou SIRET (14, dont les 9 premiers sont le SIREN).
  v_chiffres := regexp_replace(coalesce(p_siren, ''), '[^0-9]', '', 'g');
  if v_chiffres = '' then
    v_siren := null;
  elsif length(v_chiffres) = 9 then
    v_siren := v_chiffres;
  elsif length(v_chiffres) = 14 then
    v_siren := left(v_chiffres, 9);
  else
    raise exception 'Le SIREN comporte 9 chiffres, le SIRET 14. Vous en avez saisi %.', length(v_chiffres);
  end if;

  v_id := secoto_private.carrier_of(v_user);
  if v_id is not null then
    raise exception 'Vous appartenez deja a une entreprise de transport.';
  end if;

  insert into public.business_accounts(name, siren, created_by, kind, payout_account_id)
  values (btrim(p_name), v_siren, v_user, 'transporteur', v_user)
  returning id into v_id;

  insert into public.business_members(business_id, account_id, role)
  values (v_id, v_user, 'owner');

  perform secoto_private.audit('carrier_company_created', 'business_account', v_id::text,
    jsonb_build_object('name', btrim(p_name)));

  return jsonb_build_object('id', v_id, 'name', btrim(p_name), 'siren', v_siren);
end;
$f$;

revoke all on function public.secoto_carrier_create(text, text) from public, anon;
grant execute on function public.secoto_carrier_create(text, text) to authenticated;

-- Controle bloquant --------------------------------------------------------
do $controle$
declare v_src text;
begin
  select pg_get_functiondef(p.oid) into v_src
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname = 'secoto_carrier_create';

  if position('Le SIREN comporte 9 chiffres' in v_src) = 0 then
    raise exception 'Le numero d''entreprise est encore refuse sans explication';
  end if;
  if position('length(v_chiffres) = 14' in v_src) = 0 then
    raise exception 'Le SIRET n''est pas accepte';
  end if;
  if position('is_verified_transporter' in v_src) > 0 then
    raise exception 'La creation d''entreprise exige de nouveau un compte verifie';
  end if;

  raise notice 'OK : SIREN ou SIRET acceptes, et un numero invalide dit pourquoi.';
end
$controle$;
