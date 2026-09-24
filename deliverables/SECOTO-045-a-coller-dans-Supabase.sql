-- ============================================================================
-- SECOTO — MIGRATION 045 : ATTENDRE LES FONDS N'EST PAS UN ECHEC
-- ----------------------------------------------------------------------------
-- Stripe ne libere les fonds d'un paiement par carte que 3 jours ouvres apres
-- l'encaissement (delai accelere ; 7 jours en standard). Or SECOTO verse le
-- transporteur 48 h apres la livraison : quand la course est rapide, le
-- transfert part AVANT que l'argent soit disponible.
--
-- Les versements issus d'une commande portent la charge d'origine
-- (source_transaction) : Stripe les accepte et les reglera a la liberation des
-- fonds. Mais une indemnite d'annulation tardive, elle, n'a pas de charge
-- rattachee : Stripe repond « balance_insufficient ». Avec la regle d'origine,
-- cinq essais en douze heures suffisaient a marquer DEFINITIVEMENT en echec un
-- versement parfaitement legitime, qu'il fallait ensuite payer a la main.
--
-- Attendre des fonds n'est pas un echec : on repasse toutes les six heures,
-- sans consommer d'essai. Au-dela de dix jours apres l'echeance, l'admin est
-- prevenu : la, il se passe vraiment autre chose.
-- ============================================================================

do $patch$
declare
  v_src text;
  v_ancre text := '  if v.attempt_count >= v_max then';
  v_ajout text;
begin
  select pg_get_functiondef(p.oid) into v_src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'secoto_payout_transfer_result';

  if v_src is null then
    raise exception 'secoto_payout_transfer_result absente : appliquez d''abord la migration 036.';
  end if;
  if position('attente_de_fonds' in v_src) > 0 then
    raise notice 'Attente de fonds deja prise en compte.';
    return;
  end if;
  if position(v_ancre in v_src) = 0 then
    raise exception 'Point d''insertion introuvable dans secoto_payout_transfer_result.';
  end if;

  v_ajout :=
    '  -- Fonds pas encore liberes par Stripe : on patiente au lieu d''echouer.' || chr(10) ||
    '  if coalesce(p_error, '''') ~* ''balance_insufficient|insufficient (available )?funds'' then' || chr(10) ||
    '    if coalesce(v.due_at, now()) < now() - interval ''10 days'' then' || chr(10) ||
    '      update public.partner_payouts' || chr(10) ||
    '         set status = ''failed'', processing_at = null,' || chr(10) ||
    '             last_error = left(coalesce(p_error, ''solde indisponible''), 500)' || chr(10) ||
    '       where id = p_payout_id;' || chr(10) ||
    '      perform secoto_private.notify_admins_event(''payment'', ''Versement bloque faute de solde'',' || chr(10) ||
    '        format(''%s : %s € attendent depuis plus de dix jours. Approvisionnez le compte Stripe ou reglez a la main.'',' || chr(10) ||
    '          coalesce(v_ref, p_payout_id::text),' || chr(10) ||
    '          replace(to_char(v.amount_cents / 100.0, ''FM999990D00''), ''.'', '','')),' || chr(10) ||
    '        ''paiement'', ''payout-sans-solde:'' || p_payout_id::text, p_payout_id);' || chr(10) ||
    '      return jsonb_build_object(''result'', ''failed'', ''raison'', ''attente_de_fonds_trop_longue'');' || chr(10) ||
    '    end if;' || chr(10) ||
    '    update public.partner_payouts' || chr(10) ||
    '       set status = ''to_pay'', processing_at = null,' || chr(10) ||
    '           attempt_count = greatest(coalesce(attempt_count, 1) - 1, 0),' || chr(10) ||
    '           last_error = left(coalesce(p_error, ''solde indisponible''), 500),' || chr(10) ||
    '           next_retry_at = now() + interval ''6 hours''' || chr(10) ||
    '     where id = p_payout_id;' || chr(10) ||
    '    return jsonb_build_object(''result'', ''attente_de_fonds'');' || chr(10) ||
    '  end if;' || chr(10) || chr(10);

  execute replace(v_src, v_ancre, v_ajout || v_ancre);
  raise notice 'Attente de fonds prise en compte.';
end;
$patch$;

notify pgrst, 'reload schema';
