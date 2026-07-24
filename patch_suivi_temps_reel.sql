-- ============================================================================
-- SECOTO — Patch « 1 appareil / plusieurs comptes » + alertes de suivi
-- ----------------------------------------------------------------------------
-- A coller dans Supabase > SQL Editor > Run. Idempotent.
--
-- 1. UN TELEPHONE, PLUSIEURS COMPTES
--    push_subscriptions identifiait un abonnement par son seul « endpoint »
--    (= l'appareil). En se connectant en transporteur PUIS en client sur le
--    meme telephone, le second abonnement ECRASAIT le premier : un seul des
--    deux comptes recevait les notifications. Desormais la cle est le couple
--    (compte, appareil) : les deux comptes recoivent leurs alertes.
--
-- 2. FIN DE COURSE
--    L'admin et le client sont maintenant prevenus des que le transporteur
--    valide une etape (prise en charge, incident, livraison), avec
--    notification systeme.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1) Abonnements : cle (compte, appareil)
-- ----------------------------------------------------------------------------
do $$
declare cn text;
begin
  -- Retire l'ancienne unicite portant sur le seul endpoint.
  for cn in
    select con.conname
    from pg_constraint con
    join pg_class rel on rel.oid = con.conrelid
    join pg_namespace ns on ns.oid = rel.relnamespace
    where ns.nspname = 'public' and rel.relname = 'push_subscriptions'
      and con.contype in ('u', 'p') and con.contype = 'u'
      and pg_get_constraintdef(con.oid) = 'UNIQUE (endpoint)'
  loop
    execute format('alter table public.push_subscriptions drop constraint %I', cn);
  end loop;
end $$;

drop index if exists public.push_subscriptions_endpoint_key;

-- Doublons eventuels (meme compte + meme appareil) : on ne garde que le plus recent.
delete from public.push_subscriptions p
using public.push_subscriptions q
where p.account_id = q.account_id
  and p.endpoint   = q.endpoint
  and p.created_at < q.created_at;

create unique index if not exists uq_push_account_endpoint
  on public.push_subscriptions (account_id, endpoint);

-- ----------------------------------------------------------------------------
-- 2) Alertes a chaque etape du suivi terrain
-- ----------------------------------------------------------------------------
create or replace function public.secoto_trg_tracking_notify()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  m       public.missions%rowtype;
  v_titre text;
  v_corps text;
  v_who   text;
begin
  select * into m from public.missions where id = new.mission_id;
  if m.id is null then return new; end if;

  select coalesce(a.full_name, 'Le transporteur') into v_who
  from public.accounts a where a.id = new.transporter_id;

  v_titre := case new.event_type::text
               when 'pickup_inspection'   then 'Vehicule pris en charge'
               when 'road_incident'       then 'Incident signale'
               when 'delivery_inspection' then 'Course terminee'
               else 'Mise a jour de la course'
             end;

  v_corps := v_who || ' — ' || coalesce(m.from_city, 'Depart')
             || ' vers ' || coalesce(m.to_city, 'Arrivee')
             || coalesce(' (' || m.public_ref || ')', '');

  -- Direction SECOTO
  perform public.secoto_notify_admins('tracking', v_titre, v_corps, new.mission_id);

  -- Client proprietaire de la course
  if m.client_account_id is not null then
    perform public.secoto_notify_one(
      m.client_account_id, 'tracking', v_titre,
      case new.event_type::text
        when 'delivery_inspection' then 'Votre vehicule est livre. Etat des lieux disponible dans l''application.'
        when 'pickup_inspection'   then 'Votre vehicule vient d''etre pris en charge.'
        when 'road_incident'       then 'Un incident a ete signale sur votre transport.'
        else v_corps
      end,
      new.mission_id
    );
  end if;

  return new;
end $$;

drop trigger if exists trg_secoto_tracking_notify on public.mission_tracking_events;
create trigger trg_secoto_tracking_notify
  after insert on public.mission_tracking_events
  for each row execute function public.secoto_trg_tracking_notify();

-- ----------------------------------------------------------------------------
-- 3) Diffusion temps reel des tables de suivi (rappel, idempotent)
-- ----------------------------------------------------------------------------
do $$
declare t text;
begin
  foreach t in array array['missions','mission_tracking_events','mission_tracking_photos','documents'] loop
    if to_regclass('public.'||t) is null then continue; end if;
    execute format('alter table public.%I replica identity full', t);
    begin
      execute format('alter publication supabase_realtime add table public.%I', t);
    exception when duplicate_object then null; when undefined_object then null;
    end;
  end loop;
end $$;

-- ----------------------------------------------------------------------------
-- VERIFICATION
-- ----------------------------------------------------------------------------
select 'Abonnements par (compte, appareil)' as element,
       case when exists (select 1 from pg_indexes
                         where schemaname='public' and indexname='uq_push_account_endpoint')
            then 'OK' else 'MANQUANT' end as verdict
union all
select 'Alerte a chaque etape de suivi',
       case when exists (select 1 from pg_trigger where tgname='trg_secoto_tracking_notify')
            then 'OK' else 'MANQUANT' end
union all
select 'Suivi diffuse en temps reel',
       case when exists (select 1 from pg_publication_tables
                         where pubname='supabase_realtime' and schemaname='public'
                           and tablename='mission_tracking_events')
            then 'OK' else 'ABSENT' end;

notify pgrst, 'reload schema';
