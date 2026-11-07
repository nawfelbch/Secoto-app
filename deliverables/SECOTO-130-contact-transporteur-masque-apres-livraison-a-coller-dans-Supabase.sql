-- ============================================================================
-- SECOTO — MIGRATION 130 : NUMÉRO DU TRANSPORTEUR MASQUÉ DÈS LA LIVRAISON
-- ----------------------------------------------------------------------------
-- Demande de Nawfal du 07/11/2026 : un client qui a réglé voyait encore le
-- téléphone du transporteur (084 le laissait 48 h après la livraison). Le
-- contact direct ne sert qu'à organiser l'enlèvement et la livraison : il
-- disparaît dès que le véhicule est livré, pour que les prochaines courses
-- passent par SECOTO.
--   · commandes : coordonnées seulement en partner_confirmed et picked_up ;
--   · missions plateau : seulement tant que la mission est attribuée.
-- Le nom du transporteur reste affiché (identité légale, facture). ADDITIF,
-- rejouable.
-- ============================================================================

select secoto_private.mig074_patch(
  'secoto_private.order_client_json(public.transport_orders)'::regprocedure,
  '        and (o.status in (''partner_confirmed'', ''picked_up'') or (o.status = ''delivered'' and coalesce(',
  '        and (o.status in (''partner_confirmed'', ''picked_up'') /* 130 */ or (false and coalesce(');

create or replace function secoto_private.mission_transporter_contact(p_mission_id uuid)
returns jsonb language sql stable security definer set search_path = '' as $$
  -- 130 : plus aucun numéro une fois la mission terminée.
  select case when secoto_private.flag('mise_en_relation_v2') and m.type = 'plateau'
          and m.assigned_transporter_id is not null
          and m.client_account_id = auth.uid()
          and m.status = 'assigned'
      then secoto_private.carrier_contact_json(m.assigned_transporter_id) end
  from public.missions m where m.id = p_mission_id;
$$;
revoke all on function secoto_private.mission_transporter_contact(uuid) from public, anon;
grant execute on function secoto_private.mission_transporter_contact(uuid) to authenticated;

notify pgrst, 'reload schema';
