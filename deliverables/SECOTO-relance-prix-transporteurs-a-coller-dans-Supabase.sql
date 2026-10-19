-- ============================================================================
-- SECOTO — E-mail aux transporteurs : « venez donner votre prix »
-- ----------------------------------------------------------------------------
-- Cible : chaque transporteur validé, compatible avec au moins une mission
-- publiée SANS transporteur attribué, qui n'a pas encore fait de proposition.
-- Un seul e-mail par transporteur, listant ses missions. Rejouable : un
-- transporteur déjà relancé aujourd'hui ne reçoit rien de plus (clé unique).
--
-- ÉTAPE 1 : exécutez tel quel → APERÇU (rien n'est envoyé).
-- ÉTAPE 2 : remplacez  'apercu'  par  'envoi'  (ligne « mode ») et exécutez.
-- ============================================================================
with parametres as (select 'apercu'::text as mode),
missions_ouvertes as (
  select m.* from public.missions m
   where m.status = 'published' and m.assigned_transporter_id is null
),
cibles as (
  select a.id, a.email, coalesce(nullif(split_part(btrim(a.full_name), ' ', 1), ''), 'Bonjour') as prenom,
         string_agg(
           format('• %s → %s · %s%s%s%s', m.from_city, m.to_city,
                  case when m.type = 'plateau' then 'plateau' else 'convoyage' end,
                  case when m.distance_km is not null then ' · ' || m.distance_km || ' km' else '' end,
                  case when m.mission_date is not null then ' · ' || to_char(m.mission_date at time zone 'Europe/Paris', 'DD/MM') else '' end,
                  case when m.urgent then ' · URGENT' else '' end),
           E'\n' order by m.urgent desc, m.mission_date nulls last) as liste,
         count(*) as nb,
         bool_or(m.type = 'plateau') as a_plateau
    from public.accounts a
    join missions_ouvertes m on secoto_private.transporter_matches_mission(a.id, m.id)
   where a.role = 'transporter' and a.deleted_at is null and coalesce(a.email, '') like '%@%'
     and not exists (select 1 from public.mission_applications ap where ap.mission_id = m.id and ap.transporter_id = a.id)
     and not exists (select 1 from public.mission_declines d where d.mission_id = m.id and d.partner_id = a.id)
   group by a.id, a.email, a.full_name
),
messages as (
  select c.*,
    case when c.nb > 1 then format('SECOTO — %s missions attendent votre prix', c.nb)
         else 'SECOTO — une mission attend votre prix' end as objet,
    format(E'Bonjour %s,\n\n%s sur SECOTO correspond%s à votre activité :\n\n%s\n\n%s\n\nOuvrez l''application, onglet « Missions disponibles » :\nhttps://app.secoto-transport.fr\n\nLes premières propositions reçues sont étudiées en premier.\n\nMerci,\nL''équipe SECOTO\n\nVous recevez ce message car vous êtes transporteur partenaire SECOTO. Pour ne plus recevoir ces relances, répondez « STOP ».',
      c.prenom,
      case when c.nb > 1 then format('%s missions publiées', c.nb) else 'Une mission publiée' end,
      case when c.nb > 1 then 'ent' else '' end,
      c.liste,
      case when c.a_plateau
        then 'Plateau : indiquez votre prix et votre date de disponibilité (un seul prix, une seule date, modifiables tant que SECOTO n''a pas attribué). Convoyage : acceptez la date ou proposez-en une autre.'
        else 'Acceptez la date indiquée ou proposez votre date de disponibilité.' end) as corps,
    'relance-prix:' || to_char(now() at time zone 'Europe/Paris', 'YYYY-MM-DD') || ':' || c.id::text as cle
  from cibles c
),
envoi as (
  insert into public.email_outbox (account_id, to_email, subject, body_text, event_key)
  select m.id, m.email, m.objet, m.corps, m.cle
    from messages m, parametres p
   where p.mode = 'envoi'
     and not exists (select 1 from public.email_outbox e where e.event_key = m.cle)
  returning to_email
)
select m.email as destinataire, m.nb as missions, m.objet,
       case when (select mode from parametres) = 'envoi'
            then case when exists (select 1 from envoi e where e.to_email = m.email) then 'mis en file d''envoi' else 'déjà relancé aujourd''hui' end
            else 'aperçu — rien n''est envoyé' end as statut,
       m.corps as message
  from messages m order by m.nb desc, m.email;
