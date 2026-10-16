-- SECOTO 097 — Plus aucun numéro SIREN / SIRET de SECOTO sur les documents.
-- ----------------------------------------------------------------------------
-- Demande du 16/10/2026 : tant que la nouvelle immatriculation n'est pas
-- active, aucun numéro n'est affiché. Mention : « Immatriculation en cours de
-- mise à jour ».
--
--   1. Factures émises automatiquement (paiement direct) : le libellé SECOTO
--      ne porte plus de numéro (factures FUTURES uniquement).
--   2. Maquettes devis / bon de mission / facture enregistrées en base : même
--      remplacement. Une copie des maquettes d'avant est gardée.
--
-- Les documents DÉJÀ émis ne sont pas touchés : une facture émise ne se
-- modifie pas après coup.
--
-- Additif : deux repères remplacés dans une fonction, une table de
-- sauvegarde, un remplacement de texte dans les maquettes. Rien n'est
-- supprimé, aucune policy touchée. Rejouable.

select secoto_private.mig074_patch(
  'secoto_private.od_issue_direct_invoices(uuid)'::regprocedure,
  '''SECOTO - SIREN 951 857 531 - intermediaire de mise en relation''',
  '''SECOTO - Immatriculation en cours de mise à jour - intermediaire de mise en relation'' /* 097a */');

select secoto_private.mig074_patch(
  'secoto_private.od_issue_direct_invoices(uuid)'::regprocedure,
  '''SECOTO - SIREN 951 857 531''',
  '''SECOTO - Immatriculation en cours de mise à jour'' /* 097b */');

create table if not exists secoto_private.sauvegarde_097_doc_templates as
  select t.*, now() as sauvegarde_le from public.doc_templates t;
revoke all on table secoto_private.sauvegarde_097_doc_templates from public, anon, authenticated;

update public.doc_templates
   set html = regexp_replace(
                regexp_replace(html, 'SIRET ?: ?951 857 531 00028', 'Immatriculation en cours de mise à jour', 'g'),
                'SIRE[NT] 951 857 531( 00028)?', 'Immatriculation en cours de mise à jour', 'g')
 where html ~ '951 857 531';

-- 3. Garde-fou : une application pas encore mise à jour (ancien build iOS /
--    Android) resynchronise ses maquettes à l'ouverture de l'espace admin.
--    La base retire le numéro au passage : il ne peut pas revenir par là.
do $m$
begin
  if position('values (p_kind, p_html, now())'
              in coalesce(pg_get_functiondef(to_regprocedure('public.secoto_save_doc_template(text,text)')), '')) > 0 then
    perform secoto_private.mig074_patch(
      'public.secoto_save_doc_template(text,text)'::regprocedure,
      'values (p_kind, p_html, now())',
      'values (p_kind, /* 097 */ regexp_replace(regexp_replace(p_html, ''SIRET ?: ?951 857 531 00028'', ''Immatriculation en cours de mise à jour'', ''g''), ''SIRE[NT] 951 857 531( 00028)?'', ''Immatriculation en cours de mise à jour'', ''g''), now())');
  end if;
end
$m$;
