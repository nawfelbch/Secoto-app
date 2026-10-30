-- ============================================================================
-- SECOTO — MIGRATION 120 : COURSE DE L'APP RÉGLÉE HORS APPLICATION = SA MARGE
-- ----------------------------------------------------------------------------
-- Incident du 28/10/2026 (MIS-2026-D9F82590, Lux → Ambérieu-en-Bugey) : course
-- commandée dans l'app, réglée par virement hors application (150,84 €, dont
-- 125,70 € reversés au transporteur). La déclaration URSSAF comptait 150,84 €
-- de commission au lieu de 25,14 €, et « Commissions en espèces à encaisser »
-- affichait aussi 150,84 €.
--
-- Cause : pour une course issue d'une commande (transport_orders.mission_id), la
-- colonne commission_amount vaut le prix complet payé par le client (SECOTO
-- encaisse tout puis verse le transporteur). Seule la marge est à SECOTO.
--   1. Déclaration / tableau de bord : pour ces courses, ligne « hors
--      application » = encaissé (total client) − transporteur = marge.
--   2. « Commissions en espèces à encaisser » : la marge, pas le total.
--   3. Les commandes de l'app en espèces ont leur propre suivi (commissions_dues,
--      100) : l'ancien marquage « commission espèces due » sur la mission ne
--      s'applique plus à elles (sinon relance du transporteur pour le total).
-- Les missions créées à la main (sans commande) ne changent pas. ADDITIF, rejouable.
-- ============================================================================

-- 1. Déclaration et tableau de bord : encaissé, part transporteur, marge.
select secoto_private.mig074_patch('secoto_private.dirigeant_lignes()'::regprocedure,
  'round(coalesce(nullif(m.commission_amount, 0), m.margin, 0) * 100)::bigint, 0::bigint, 0::bigint,',
  'round(case when exists (select 1 from public.transport_orders o where o.mission_id = m.id) then coalesce(m.client_total_due, m.client_price, 0) else coalesce(nullif(m.commission_amount, 0), m.margin, 0) end * 100)::bigint, 0::bigint, case when exists (select 1 from public.transport_orders o where o.mission_id = m.id) then round(coalesce(m.carrier_pay, 0) * 100)::bigint else 0::bigint end,  -- 120');
select secoto_private.mig074_patch('secoto_private.dirigeant_lignes()'::regprocedure,
  'round(coalesce(nullif(m.commission_amount, 0), m.margin, 0) * 100)::bigint',
  'round(case when exists (select 1 from public.transport_orders o where o.mission_id = m.id) then coalesce(m.margin, 0) else coalesce(nullif(m.commission_amount, 0), m.margin, 0) end * 100)::bigint  -- 120');

-- 2. « Commissions en espèces à encaisser » : la marge.
select secoto_private.mig074_patch('public.secoto_dirigeant_tableau(integer)'::regprocedure,
  'sum(round(coalesce(nullif(m.commission_amount, 0), m.margin, 0) * 100))',
  'sum(round(case when exists (select 1 from public.transport_orders o where o.mission_id = m.id) then coalesce(m.margin, 0) else coalesce(nullif(m.commission_amount, 0), m.margin, 0) end * 100))  /* 120 */');
select secoto_private.mig074_patch('public.secoto_dirigeant_tableau(integer)'::regprocedure,
  '''montant_cents'', round(coalesce(nullif(m.commission_amount, 0), m.margin, 0) * 100)::bigint,',
  '''montant_cents'', round(case when exists (select 1 from public.transport_orders o where o.mission_id = m.id) then coalesce(m.margin, 0) else coalesce(nullif(m.commission_amount, 0), m.margin, 0) end * 100)::bigint,  -- 120');

-- 3. Commandes de l'app : suivi par commissions_dues uniquement.
select secoto_private.mig074_patch('secoto_private.trg_commission_especes_due()'::regprocedure,
  'if new.type::text <> ''plateau'' then return new; end if;',
  'if new.type::text <> ''plateau'' then return new; end if;
  if exists (select 1 from public.transport_orders o where o.mission_id = new.id) then return new; end if;  -- 120 : suivi par commissions_dues');

notify pgrst, 'reload schema';
