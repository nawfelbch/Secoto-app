-- ============================================================================
-- SECOTO — 063 : CREER SON ENTREPRISE SANS ATTENDRE LA VERIFICATION
-- ----------------------------------------------------------------------------
-- La migration 060 reservait la creation d'une entreprise aux transporteurs
-- deja verifies par SECOTO. Une societe qui s'inscrit se heurtait donc a un
-- mur : elle ne pouvait rien declarer tant que SECOTO ne l'avait pas validee,
-- et n'avait aucun moyen de savoir que cet espace existait.
--
-- Cette exigence n'apportait aucune securite : creer une entreprise ne donne
-- droit a rien. Accepter une mission, elle, reste reservee aux transporteurs
-- verifies — c'est la que le controle a lieu, et il ne bouge pas. Une entreprise
-- creee par un compte non verifie ne peut donc rien faire de plus qu'avant.
--
-- Ce qui change : le compte doit etre un transporteur. Rien d'autre.
-- ============================================================================

create or replace function public.secoto_carrier_create(p_name text, p_siren text default null)
returns jsonb language plpgsql volatile security definer set search_path = ''
as $f$
declare
  v_user uuid := secoto_private.assert_authenticated();
  v_id   uuid;
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

revoke all on function public.secoto_carrier_create(text, text) from public, anon;
grant execute on function public.secoto_carrier_create(text, text) to authenticated;

-- Controle bloquant --------------------------------------------------------
do $controle$
declare v_src text;
begin
  select pg_get_functiondef(p.oid) into v_src
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname = 'secoto_carrier_create';

  if position('is_verified_transporter' in v_src) > 0 then
    raise exception 'La creation d''entreprise exige encore un compte verifie';
  end if;
  if position('Reserve aux comptes transporteurs.' in v_src) = 0 then
    raise exception 'La creation d''entreprise n''est plus reservee aux transporteurs';
  end if;

  -- L'acceptation d'une mission, elle, doit rester verrouillee.
  select pg_get_functiondef(p.oid) into v_src
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'secoto_private' and p.proname = 'trg_carrier_payee';
  if position('Seul un gerant peut accepter' in v_src) = 0 then
    raise exception 'Le verrou sur l''acceptation des missions a disparu';
  end if;

  raise notice 'OK : une entreprise se cree des l''inscription, la verification reste exigee pour accepter une mission.';
end
$controle$;
