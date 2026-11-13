-- ============================================================================
-- SECOTO — MIGRATION 143 : KLARNA CONFORME CCD2 (20/11/2026) ET INTERDIT EN B2B
-- ----------------------------------------------------------------------------
-- 1. Directive crédit à la consommation (CCD2), applicable en France le
--    20/11/2026 : toute mention d'un paiement en plusieurs fois avec Klarna doit
--    reprendre le texte préapprouvé par Klarna avec l'avertissement obligatoire.
--    Nos e-mails et notifications citent désormais seulement « Klarna » (ligne
--    générique, aucune mention requise) ; plus aucun exemple « 3 × … € ».
--    Source : docs.klarna.com — Partner marketing legal guidelines, France.
-- 2. Conditions Stripe/Klarna : Klarna est interdit pour les ventes entre
--    entreprises (B2B). Un compte professionnel (accounts.client_type = 'pro')
--    ne peut plus choisir Klarna comme mode de règlement.
-- ADDITIF, rejouable (mig074_patch ignore un patch déjà appliqué).
-- ============================================================================

-- 2. Klarna refusé pour un compte professionnel.
select secoto_private.mig074_patch(
  'public.secoto_od_choisir_reglement(uuid,text)'::regprocedure,
  $a$  if p_mode not in ('carte', 'virement', 'klarna', 'especes') then raise exception 'Mode de règlement inconnu.'; end if;$a$,
  $b$  if p_mode not in ('carte', 'virement', 'klarna', 'especes') then raise exception 'Mode de règlement inconnu.'; end if;
  -- 143 : Klarna est réservé aux particuliers (interdit en B2B).
  if p_mode = 'klarna' and exists (select 1 from public.transport_orders o join public.accounts a on a.id = o.account_id
                                    where o.id = p_order_id and a.client_type = 'pro') then
    raise exception 'Klarna est réservé aux particuliers. Choisissez la carte, le virement ou les espèces.';
  end if;$b$);

-- 1a. Relance « carte non enregistrée » (141).
select secoto_private.mig074_patch(
  'secoto_private.od_relance_carte()'::regprocedure,
  $a$      when 'klarna' then 'en plusieurs fois avec Klarna'$a$,
  $b$      when 'klarna' then 'avec Klarna'  -- 143$b$);

-- 1b. Notification « véhicule livré » (mode Klarna).
select secoto_private.mig074_patch(
  'secoto_private.trg_reglement_livraison()'::regprocedure,
  $a$    perform secoto_private.notify_event(new.account_id, 'payment', 'Véhicule livré : réglez en plusieurs fois',$a$,
  $b$    perform secoto_private.notify_event(new.account_id, 'payment', 'Véhicule livré : payez avec Klarna',  -- 143$b$);
select secoto_private.mig074_patch(
  'secoto_private.trg_reglement_livraison()'::regprocedure,
  $a$Réglez %s avec Klarna depuis votre commande (bouton « Payer maintenant »).$a$,
  $b$Réglez %s avec Klarna depuis votre commande (bouton « Payez avec Klarna »).$b$);

-- 1c. E-mail « véhicule arrivé » (mode Klarna) : le bouton s'appelle « Payez avec Klarna ».
select secoto_private.mig074_patch(
  'secoto_private.email_client_etape(public.transport_orders,text)'::regprocedure,
  $a$        then 'Réglez maintenant avec Klarna depuis votre commande (bouton « Payer maintenant »).$a$,
  $b$        then 'Réglez maintenant avec Klarna depuis votre commande (bouton « Payez avec Klarna »).$b$);

-- 1d. E-mails de devis (prévenir + relances) : plus d'exemple « 3 × … ».
--     L'argument du montant par échéance (5e) n'est plus lu : les suivants sont
--     désignés par leur position (%6$s = date de validité, puis %s = lien).
select secoto_private.mig074_patch(
  'secoto_private.devis_prevenir_par_email(uuid)'::regprocedure,
  $a$      || E'• Paiement par carte, virement%s, ou en plusieurs fois avec Klarna (par exemple 3 × %s, sous réserve d''acceptation).\n'$a$,
  $b$      || E'• Paiement par carte, virement%4$s ou avec Klarna.\n'  -- 143$b$);
select secoto_private.mig074_patch(
  'secoto_private.devis_prevenir_par_email(uuid)'::regprocedure,
  $a$      || E'• Ce prix est garanti jusqu''au %s.\n\n'$a$,
  $b$      || E'• Ce prix est garanti jusqu''au %6$s.\n\n'$b$);

select secoto_private.mig074_patch(
  'public.secoto_devis_relances(integer)'::regprocedure,
  $a$      || E'• Paiement par carte, virement%s, ou en plusieurs fois avec Klarna (par exemple 3 × %s, sous réserve d''acceptation).\n'$a$,
  $b$      || E'• Paiement par carte, virement%4$s ou avec Klarna.\n'  -- 143$b$);
select secoto_private.mig074_patch(
  'public.secoto_devis_relances(integer)'::regprocedure,
  $a$      || E'• Ce prix est garanti jusqu''au %s.\n\n'$a$,
  $b$      || E'• Ce prix est garanti jusqu''au %6$s.\n\n'$b$);

notify pgrst, 'reload schema';
