-- ============================================================================
-- SECOTO - Patch : suppression propre des courses + acces admin aux clients.
-- A coller dans le SQL Editor Supabase. Idempotent.
-- ============================================================================

-- 1) SUPPRESSION EN CASCADE : quand une mission est supprimee, ses donnees
--    liees (candidatures, suivi, photos, documents, frais) sont supprimees
--    aussi -> plus d'orphelins, la course disparait vraiment pour tous.
do $$
declare
  t text;
  cname text;
  child_tables text[] := array[
    'mission_applications','mission_tracking_events',
    'mission_tracking_photos','documents','frais'
  ];
begin
  foreach t in array child_tables loop
    if to_regclass('public.'||t) is null then continue; end if;

    -- Retirer la contrainte FK existante vers missions (quel que soit son nom)
    select tc.constraint_name into cname
    from information_schema.table_constraints tc
    join information_schema.key_column_usage kcu
      on tc.constraint_name = kcu.constraint_name and tc.table_schema = kcu.table_schema
    join information_schema.constraint_column_usage ccu
      on tc.constraint_name = ccu.constraint_name and tc.table_schema = ccu.table_schema
    where tc.constraint_type = 'FOREIGN KEY' and tc.table_schema = 'public'
      and tc.table_name = t and kcu.column_name = 'mission_id'
      and ccu.table_name = 'missions'
    limit 1;
    if cname is not null then
      execute format('alter table public.%I drop constraint %I', t, cname);
    end if;

    -- Recreer la FK avec ON DELETE CASCADE
    if exists (select 1 from information_schema.columns
               where table_schema='public' and table_name=t and column_name='mission_id') then
      execute format(
        'alter table public.%I add constraint %I foreign key (mission_id) references public.missions(id) on delete cascade',
        t, t||'_mission_id_fkey');
    end if;
  end loop;
end $$;

-- 2) TEMPS REEL : permet aux autres utilisateurs de voir la suppression
--    immediatement (les evenements DELETE portent alors l'identifiant).
alter table public.missions replica identity full;

-- 3) ACCES ADMIN AUX CLIENTS : l'admin peut lire tous les comptes ;
--    chaque utilisateur lit le sien.
drop policy if exists accounts_admin_read on public.accounts;
create policy accounts_admin_read on public.accounts
  for select to authenticated
  using (public.secoto_is_admin() or id = auth.uid());

notify pgrst, 'reload schema';
