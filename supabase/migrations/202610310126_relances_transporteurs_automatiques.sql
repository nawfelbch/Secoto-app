-- ============================================================================
-- SECOTO — MIGRATION 126 : RELANCES AUTOMATIQUES DES TRANSPORTEURS AVANT LE DÉPART
-- ----------------------------------------------------------------------------
-- Demande de Nawfal du 31/10/2026 (Saints-Geosmes → Montbéliard, sans
-- transporteur à deux jours du départ, relancée à la main) : l'application doit
-- relancer seule les transporteurs quand une mission approche de sa date sans
-- personne, pour ne plus avoir à appeler des dizaines de transporteurs.
--
-- Pour chaque mission PUBLIÉE sans transporteur attribué (hors test) :
--   · 48 h avant le départ : e-mail « une mission attend votre prix » ;
--   · 24 h avant le départ : e-mail « dernière chance ».
-- Destinataires : les transporteurs compatibles (même règle que la diffusion),
-- qui n'ont ni proposé ni refusé cette mission. Plateau : ils proposent leur
-- tarif et leur date ; convoyage : ils acceptent la date ou en proposent une.
-- Au plus un e-mail par palier, par mission et par transporteur (clé unique),
-- et jamais deux relances à moins de 12 h d'écart.
-- Envois entre 7 h et 21 h (heure de Paris) : un palier atteint la nuit part à
-- 7 h. À 24 h, si personne n'a proposé, les administrateurs sont alertés.
-- Appelée chaque minute par la maintenance (od-maintenance). ADDITIF, rejouable.
-- ============================================================================

create or replace function public.secoto_relances_transporteurs(p_limit integer default 200)
returns jsonb language plpgsql security definer set search_path = ''
as $f$
declare
  v_heure integer := extract(hour from now() at time zone 'Europe/Paris')::int;
  v_mails integer := 0;
  v_alertes integer := 0;
  r record;
begin
  if v_heure < 7 or v_heure >= 21 then
    return jsonb_build_object('mails', 0, 'alertes', 0, 'pause', 'nuit');
  end if;

  for r in
    with missions_ouvertes as (
      select m.*,
             case when m.mission_date <= now() + interval '24 hours' then 'j1' else 'j2' end as palier
        from public.missions m
       where m.status::text = 'published'
         and m.assigned_transporter_id is null
         and not coalesce(m.is_test, false)
         and m.cancelled_at is null
         and m.mission_date > now()
         and m.mission_date <= now() + interval '48 hours'
    )
    select m.id as mission_id, m.palier, m.type::text as type, m.from_city, m.to_city, m.distance_km,
           m.mission_date, m.vehicle, a.id as transporteur_id, a.email,
           coalesce(nullif(split_part(btrim(coalesce(a.full_name, '')), ' ', 1), ''), '') as prenom
      from missions_ouvertes m
      join public.accounts a on a.role::text = 'transporter' and a.deleted_at is null
                            and coalesce(a.email, '') like '%@%'
     where secoto_private.transporter_matches_mission(a.id, m.id)
       and not exists (select 1 from public.mission_applications ap where ap.mission_id = m.id and ap.transporter_id = a.id)
       and not exists (select 1 from public.mission_declines d where d.mission_id = m.id and d.partner_id = a.id)
       and not exists (select 1 from public.email_outbox e
                        where e.event_key = 'relance-auto:' || m.id::text || ':' || m.palier || ':' || a.id::text)
       -- Relancé il y a moins de 12 h (automatiquement ou à la main) : on attend.
       and not exists (select 1 from public.email_outbox e
                        where e.account_id = a.id and e.created_at > now() - interval '12 hours'
                          and (e.event_key like 'relance-auto:' || m.id::text || ':%' or e.event_key like 'relance-prix%'))
     order by m.mission_date, a.id
     limit greatest(1, least(coalesce(p_limit, 200), 1000))
  loop
    insert into public.email_outbox(account_id, to_email, subject, body_text, event_key)
    values (r.transporteur_id, r.email,
      case r.palier
        when 'j1' then format('Dernière chance : %s → %s, départ %s', r.from_city, r.to_city,
                              to_char(r.mission_date at time zone 'Europe/Paris', 'DD/MM'))
        else format('Une mission attend votre prix : %s → %s, départ %s', r.from_city, r.to_city,
                    to_char(r.mission_date at time zone 'Europe/Paris', 'DD/MM')) end,
      concat_ws(E'\n',
        'Bonjour' || case when r.prenom <> '' then ' ' || r.prenom else '' end || ',',
        '',
        case r.palier
          when 'j1' then 'Une mission part dans moins de 24 heures et attend encore un transporteur. C''est la dernière chance avant son annulation :'
          else 'Une mission part dans moins de 48 heures et attend encore un transporteur :' end,
        '',
        format('• %s → %s%s', r.from_city, r.to_city,
               case when r.distance_km is not null then ' · ' || round(r.distance_km)::text || ' km' else '' end),
        '• ' || case when r.type = 'plateau' then 'Transport sur plateau' else 'Convoyage' end
             || case when nullif(btrim(coalesce(r.vehicle, '')), '') is not null then ' · ' || btrim(r.vehicle) else '' end,
        '• Départ le ' || to_char(r.mission_date at time zone 'Europe/Paris', 'DD/MM/YYYY'),
        '',
        case when r.type = 'plateau'
          then 'Le prix affiché ne vous convient pas ? Proposez directement VOTRE tarif et votre date de disponibilité dans l''application, onglet « Missions disponibles ». Votre proposition est étudiée tout de suite.'
          else 'Acceptez la date indiquée ou proposez votre date de disponibilité dans l''application, onglet « Missions disponibles ».' end,
        '',
        'https://app.secoto-transport.fr',
        '',
        'Une question ? Appelez-nous au 07 83 27 82 31.',
        '',
        'Merci,',
        'L''Équipe SECOTO',
        '',
        'Vous recevez ce message car vous êtes transporteur partenaire SECOTO. Pour ne plus recevoir ces relances, répondez « STOP ».'),
      'relance-auto:' || r.mission_id::text || ':' || r.palier || ':' || r.transporteur_id::text)
    on conflict (event_key) do nothing;
    v_mails := v_mails + 1;
  end loop;

  -- À 24 h du départ, personne n'a proposé : SECOTO est prévenu (une fois).
  for r in
    select m.id, m.from_city, m.to_city, m.mission_date, m.public_ref
      from public.missions m
     where m.status::text = 'published' and m.assigned_transporter_id is null
       and not coalesce(m.is_test, false) and m.cancelled_at is null
       and m.mission_date > now() and m.mission_date <= now() + interval '24 hours'
       and not exists (select 1 from public.mission_applications ap where ap.mission_id = m.id)
       and not exists (select 1 from public.notifications n where n.event_key like 'relance-auto-admin:' || m.id::text || '%')
  loop
    perform secoto_private.notify_admins_event('new_request', 'Mission sans transporteur à 24 h',
      format('%s · %s → %s, départ %s : aucune proposition. Les transporteurs compatibles ont été relancés par e-mail.',
             coalesce(r.public_ref, ''), r.from_city, r.to_city, to_char(r.mission_date at time zone 'Europe/Paris', 'DD/MM HH24:MI')),
      'offre', 'relance-auto-admin:' || r.id::text, null);
    v_alertes := v_alertes + 1;
  end loop;

  return jsonb_build_object('mails', v_mails, 'alertes', v_alertes);
end;
$f$;
revoke all on function public.secoto_relances_transporteurs(integer) from public, anon, authenticated;
grant execute on function public.secoto_relances_transporteurs(integer) to service_role;

notify pgrst, 'reload schema';
