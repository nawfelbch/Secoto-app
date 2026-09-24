-- ============================================================================
-- SECOTO — CORRECTIF 041 : FABRIQUER LE JETON SANS PGCRYPTO
-- ----------------------------------------------------------------------------
-- Les migrations 038 et 040 tiraient le jeton du lien de paiement avec
-- gen_random_bytes(), fournie par l'extension pgcrypto. Supabase range cette
-- extension dans le schema « extensions », hors du search_path de nos
-- fonctions : la base repondait « function gen_random_bytes(integer) does not
-- exist » et aucun lien ne pouvait etre cree.
--
-- On s'appuie desormais sur gen_random_uuid(), presente dans PostgreSQL lui-
-- meme depuis la version 13 : deux UUID concatenes donnent 64 caracteres
-- hexadecimaux tires du meme generateur cryptographique. Aucune extension
-- requise, et le jeton reste au format attendu par la fonction devis-pay.
-- ============================================================================

create or replace function secoto_private.new_link_token()
returns text
language sql
volatile
security definer
set search_path = public, secoto_private
as $function$
  select replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', '');
$function$;

revoke all on function secoto_private.new_link_token() from public, anon, authenticated;

comment on function secoto_private.new_link_token() is
  'Jeton de lien de paiement : 64 caracteres hexadecimaux, sans dependance a pgcrypto.';

-- Remplacement dans les deux fabricants de liens, sans toucher au reste.
do $patch$
declare
  v_src text;
  v_fn  record;
begin
  for v_fn in
    select p.oid, n.nspname, p.proname
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where (n.nspname = 'secoto_private' and p.proname = 'devis_link')
        or (n.nspname = 'public' and p.proname = 'secoto_admin_devis_link_quote')
  loop
    v_src := pg_get_functiondef(v_fn.oid);
    if position('gen_random_bytes' in v_src) = 0 then continue; end if;
    v_src := replace(v_src, 'encode(gen_random_bytes(18), ''hex'')', 'secoto_private.new_link_token()');
    execute v_src;
    raise notice 'Jeton corrige dans %.%', v_fn.nspname, v_fn.proname;
  end loop;
end;
$patch$;

-- Controle : plus aucune fonction SECOTO ne doit dependre de pgcrypto.
do $verif$
declare v_reste int;
begin
  select count(*) into v_reste
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname in ('public', 'secoto_private')
     and p.proname in ('devis_link', 'secoto_admin_devis_link_quote')
     and position('gen_random_bytes' in pg_get_functiondef(p.oid)) > 0;
  if v_reste > 0 then
    raise exception 'Correctif incomplet : % fonction(s) utilisent encore gen_random_bytes.', v_reste;
  end if;
end;
$verif$;

notify pgrst, 'reload schema';
