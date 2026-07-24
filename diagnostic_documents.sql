-- ============================================================================
-- SECOTO — Diagnostic du circuit des documents
-- ----------------------------------------------------------------------------
-- A coller dans Supabase > SQL Editor > Run.
-- Ne modifie RIEN : ce script se contente de dire ce qui est en place et ce
-- qui manque. Lisez la colonne « verdict ».
-- ============================================================================

with checks as (

  -- 1. Les fonctions du circuit existent-elles ?
  select 1 as ordre,
         'Fonction d''emission des documents' as element,
         case when exists (
           select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname = 'secoto_emit_document'
         ) then 'OK'
         else 'MANQUANT -> lancer patch_documents_signature.sql' end as verdict

  union all
  select 2, 'Fonction de signature',
         case when exists (
           select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname = 'secoto_sign_document'
         ) then 'OK'
         else 'MANQUANT -> lancer patch_documents_signature.sql' end

  union all
  select 3, 'Fonction de notification aux admins',
         case when exists (
           select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname = 'secoto_notify_admins'
         ) then 'OK'
         else 'MANQUANT -> lancer patch_temps_reel.sql AVANT le patch documents' end

  union all
  -- 2. Les colonnes du cycle de vie sont-elles presentes ?
  select 4, 'Colonnes documents (recipient_id, html_snapshot, needs_signature)',
         case when (
           select count(*) from information_schema.columns
           where table_schema = 'public' and table_name = 'documents'
             and column_name in ('recipient_id', 'html_snapshot', 'needs_signature')
         ) = 3 then 'OK'
         else 'INCOMPLET -> lancer patch_documents_signature.sql' end

  union all
  -- 3. Le declencheur qui envoie le bon de mission apres signature du devis.
  select 5, 'Declencheur d''enchainement apres signature',
         case when exists (
           select 1 from pg_trigger where tgname = 'trg_secoto_document_signed'
         ) then 'OK'
         else 'MANQUANT -> lancer patch_documents_signature.sql' end

  union all
  -- 4. Y a-t-il au moins un compte administrateur ?
  select 6, 'Compte administrateur',
         case when exists (select 1 from public.accounts where role = 'admin')
         then 'OK' else 'AUCUN ADMIN -> l''emission sera refusee' end

  union all
  -- 5. Missions attribuees SANS devis emis (le cas qui bloque le circuit).
  select 7, 'Missions attribuees sans devis',
         coalesce((
           select case when count(*) = 0 then 'OK : aucune'
                  else count(*)::text || ' mission(s) -> bouton « Envoyer le devis au client » sur la fiche'
                  end
           from public.missions m
           where m.status::text = 'assigned'
             and m.client_account_id is not null
             and not exists (
               select 1 from public.documents d
               where d.mission_id = m.id and d.doc_type = 'devis'
             )
         ), 'OK : aucune')

  union all
  -- 6. Courses attribuees non reliees a un compte client (devis impossible).
  select 8, 'Missions attribuees sans compte client relie',
         coalesce((
           select case when count(*) = 0 then 'OK : aucune'
                  else count(*)::text || ' mission(s) : client hors application, devis non envoyable'
                  end
           from public.missions m
           where m.status::text = 'assigned' and m.client_account_id is null
         ), 'OK : aucune')

  union all
  -- 7. Le temps reel diffuse-t-il bien la table documents ?
  select 9, 'Documents diffuses en temps reel',
         case when exists (
           select 1 from pg_publication_tables
           where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'documents'
         ) then 'OK'
         else 'ABSENT -> relancer patch_documents_signature.sql' end
)
select element, verdict from checks order by ordre;

-- ----------------------------------------------------------------------------
-- Detail des documents deja emis (vide = aucun document genere a ce jour).
-- ----------------------------------------------------------------------------
select d.numero,
       d.doc_type   as type_document,
       d.statut,
       d.needs_signature as signature_requise,
       d.emitted_at as emis_le,
       d.signed_at  as signe_le,
       a.full_name  as destinataire,
       m.public_ref as mission
from public.documents d
left join public.accounts a on a.id = d.recipient_id
left join public.missions m on m.id = d.mission_id
where d.doc_type is not null
order by d.created_at desc
limit 50;
