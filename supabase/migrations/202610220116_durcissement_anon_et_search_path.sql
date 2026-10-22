-- 116 : durcissement signalé par les contrôles de sécurité Supabase (22/10/2026).
--
-- A. 12 fonctions réservées aux comptes connectés (ou à l'admin) étaient
--    appelables par le rôle « anon » via /rest/v1/rpc/. Chacune commence déjà
--    par secoto_private.assert_authenticated() ou assert_admin() : un appel
--    anonyme échoue donc déjà, rien n'était exploitable. On retire quand même
--    le droit d'exécution à anon et PUBLIC (défense en profondeur) et on
--    le réserve à authenticated et service_role.
--
--    SONT VOLONTAIREMENT LAISSÉES À « anon » (parcours sans compte, avant
--    connexion) : secoto_bareme_public, secoto_terms_public,
--    secoto_create_public_request, secoto_etape_formulaire,
--    secoto_reglement_arrivee_actif.
--
-- B. 7 petites fonctions sans search_path fixé : on le fige. Aucune ne référence
--    un autre schéma que public (vérifié sur les corps).
--
-- Réversible : grant execute on function <nom> to anon;
-- Aucun changement de comportement pour le parcours client.

do $$
declare
  r record;
begin
  for r in
    select p.oid::regprocedure as f
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname in (
        'secoto_admin_build_payout',
        'secoto_admin_devis_link',
        'secoto_admin_devis_link_quote',
        'secoto_admin_od_update_conditions',
        'secoto_admin_set_payout_status',
        'secoto_anon_quote_claim',
        'secoto_mission_accept',
        'secoto_mission_decline',
        'secoto_my_bank_account',
        'secoto_od_cancel_quote_preview',
        'secoto_register_transporter_document',
        'secoto_set_bank_account'
      )
  loop
    execute format('revoke execute on function %s from public, anon', r.f);
    execute format('grant execute on function %s to authenticated, service_role', r.f);
  end loop;

  for r in
    select p.oid::regprocedure as f
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname in (
        'secoto_esc',
        'secoto_fmt_amount',
        'secoto_fmt_date',
        'secoto_fmt_distance',
        'secoto_notifications_fill_legacy',
        'set_updated_at',
        'secoto_documents_immutable_guard'
      )
  loop
    execute format('alter function %s set search_path = public, pg_temp', r.f);
  end loop;
end
$$;
