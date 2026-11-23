-- ============================================================================
-- SECOTO 158 — Convoyage : « carburant et péages remboursés » dit clairement
-- aux convoyeurs (décision de Nawfal, 23/11/2026)
-- ----------------------------------------------------------------------------
-- Constat (CMD-2026-FAFD6550) : la notification / l'e-mail de mission ne
-- disait pas que le carburant et les péages sont à la charge de SECOTO, seule
-- la fiche de l'offre le mentionnait. Un convoyeur voyant « 158,35 € » pouvait
-- croire devoir les payer. Ajout de la mention :
--   · diffusion d'une mission de convoyage (od_broadcast) ;
--   · diffusion complémentaire (od_completer_diffusion) ;
--   · relance e-mail 12 h (secoto_automatisation_tick, 152).
-- Plateau inchangé (péages et carburant compris dans la rémunération).
-- ============================================================================

select secoto_private.mig074_patch(
  'secoto_private.od_broadcast(uuid)'::regprocedure,
  $a$'FM990D00'), '.', ',')),$a$,
  $b$'FM990D00'), '.', ','))
          || case when v_order.mode = 'convoyage'
                  then ' · Carburant et péages remboursés par SECOTO en plus (justificatifs, onglet « Mes frais »)' else '' end,  -- 158$b$);

select secoto_private.mig074_patch(
  'secoto_private.od_completer_diffusion(uuid)'::regprocedure,
  $a$          to_char(v_order.partner_pay_cents / 100.0, 'FM999990D00')),$a$,
  $b$          to_char(v_order.partner_pay_cents / 100.0, 'FM999990D00'))
          || case when v_order.mode = 'convoyage'
                  then ' · Carburant et péages remboursés par SECOTO en plus (justificatifs, onglet « Mes frais »)' else '' end,  -- 158$b$);

select secoto_private.mig074_patch(
  'public.secoto_automatisation_tick()'::regprocedure,
  $a$              'Acceptez-la dans l''application, onglet « Missions disponibles » :', 'https://app.secoto-transport.fr', '',$a$,
  $b$              case when o.mode = 'convoyage' then 'Le carburant et les péages ne sont pas à votre charge : ils vous sont remboursés intégralement par SECOTO, en plus de votre rémunération, sur justificatifs (onglet « Mes frais »).' end,  -- 158
              case when o.mode = 'convoyage' then '' end,
              'Acceptez-la dans l''application, onglet « Missions disponibles » :', 'https://app.secoto-transport.fr', '',$b$);
