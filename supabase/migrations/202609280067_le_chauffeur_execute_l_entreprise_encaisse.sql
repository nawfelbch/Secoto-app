-- ============================================================================
-- SECOTO — 067 : LE CHAUFFEUR EXECUTE, L'ENTREPRISE ENCAISSE
-- ----------------------------------------------------------------------------
-- CE QUI NE MARCHAIT PAS
--   La migration 060 faisait du GERANT le titulaire de la mission, et notait le
--   chauffeur a cote. Or toute l'application — vues, RLS, etat des lieux,
--   photos, suivi GPS, stockage — reconnait un seul titulaire :
--   assigned_transporter_id. Le chauffeur n'etait donc personne : il recevait
--   la notification, ne voyait pas la mission, et aurait ete refuse a chaque
--   geste de terrain. Le gerant, lui, voyait un etat des lieux a faire alors
--   qu'il ne conduit pas.
--
-- LA CORRECTION, A LA RACINE
--   Le titulaire de la mission redevient CELUI QUI LA FAIT — chauffeur ou
--   gerant. Tout le terrain fonctionne alors sans qu'une seule ligne y soit
--   touchee. Ce n'est plus l'affectation qui porte la regle des versements,
--   c'est le VERSEMENT lui-meme : au moment de payer, le beneficiaire est le
--   compte de versement de l'entreprise, jamais le chauffeur.
--
--   La regle « seul un gerant accepte » est donc deplacee, pas supprimee : un
--   chauffeur ne peut toujours pas prendre une mission de lui-meme. Il n'y est
--   affecte que par la designation d'un gerant, qui pose un drapeau de session
--   que lui seul peut poser.
-- ============================================================================

-- 1. Le drapeau de designation -----------------------------------------------
create or replace function secoto_private.designation_en_cours()
returns boolean language sql stable set search_path = ''
as $f$
  select coalesce(current_setting('secoto.designation', true), '') = 'on';
$f$;

-- 2. Qui doit etre paye pour cette mission -----------------------------------
-- Le compte de versement de l'entreprise s'il y en a une, sinon le titulaire.
create or replace function secoto_private.beneficiaire_mission(p_mission_id uuid)
returns uuid language sql stable security definer set search_path = ''
as $f$
  select coalesce(
    (select b.payout_account_id
       from public.missions m
       join public.business_accounts b on b.id = m.carrier_company_id
      where m.id = p_mission_id and b.archived_at is null),
    (select m.assigned_transporter_id from public.missions m where m.id = p_mission_id));
$f$;

-- 3. L'affectation ne redirige plus : elle rattache et protege ---------------
create or replace function secoto_private.trg_carrier_payee()
returns trigger language plpgsql security definer set search_path = ''
as $f$
declare
  v_company uuid;
  v_role    text;
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

  -- Un chauffeur ne prend pas une mission de lui-meme. Il n'y arrive que par la
  -- designation d'un gerant, seule a poser ce drapeau.
  if v_role <> 'owner' and not secoto_private.designation_en_cours() then
    raise exception 'Seul un gerant peut accepter une mission pour son entreprise.'
      using errcode = '42501';
  end if;

  -- La mission appartient a l'entreprise : c'est elle qui sera payee.
  new.carrier_company_id := v_company;

  return new;
end;
$f$;

-- 4. Designer un chauffeur l'affecte reellement a la mission ------------------
create or replace function public.secoto_carrier_assign_employee(p_mission_id uuid, p_account_id uuid)
returns jsonb language plpgsql volatile security definer set search_path = ''
as $f$
declare
  v_user    uuid := secoto_private.assert_authenticated();
  v_company uuid := secoto_private.carrier_of(v_user);
  v_mission public.missions%rowtype;
  v_cible   uuid;
  v_nom     text;
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

  -- Retirer la designation rend la mission au gerant qui l'a acceptee.
  v_cible := coalesce(p_account_id, v_user);
  select coalesce(a.company_name, a.full_name) into v_nom
  from public.accounts a where a.id = v_cible;

  -- Le drapeau autorise, le temps de cette transaction, l'affectation d'un
  -- chauffeur salarie — ce que le declencheur refuse en toute autre
  -- circonstance.
  perform set_config('secoto.designation', 'on', true);

  update public.missions
     set carrier_employee_id = p_account_id,
         assigned_transporter_id = v_cible,
         assigned_transporter_name = v_nom
   where id = p_mission_id;

  update public.carrier_suggestions
     set status = case when employee_id = p_account_id then 'retenue' else 'ecartee' end
   where mission_id = p_mission_id and status = 'pending';

  if p_account_id is not null then
    perform secoto_private.notify_event(
      p_account_id, 'course_assigned', 'Vous etes designe sur une mission',
      format('%s vers %s. Retrouvez-la dans « Mes missions ».',
        v_mission.from_city, v_mission.to_city),
      p_mission_id, 'courses', 'carrier-assign:' || p_mission_id::text, p_mission_id);
  end if;

  return jsonb_build_object('mission_id', p_mission_id, 'employee_id', p_account_id);
end;
$f$;

revoke all on function public.secoto_carrier_assign_employee(uuid, uuid) from public, anon;
grant execute on function public.secoto_carrier_assign_employee(uuid, uuid) to authenticated;

-- 5. Le versement va a l'entreprise, quel que soit le titulaire ---------------
do $patch_versement$
declare
  v_src text;
  v_new text;
begin
  select pg_get_functiondef(p.oid) into v_src
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'secoto_private' and p.proname = 'trg_manual_mission_payout';

  if v_src is null then
    raise exception 'trg_manual_mission_payout absente : appliquez d''abord la migration 036.';
  end if;

  if position('beneficiaire_mission' in v_src) > 0 then
    raise notice 'Le versement vise deja l''entreprise : rien a faire';
    return;
  end if;

  if position('values (new.id, null, new.assigned_transporter_id, round(new.carrier_pay * 100)::int,' in v_src) = 0 then
    raise exception 'Ancre du versement introuvable dans trg_manual_mission_payout.';
  end if;

  v_new := replace(v_src,
    'values (new.id, null, new.assigned_transporter_id, round(new.carrier_pay * 100)::int,',
    'values (new.id, null, coalesce(secoto_private.beneficiaire_mission(new.id), new.assigned_transporter_id), round(new.carrier_pay * 100)::int,');

  -- Le gerant est prevenu du paiement, pas le chauffeur : il ne voit aucun montant.
  v_new := replace(v_new,
    'perform secoto_private.notify_event(new.assigned_transporter_id, ''payment'', ''Paiement programmé'',',
    'perform secoto_private.notify_event(coalesce(secoto_private.beneficiaire_mission(new.id), new.assigned_transporter_id), ''payment'', ''Paiement programmé'',');

  execute v_new;
  raise notice 'Le versement d''une mission d''entreprise vise desormais l''entreprise';
end
$patch_versement$;

-- 6. Le chauffeur reste sans montant, le gerant les voit tous ----------------
do $vue$
declare
  v_type_cost text;
  v_type_pay  text;
begin
  select format_type(a.atttypid, a.atttypmod) into v_type_cost
  from pg_attribute a
  where a.attrelid = 'public.missions'::regclass and a.attname = 'carrier_cost';
  select format_type(a.atttypid, a.atttypmod) into v_type_pay
  from pg_attribute a
  where a.attrelid = 'public.missions'::regclass and a.attname = 'carrier_pay';

  -- Un transporteur independant voit sa remuneration. Un salarie ne voit rien :
  -- il execute, il n'encaisse pas. Un gerant voit celle de son entreprise.
  execute format($vue_sql$
    create or replace view public.secoto_missions_transporter_v2
    with (security_barrier = true, security_invoker = false)
    as
    select
      m.id, m.public_ref, m.type, m.status, m.progress_status,
      m.from_city, m.to_city, m.pickup_address, m.delivery_address,
      m.mission_date, m.vehicle, m.plate, m.distance_km,
      (case when secoto_private.is_carrier_owner(m.carrier_company_id, auth.uid())
              or (m.assigned_transporter_id = auth.uid()
                  and secoto_private.carrier_of(auth.uid()) is null)
            then m.carrier_cost end)::%s as carrier_cost,
      (case when secoto_private.is_carrier_owner(m.carrier_company_id, auth.uid())
              or (m.assigned_transporter_id = auth.uid()
                  and secoto_private.carrier_of(auth.uid()) is null)
            then m.carrier_pay end)::%s as carrier_pay,
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
       or secoto_private.is_carrier_owner(m.carrier_company_id, auth.uid())
  $vue_sql$, v_type_cost, v_type_pay);
end
$vue$;

revoke all on table public.secoto_missions_transporter_v2 from public, anon;
grant select on table public.secoto_missions_transporter_v2 to authenticated;

-- 7. Le tableau du chauffeur suit ses missions, sans montant ------------------
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
        where (m.assigned_transporter_id = v_user or m.carrier_employee_id = v_user)
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

revoke all on function public.secoto_carrier_overview() from public, anon;
grant execute on function public.secoto_carrier_overview() to authenticated;

-- 7 bis. La direction voit qui appartient a quelle entreprise ----------------
-- Sans cela, un chauffeur salarie apparait dans « Transporteurs » comme un
-- independant, et rien ne dit a qui SECOTO verse reellement.
create or replace function public.secoto_admin_carrier_members()
returns jsonb language plpgsql stable security definer set search_path = ''
as $f$
begin
  perform secoto_private.assert_admin();
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'account_id', bm.account_id,
      'company_id', b.id,
      'company_name', b.name,
      'role', bm.role,
      'recoit_les_versements', (b.payout_account_id = bm.account_id)))
    from public.business_members bm
    join public.business_accounts b on b.id = bm.business_id
    where b.kind = 'transporteur' and b.archived_at is null), '[]'::jsonb);
end;
$f$;

revoke all on function public.secoto_admin_carrier_members() from public, anon;
grant execute on function public.secoto_admin_carrier_members() to authenticated;

-- 8. Controles bloquants -------------------------------------------------------
do $controles$
declare v_src text;
begin
  select pg_get_functiondef(p.oid) into v_src
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'secoto_private' and p.proname = 'trg_carrier_payee';
  if position('new.assigned_transporter_id := v_payout' in v_src) > 0 then
    raise exception 'L''affectation redirige encore le titulaire de la mission';
  end if;
  if position('Seul un gerant peut accepter' in v_src) = 0 then
    raise exception 'Un chauffeur pourrait accepter une mission de lui-meme';
  end if;
  if position('designation_en_cours()' in v_src) = 0 then
    raise exception 'La designation par un gerant n''est pas reconnue';
  end if;

  select pg_get_functiondef(p.oid) into v_src
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'secoto_private' and p.proname = 'trg_manual_mission_payout';
  if position('beneficiaire_mission' in v_src) = 0 then
    raise exception 'Le versement d''une mission d''entreprise ne vise pas l''entreprise';
  end if;

  select pg_get_functiondef(p.oid) into v_src
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname = 'secoto_carrier_assign_employee';
  if position('set_config(''secoto.designation''' in v_src) = 0
     or position('assigned_transporter_id = v_cible' in v_src) = 0 then
    raise exception 'La designation n''affecte pas reellement le chauffeur a la mission';
  end if;

  if has_table_privilege('anon', 'public.secoto_missions_transporter_v2', 'SELECT') then
    raise exception 'La vue transporteur est lisible par anon';
  end if;

  if to_regprocedure('public.secoto_admin_carrier_members()') is null then
    raise exception 'La direction ne peut pas voir les rattachements d''entreprise';
  end if;

  raise notice 'OK : le chauffeur execute la mission, l''entreprise en encaisse le versement.';
end
$controles$;
