-- ============================================================================
-- SECOTO — MIGRATION 093 : LIEN DE PAIEMENT D'UN DEVIS « SANS COMPTE »
-- ----------------------------------------------------------------------------
-- Incident du 15/10/2026 : depuis 090, la plupart des devis arrivent sans
-- compte (téléphone laissé avant le prix). Le lien de paiement envoyé par SMS
-- échouait (« Lien inutilisable ») : une commande exige un compte client.
-- Les devis de plus de 48 h tombaient aussi en « expiré » alors que le lien,
-- lui, est valable 30 jours.
--
-- Désormais, à l'ouverture du lien :
--   1. un devis encore datable est remis à son prix et gardé valable jusqu'à
--      l'échéance du lien (le prix envoyé par SMS est honoré) ;
--   2. devis sans compte : le serveur répond « compte_requis » avec le jeton
--      de reprise ; la page de paiement envoie le client sur l'app, il crée
--      son compte (ou se connecte), le devis est rattaché et l'écran de
--      paiement s'ouvre aussitôt (parcours 049 existant) ;
--   3. devis avec compte : inchangé.
--
-- ADDITIF : une seule fonction complétée par remplacement de repère. Aucune
-- policy touchée. Rejouable.
-- ============================================================================

select secoto_private.mig074_patch(
  'public.secoto_devis_link_open(text)'::regprocedure,
  'v_payment := secoto_private.od_book_for_link(v_link.quote_id);',
  '-- 093 : prix du lien honoré, et devis sans compte -> création du compte puis paiement.
      if v_quote.pickup_at > now() and v_quote.status in (''priced'', ''manual_priced'', ''expired'') then
        update public.transport_quotes
           set status = case when status = ''expired''
                             then case when manual_reason is null then ''priced'' else ''manual_priced'' end
                             else status end,
               valid_until = greatest(coalesce(valid_until, now()), v_link.expires_at),
               updated_at = now()
         where id = v_quote.id;
        select * into v_quote from public.transport_quotes q where q.id = v_link.quote_id;
      end if;
      if v_quote.account_id is null then
        if v_quote.pickup_at <= now() then
          return jsonb_build_object(''error'', ''date_depassee'');
        end if;
        if v_quote.anon_token is null then
          update public.transport_quotes
             set anon_token = replace(gen_random_uuid()::text, ''-'', '''') || replace(gen_random_uuid()::text, ''-'', '''')
           where id = v_quote.id;
          select * into v_quote from public.transport_quotes q where q.id = v_link.quote_id;
        end if;
        return jsonb_build_object(''error'', ''compte_requis'',
          ''reprendre'', v_quote.anon_token,
          ''trajet'', coalesce(v_quote.pickup ->> ''city'', '''') || '' → '' || coalesce(v_quote.delivery ->> ''city'', ''''),
          ''amount_cents'', v_quote.client_price_cents);
      end if;
      v_payment := secoto_private.od_book_for_link(v_link.quote_id);');
