-- ============================================================================
-- SECOTO — MIGRATION 123 : IMMATRICULATION ACTIVE — LE SIRET REVIENT (KBIS VALIDE)
-- ----------------------------------------------------------------------------
-- Le 30/10/2026, le Kbis de SECOTO est de nouveau valide : SIRET
-- 951 857 531 00028, RCS Nanterre. On annule l'effet de la 097 (« Immatriculation
-- en cours de mise à jour ») côté base :
--   1. Factures émises automatiquement (paiement direct) : le libellé SECOTO
--      reprend le SIRET (factures FUTURES uniquement ; une facture émise ne se
--      modifie pas).
--   2. Maquettes devis / bon de mission / facture enregistrées en base : la
--      mention provisoire devient le SIRET.
--   3. Le garde-fou 097, qui retirait le numéro à chaque enregistrement d'une
--      maquette depuis l'application, est retiré.
-- La sauvegarde des maquettes faite par la 097 reste en place. ADDITIF, rejouable.
-- ============================================================================

select secoto_private.mig074_patch(
  'secoto_private.od_issue_direct_invoices(uuid)'::regprocedure,
  '''SECOTO - Immatriculation en cours de mise à jour - intermediaire de mise en relation'' /* 097a */',
  '''SECOTO - SIRET 951 857 531 00028 - RCS Nanterre - intermediaire de mise en relation'' /* 123a */');

select secoto_private.mig074_patch(
  'secoto_private.od_issue_direct_invoices(uuid)'::regprocedure,
  '''SECOTO - Immatriculation en cours de mise à jour'' /* 097b */',
  '''SECOTO - SIRET 951 857 531 00028 - RCS Nanterre'' /* 123b */');

update public.doc_templates
   set html = replace(html, 'Immatriculation en cours de mise à jour', 'SIRET 951 857 531 00028 · RCS Nanterre')
 where html like '%Immatriculation en cours de mise à jour%';

do $m$
begin
  if position('/* 097 */' in coalesce(pg_get_functiondef(to_regprocedure('public.secoto_save_doc_template(text,text)')), '')) > 0 then
    perform secoto_private.mig074_patch(
      'public.secoto_save_doc_template(text,text)'::regprocedure,
      'values (p_kind, /* 097 */ regexp_replace(regexp_replace(p_html, ''SIRET ?: ?951 857 531 00028'', ''Immatriculation en cours de mise à jour'', ''g''), ''SIRE[NT] 951 857 531( 00028)?'', ''Immatriculation en cours de mise à jour'', ''g''), now())',
      'values (p_kind, /* 123 */ p_html, now())');
  end if;
end
$m$;

notify pgrst, 'reload schema';
