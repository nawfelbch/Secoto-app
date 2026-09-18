-- ============================================================================
-- SECOTO — CORRECTIF 033 : droits d'exécution des helpers secoto_private
-- ----------------------------------------------------------------------------
-- INCIDENT. Les migrations 030 à 032 contenaient un
--   revoke all on all functions in schema secoto_private from public, anon, authenticated;
-- qui a retiré les droits posés par les migrations 003 et 008 sur les helpers
-- appelés PAR LES POLITIQUES RLS (secoto_private.current_is_admin,
-- can_read_mission, current_role…). Ces fonctions sont évaluées avec l'identité
-- de l'utilisateur : sans droit d'exécution, PostgreSQL refuse la lecture de
-- public.accounts et de toutes les tables protégées. Symptôme observé :
-- « Session connectée, mais aucun profil SECOTO valide n'est relié à ce
-- compte » pour les clients, les transporteurs ET les administrateurs.
--
-- Ce correctif restaure EXACTEMENT les droits antérieurs à la 030, et rien de
-- plus. Il est additif, rejouable, et n'ouvre aucun nouvel accès.
-- ============================================================================

begin;

do $restore$
declare
  v_item text;
  -- fonction => rôles à qui restituer l'exécution (état d'avant la 030)
  v_grants constant text[][] := array[
    ['secoto_private.current_is_admin()', 'authenticated, public'],
    ['secoto_private."current_role"()', 'authenticated, public'],
    ['secoto_private.can_read_mission(uuid)', 'authenticated'],
    ['secoto_private.can_read_document_path(text,boolean)', 'authenticated'],
    ['secoto_private.can_write_mission_file(uuid)', 'authenticated'],
    ['secoto_private.can_upload_tracking_file(uuid)', 'authenticated, public'],
    ['secoto_private.transporter_matches_mission(uuid,uuid)', 'public'],
    ['secoto_private.current_transporter_matches_mission(uuid)', 'public'],
    ['secoto_private.claim_phone_matches(text,text)', 'public'],
    ['secoto_private.normalize_claim_email(text)', 'public'],
    ['secoto_private.normalize_claim_phone(text)', 'public'],
    ['secoto_private.safe_vehicle_category(jsonb)', 'public'],
    ['secoto_private.scan_groupages(uuid)', 'public'],
    ['secoto_private.queue_email(uuid,text,text,uuid,text)', 'public'],
    ['secoto_private.enqueue_push_outbox()', 'public'],
    ['secoto_private.prepare_notification()', 'public'],
    ['secoto_private.neutralize_removed_surcharges()', 'public'],
    ['secoto_private.trg_account_created_notify()', 'public'],
    ['secoto_private.trg_mission_delivered_notify()', 'public'],
    ['secoto_private.trg_mission_scan_groupages()', 'public'],
    -- Helper de la migration 031, appelé par les politiques Storage du bucket
    -- privé « business-private » avec l'identité de l'utilisateur.
    ['secoto_private.is_business_member(uuid,uuid)', 'authenticated']
  ];
begin
  for i in 1 .. array_length(v_grants, 1) loop
    v_item := v_grants[i][1];
    if to_regprocedure(v_item) is not null then
      execute format('grant execute on function %s to %s', v_item, v_grants[i][2]);
    else
      raise notice 'Fonction absente, ignorée : %', v_item;
    end if;
  end loop;
end
$restore$;

-- Contrôle immédiat : la lecture des comptes doit redevenir possible pour un
-- utilisateur authentifié. Si ce bloc échoue, la migration est annulée.
do $verif$
declare v_ok boolean;
begin
  select has_function_privilege('authenticated', 'secoto_private.current_is_admin()', 'execute')
     and has_function_privilege('authenticated', 'secoto_private.can_read_mission(uuid)', 'execute')
     and has_function_privilege('authenticated', 'secoto_private."current_role"()', 'execute')
    into v_ok;
  if not v_ok then
    raise exception 'Correctif 033 incomplet : les helpers RLS ne sont pas exécutables par authenticated.';
  end if;
end
$verif$;

notify pgrst, 'reload schema';
commit;
