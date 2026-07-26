-- SECOTO - PRE-FLIGHT DE PRODUCTION (LECTURE SEULE)
-- Date: 2026-07-26
--
-- IMPORTANT
-- 1. Executer ce fichier seul dans Supabase SQL Editor.
-- 2. Exporter et conserver tous les resultats avec un dump logique et une
--    sauvegarde PITR avant d'executer une migration SECOTO.
-- 3. Ce script ne modifie aucune donnee et termine par ROLLBACK.
-- 4. Ne pas executer les anciens scripts du depot en bloc : certains retirent
--    des colonnes, relachent des policies ou suppriment des donnees.

begin transaction read only;

select
  now() as checked_at,
  current_database() as database_name,
  current_user as database_user,
  version() as postgres_version,
  current_setting('server_version_num') as server_version_num;

-- Extensions necessaires aux migrations.
select e.extname, e.extversion
from pg_extension e
where e.extname in ('pgcrypto', 'uuid-ossp')
order by e.extname;

-- Tables attendues et activation RLS.
with expected(table_name) as (
  values
    ('accounts'),
    ('missions'),
    ('mission_requests'),
    ('mission_applications'),
    ('documents'),
    ('mission_tracking_events'),
    ('mission_tracking_photos'),
    ('frais'),
    ('notifications'),
    ('push_subscriptions')
)
select
  e.table_name,
  c.oid is not null as exists,
  coalesce(c.relrowsecurity, false) as rls_enabled,
  coalesce(c.relforcerowsecurity, false) as rls_forced,
  pg_get_userbyid(c.relowner) as owner
from expected e
left join pg_class c
  on c.relname = e.table_name
 and c.relnamespace = 'public'::regnamespace
 and c.relkind in ('r', 'p')
order by e.table_name;

-- Colonnes, types, valeurs par defaut, nullabilite et colonnes generees.
select
  c.table_name,
  c.ordinal_position,
  c.column_name,
  c.data_type,
  c.udt_name,
  c.is_nullable,
  c.column_default,
  c.is_generated,
  c.generation_expression
from information_schema.columns c
where c.table_schema = 'public'
  and c.table_name in (
    'accounts',
    'missions',
    'mission_requests',
    'mission_applications',
    'documents',
    'mission_tracking_events',
    'mission_tracking_photos',
    'frais',
    'notifications',
    'push_subscriptions'
  )
order by c.table_name, c.ordinal_position;

-- Contraintes et index existants.
select
  n.nspname as schema_name,
  t.relname as table_name,
  con.conname as constraint_name,
  con.contype as constraint_type,
  pg_get_constraintdef(con.oid, true) as definition
from pg_constraint con
join pg_class t on t.oid = con.conrelid
join pg_namespace n on n.oid = t.relnamespace
where n.nspname = 'public'
  and t.relname in (
    'accounts',
    'missions',
    'mission_requests',
    'mission_applications',
    'documents',
    'mission_tracking_events',
    'mission_tracking_photos',
    'frais',
    'notifications',
    'push_subscriptions'
  )
order by t.relname, con.conname;

select schemaname, tablename, indexname, indexdef
from pg_indexes
where schemaname = 'public'
  and tablename in (
    'accounts',
    'missions',
    'mission_requests',
    'mission_applications',
    'documents',
    'mission_tracking_events',
    'mission_tracking_photos',
    'frais',
    'notifications',
    'push_subscriptions'
  )
order by tablename, indexname;

-- Roles et statuts reels. Toute valeur inattendue doit etre resolue avant la
-- migration, sans la convertir silencieusement.
select role, status, count(*) as account_count
from public.accounts
group by role, status
order by role, status;

select transporter_type, count(*) as account_count
from public.accounts
where role = 'transporter'
group by transporter_type
order by transporter_type;

select client_type, count(*) as account_count
from public.accounts
where role = 'client'
group by client_type
order by client_type;

select type, status, progress_status, payment_method, count(*) as mission_count
from public.missions
group by type, status, progress_status, payment_method
order by type, status, progress_status, payment_method;

select status, created_by_role, count(*) as request_count
from public.mission_requests
group by status, created_by_role
order by status, created_by_role;

select status, count(*) as application_count
from public.mission_applications
group by status
order by status;

-- Incoherences qui bloquent une migration atomique.
select public_ref, count(*) as duplicate_count
from public.missions
where public_ref is not null
group by public_ref
having count(*) > 1
order by duplicate_count desc, public_ref;

select public_ref, count(*) as duplicate_count
from public.mission_requests
where public_ref is not null
group by public_ref
having count(*) > 1
order by duplicate_count desc, public_ref;

select mission_id, transporter_id, count(*) as duplicate_count
from public.mission_applications
group by mission_id, transporter_id
having count(*) > 1
order by duplicate_count desc;

select id, status, assigned_transporter_id
from public.missions
where
  (status::text = 'assigned' and assigned_transporter_id is null)
  or (status::text = 'published' and assigned_transporter_id is not null)
  or (status::text = 'completed' and assigned_transporter_id is null)
order by created_at desc;

select ma.mission_id, count(*) filter (where ma.status::text = 'accepted') as accepted_count
from public.mission_applications ma
group by ma.mission_id
having count(*) filter (where ma.status::text = 'accepted') > 1
order by accepted_count desc;

select m.id, m.public_ref, m.type, m.distance_km, m.carrier_cost,
       m.client_price, m.carrier_pay, m.margin
from public.missions m
where
  m.distance_km < 0
  or m.carrier_cost < 0
  or m.client_price < 0
  or m.carrier_pay < 0
  or m.margin <> round(m.client_price - m.carrier_pay, 2)
order by m.created_at desc;

-- Policies RLS et grants. Exporter integralement ces resultats.
select schemaname, tablename, policyname, permissive, roles, cmd, qual, with_check
from pg_policies
where schemaname in ('public', 'storage')
order by schemaname, tablename, policyname;

select grantee, table_schema, table_name, privilege_type, is_grantable
from information_schema.role_table_grants
where table_schema in ('public', 'storage')
order by table_schema, table_name, grantee, privilege_type;

select routine_schema, routine_name, grantee, privilege_type
from information_schema.routine_privileges
where routine_schema = 'public'
order by routine_name, grantee;

-- Fonctions SECURITY DEFINER, search_path et definition exacte.
select
  n.nspname as schema_name,
  p.proname,
  pg_get_function_identity_arguments(p.oid) as identity_arguments,
  p.prosecdef as security_definer,
  p.proconfig,
  has_function_privilege('anon', p.oid, 'EXECUTE') as anon_can_execute,
  has_function_privilege('authenticated', p.oid, 'EXECUTE') as authenticated_can_execute,
  pg_get_functiondef(p.oid) as definition
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
order by p.proname, identity_arguments;

-- Vues exposees par PostgREST et leur definition.
select
  n.nspname as schema_name,
  c.relname as view_name,
  c.reloptions,
  pg_get_userbyid(c.relowner) as owner,
  pg_get_viewdef(c.oid, true) as definition
from pg_class c
join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public'
  and c.relkind in ('v', 'm')
order by c.relname;

-- Triggers metier et publication Realtime.
select
  event_object_table,
  trigger_name,
  event_manipulation,
  action_timing,
  action_statement
from information_schema.triggers
where trigger_schema = 'public'
order by event_object_table, trigger_name, event_manipulation;

select pubname, schemaname, tablename
from pg_publication_tables
where pubname = 'supabase_realtime'
order by schemaname, tablename;

-- Auth: les metadonnees ne doivent pas contenir de privilege eleve.
select
  id,
  email,
  raw_user_meta_data ->> 'role' as metadata_role,
  raw_user_meta_data ->> 'is_verified' as metadata_is_verified,
  raw_user_meta_data ->> 'status' as metadata_status,
  raw_app_meta_data ->> 'role' as app_metadata_role,
  created_at
from auth.users
where
  coalesce(raw_user_meta_data ->> 'role', '') not in ('', 'client', 'transporter')
  or raw_user_meta_data ? 'is_verified'
  or raw_user_meta_data ? 'status'
order by created_at desc;

-- Buckets sensibles: public doit etre false.
select id, name, public, file_size_limit, allowed_mime_types, created_at, updated_at
from storage.buckets
where id in ('documents', 'documents-pdf', 'mission-photos', 'justificatifs')
order by id;

-- Inventaire d'objets et controle des chemins. Aucun objet n'est modifie.
select bucket_id, count(*) as object_count, sum(coalesce((metadata ->> 'size')::bigint, 0)) as total_bytes
from storage.objects
where bucket_id in ('documents', 'documents-pdf', 'mission-photos', 'justificatifs')
group by bucket_id
order by bucket_id;

select bucket_id, name, owner_id, created_at
from storage.objects
where bucket_id in ('documents', 'documents-pdf', 'mission-photos', 'justificatifs')
  and (
    name like '/%'
    or name like '%..%'
    or split_part(name, '/', 1) = ''
  )
order by created_at desc;

-- Lignes sensibles qui dependent encore d'une URL publique historique.
select 'documents' as source, count(*) as rows_with_public_url
from public.documents
where coalesce(file_url, '') <> ''
union all
select 'mission_tracking_photos', count(*)
from public.mission_tracking_photos
where coalesce(file_url, '') <> ''
union all
select 'frais', count(*)
from public.frais
where coalesce(justificatif_url, '') ~* '^https?://';

-- References vers un objet absent (orphelins base -> Storage).
select d.id, 'documents' as bucket_id, d.file_path
from public.documents d
where d.file_path is not null
  and d.doc_type is null
  and not exists (
    select 1 from storage.objects o
    where o.bucket_id = 'documents' and o.name = d.file_path
  )
union all
select p.id, 'mission-photos', p.file_path
from public.mission_tracking_photos p
where p.file_path is not null
  and not exists (
    select 1 from storage.objects o
    where o.bucket_id = 'mission-photos' and o.name = p.file_path
  )
union all
select f.id, 'justificatifs', f.justificatif_url
from public.frais f
where f.justificatif_url is not null
  and f.justificatif_url !~* '^https?://'
  and not exists (
    select 1 from storage.objects o
    where o.bucket_id = 'justificatifs' and o.name = f.justificatif_url
  );

-- Objets sans ligne metier (Storage -> base), a examiner mais jamais supprimer
-- directement depuis storage.objects.
select o.bucket_id, o.name, o.created_at
from storage.objects o
where o.bucket_id = 'documents'
  and not exists (
    select 1 from public.documents d
    where d.file_path = o.name and d.doc_type is null
  )
union all
select o.bucket_id, o.name, o.created_at
from storage.objects o
where o.bucket_id = 'mission-photos'
  and not exists (
    select 1 from public.mission_tracking_photos p where p.file_path = o.name
  )
union all
select o.bucket_id, o.name, o.created_at
from storage.objects o
where o.bucket_id = 'justificatifs'
  and not exists (
    select 1 from public.frais f
    where f.justificatif_url = o.name
  )
order by created_at desc;

-- Volumetrie utile au plan de sauvegarde et aux index.
select 'accounts' as relation, count(*) as row_count from public.accounts
union all select 'missions', count(*) from public.missions
union all select 'mission_requests', count(*) from public.mission_requests
union all select 'mission_applications', count(*) from public.mission_applications
union all select 'documents', count(*) from public.documents
union all select 'mission_tracking_events', count(*) from public.mission_tracking_events
union all select 'mission_tracking_photos', count(*) from public.mission_tracking_photos
union all select 'frais', count(*) from public.frais
union all select 'notifications', count(*) from public.notifications
union all select 'push_subscriptions', count(*) from public.push_subscriptions
order by relation;

rollback;
