-- ============================================================================
-- SECOTO — MIGRATION 119 : ESPÈCES — LE TRANSPORTEUR VOIT LE TOTAL À ENCAISSER
-- ----------------------------------------------------------------------------
-- Incident du 28/10/2026 (Lux → Ambérieu-en-Bugey) : sur une course réglée en
-- espèces, le transporteur ne voyait dans « Mes missions » que sa propre
-- rémunération (125,70 €), pas le total à encaisser auprès du client
-- (150,84 €). Il n'a pas pu réclamer le bon montant à l'enlèvement.
--
-- La vue transporteur gagne une colonne « especes_a_encaisser » (dernière
-- colonne, rien d'autre ne change) : le total que le client règle en espèces,
-- et UNIQUEMENT quand la course est réglée en espèces (sinon null : le prix
-- client reste invisible pour le transporteur). L'application affiche ce
-- total en grand, puis le détail : sa part et la part SECOTO à reverser.
-- Même montant que l'offre (offer_partner_json, 100) : prix client de la
-- commande, sinon total dû de la mission.
-- ADDITIF, rejouable.
-- ============================================================================

do $vue$
declare
  v_def text;
begin
  if to_regclass('public.secoto_missions_transporter_v2') is null then return; end if;
  v_def := pg_get_viewdef('public.secoto_missions_transporter_v2'::regclass);
  if v_def ~ '\mespeces_a_encaisser\M' then return; end if;
  -- Premier « FROM missions m » : la requête principale (cf. 101).
  v_def := regexp_replace(v_def, '\s+FROM\s+(public\.)?missions\s+m\M',
    ', (CASE WHEN coalesce((SELECT o.mode_reglement FROM public.transport_orders o WHERE o.id = m.od_order_id), m.payment_method) = ''especes''
         THEN coalesce((SELECT o.client_price_cents / 100.0 FROM public.transport_orders o WHERE o.id = m.od_order_id), m.client_total_due, m.client_price)
       END)::numeric(12,2) AS especes_a_encaisser FROM public.missions m');
  if v_def !~ 'especes_a_encaisser FROM public\.missions m' then
    raise exception 'Vue secoto_missions_transporter_v2 : structure inattendue, migration interrompue.';
  end if;
  execute format('create or replace view public.secoto_missions_transporter_v2 with (security_barrier = true, security_invoker = false) as %s', v_def);
end
$vue$;

notify pgrst, 'reload schema';
