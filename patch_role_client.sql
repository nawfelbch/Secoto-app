-- ============================================================================
-- SECOTO — Correctif « un client ne peut pas publier de course »
-- ----------------------------------------------------------------------------
-- A coller dans Supabase > SQL Editor > Run. Idempotent.
--
-- Erreur corrigee :
--   new row for relation "missions" violates check constraint
--   "missions_created_by_role_check"
--
-- Cause : la contrainte d'origine n'autorisait pas la valeur 'client' dans
-- missions.created_by_role (elle datait d'avant l'ouverture de l'app aux
-- clients). On elargit la liste des valeurs acceptees, sur missions ET sur
-- mission_requests, sans rien supprimer des donnees existantes.
-- ============================================================================

do $$
declare
  t    text;
  cn   text;
  tables text[] := array['missions', 'mission_requests'];
begin
  foreach t in array tables loop
    if to_regclass('public.' || t) is null then continue; end if;
    if not exists (
      select 1 from information_schema.columns
      where table_schema = 'public' and table_name = t and column_name = 'created_by_role'
    ) then continue; end if;

    -- Retirer toute contrainte CHECK portant sur created_by_role,
    -- quel que soit son nom.
    for cn in
      select con.conname
      from pg_constraint con
      join pg_class rel on rel.oid = con.conrelid
      join pg_namespace ns on ns.oid = rel.relnamespace
      where ns.nspname = 'public'
        and rel.relname = t
        and con.contype = 'c'
        and pg_get_constraintdef(con.oid) ilike '%created_by_role%'
    loop
      execute format('alter table public.%I drop constraint %I', t, cn);
    end loop;

    -- Recreer la contrainte avec TOUTES les valeurs utilisees par l'app.
    -- « not valid » : les lignes deja enregistrees (parfois issues d'anciennes
    -- versions) ne sont pas re-verifiees, la regle s'applique aux nouvelles.
    execute format($f$
      alter table public.%I
        add constraint %I check (
          created_by_role is null
          or created_by_role in (
            'admin', 'client', 'transporter', 'transporter_request', 'guest'
          )
        ) not valid
    $f$, t, t || '_created_by_role_check');

    -- Si toutes les lignes existantes respectent deja la regle, on la valide.
    begin
      execute format('alter table public.%I validate constraint %I', t, t || '_created_by_role_check');
    exception when others then null;
    end;
  end loop;
end $$;

notify pgrst, 'reload schema';
