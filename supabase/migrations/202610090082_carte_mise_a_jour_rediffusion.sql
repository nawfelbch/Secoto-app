-- ============================================================================
-- SECOTO 082 — Paiement direct : carte mise à jour après un débit refusé
-- ----------------------------------------------------------------------------
-- Quand le débit est refusé à l'acceptation, la proposition du transporteur
-- est close et la commande repasse « en recherche ». Si le client met ensuite
-- sa carte à jour, la demande doit repartir vers les transporteurs (y compris
-- celui dont l'acceptation a échoué : il n'y était pour rien). Sans cela,
-- personne ne voyait plus la mission.
--
-- Rediffusion seulement si plus aucune proposition n'est en cours pour cette
-- commande. Migration rejouable ; rien ne change hors paiement direct.
-- ============================================================================
select secoto_private.mig074_patch(
  'public.secoto_direct_card_saved(uuid, text, text, text)'::regprocedure,
  '        null, ''courses'', ''od-card-saved:'' || v_order.id::text, v_order.id);',
  '        null, ''courses'', ''od-card-saved:'' || v_order.id::text, v_order.id);
    elsif v_order.status = ''searching_partner''
          and not exists (select 1 from public.transport_offers x where x.order_id = v_order.id and x.status = ''sent'') then
      -- 082 : carte mise à jour après un débit refusé -> nouvelle diffusion.
      perform secoto_private.od_broadcast(v_order.id);
      v_effect := ''dispatch_reopened'';
      perform secoto_private.notify_event(v_order.account_id, ''payment'', ''Carte mise à jour'',
        format(''Commande %s : votre nouvelle carte est validée, rien n''''a été débité. Votre demande est de nouveau proposée aux transporteurs.'', v_order.public_ref),
        null, ''courses'', ''od-card-updated:'' || v_order.id::text || '':'' || coalesce(p_event_id, now()::text), v_order.id);');

notify pgrst, 'reload schema';
