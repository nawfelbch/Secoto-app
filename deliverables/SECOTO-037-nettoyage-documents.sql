-- ============================================================================
-- SECOTO 037 — NETTOYAGE DES DOCUMENTS FANTOMES
-- ----------------------------------------------------------------------------
-- Certaines lignes de `public.documents` pointent vers un fichier qui n'existe
-- plus dans le stockage. A chaque ouverture de l'espace transporteur ou de
-- l'admin, l'application demandait une URL signee pour ces fichiers : Supabase
-- repondait 400, la console se remplissait d'erreurs et chaque rechargement
-- refaisait le meme appel pour rien.
--
-- Ce script ne supprime rien sans filet : les lignes concernees sont d'abord
-- recopiees dans une table de sauvegarde, puis leur chemin de fichier est vide
-- (ou la ligne supprimee si la colonne n'accepte pas de valeur vide).
-- ============================================================================

-- 1. Sauvegarde des lignes concernees --------------------------------------
create table if not exists public.secoto_documents_orphelins (
  id            uuid primary key,
  account_id    uuid,
  mission_id    uuid,
  file_name     text,
  file_path     text,
  bucket        text,
  doc_type      text,
  created_at    timestamptz,
  archive_le    timestamptz not null default now()
);

with orphelins as (
  select d.*,
         case when d.doc_type is not null then 'documents-pdf' else 'documents' end as bucket
    from public.documents d
   where d.file_path is not null
)
insert into public.secoto_documents_orphelins
       (id, account_id, mission_id, file_name, file_path, bucket, doc_type, created_at)
select o.id, o.account_id, o.mission_id, o.file_name, o.file_path, o.bucket, o.doc_type, o.created_at
  from orphelins o
  left join storage.objects s
         on s.bucket_id = o.bucket
        and s.name = o.file_path
 where s.id is null
on conflict (id) do nothing;

-- 2. Nettoyage ---------------------------------------------------------------
-- On prefere vider le chemin plutot que supprimer la ligne : le numero de
-- facture, le statut et l'historique restent consultables.
do $$
declare
  v_ids uuid[];
begin
  select array_agg(id) into v_ids from public.secoto_documents_orphelins;
  if v_ids is null then
    raise notice 'Aucun document fantome.';
    return;
  end if;

  begin
    update public.documents set file_path = null where id = any(v_ids);
    raise notice 'Chemins vides pour % document(s).', array_length(v_ids, 1);
  exception when not_null_violation then
    delete from public.documents where id = any(v_ids);
    raise notice 'Colonne obligatoire : % ligne(s) supprimee(s), copie conservee dans secoto_documents_orphelins.', array_length(v_ids, 1);
  end;
end $$;

-- 3. Verification ------------------------------------------------------------
select count(*) as documents_fantomes_restants
  from public.documents d
  left join storage.objects s
         on s.bucket_id = case when d.doc_type is not null then 'documents-pdf' else 'documents' end
        and s.name = d.file_path
 where d.file_path is not null and s.id is null;
