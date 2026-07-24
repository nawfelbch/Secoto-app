-- ============================================================================
-- SECOTO — Correctif « un visiteur ne peut pas demander de devis »
-- ----------------------------------------------------------------------------
-- A coller dans Supabase > SQL Editor > Run. Idempotent.
--
-- Erreur corrigee :
--   null value in column "pickup_address" of relation "mission_requests"
--   violates not-null constraint
--
-- Contexte : le formulaire public sert a CAPTER un prospect en une minute.
-- On lui demande le strict necessaire (nom, telephone, type, vehicule) ; les
-- adresses precises se recueillent au rappel telephonique. La base exigeait
-- pourtant l'adresse d'enlevement, ce qui bloquait toute demande.
--
-- On rend donc facultatives toutes les colonnes accessoires de
-- mission_requests, en conservant obligatoires celles qui identifient la
-- demande (identifiant, statut, date de creation).
-- ============================================================================

do $$
declare
  c record;
  garder text[] := array['id', 'created_at', 'status', 'public_ref'];
begin
  for c in
    select column_name
    from information_schema.columns
    where table_schema = 'public'
      and table_name   = 'mission_requests'
      and is_nullable  = 'NO'
      -- On ne filtre PAS sur la valeur par defaut : une colonne qui en a une
      -- reste bloquante des lors qu'on lui envoie explicitement null.
      and not (column_name = any (garder))
  loop
    execute format('alter table public.mission_requests alter column %I drop not null', c.column_name);
    raise notice 'Colonne rendue facultative : %', c.column_name;
  end loop;
end $$;

-- Meme precaution sur missions : une mission creee a partir d'une demande
-- incomplete ne doit pas echouer a la validation par l'admin.
do $$
declare
  c record;
  garder text[] := array['id', 'created_at', 'status', 'public_ref', 'type'];
begin
  for c in
    select column_name
    from information_schema.columns
    where table_schema = 'public'
      and table_name   = 'missions'
      and is_nullable  = 'NO'
      -- On ne filtre PAS sur la valeur par defaut : une colonne qui en a une
      -- reste bloquante des lors qu'on lui envoie explicitement null.
      and not (column_name = any (garder))
  loop
    execute format('alter table public.missions alter column %I drop not null', c.column_name);
    raise notice 'Colonne rendue facultative : %', c.column_name;
  end loop;
end $$;

-- ----------------------------------------------------------------------------
-- VERIFICATION : plus aucune colonne bloquante sur le depot public.
-- ----------------------------------------------------------------------------
select 'mission_requests' as table_concernee,
       coalesce(string_agg(column_name, ', ' order by column_name),
                'aucune — le formulaire public passe') as colonnes_encore_obligatoires
from information_schema.columns
where table_schema = 'public' and table_name = 'mission_requests'
  and is_nullable = 'NO'
  and column_name not in ('id', 'created_at', 'status', 'public_ref')
union all
select 'missions',
       coalesce(string_agg(column_name, ', ' order by column_name),
                'aucune — la validation admin passe')
from information_schema.columns
where table_schema = 'public' and table_name = 'missions'
  and is_nullable = 'NO'
  and column_name not in ('id', 'created_at', 'status', 'public_ref', 'type');

notify pgrst, 'reload schema';
