-- ============================================================================
-- SECOTO — MIGRATION 110 : COMPTAGE ANONYME DES ÉTAPES DU FORMULAIRE DE DEVIS
-- ----------------------------------------------------------------------------
-- Demande de Nawfal du 21/10/2026 : savoir à quelle étape les visiteurs
-- abandonnent (arrivée, trajet, véhicule, mode, dates, contact, prix,
-- réservation).
-- ANONYME : un identifiant de visite tiré au hasard dans l'onglet (sessionStorage,
-- effacé à la fermeture), jamais relié à un compte, une adresse IP, un cookie
-- ni un appareil. Aucun contenu du formulaire n'est envoyé : seulement le nom
-- de l'étape, la provenance (Google Ads / naturel / direct / autre) et le type
-- d'écran (mobile ou non). Effacé après 90 jours.
-- ADDITIF, rejouable.
-- ============================================================================

create table if not exists public.entonnoir_etapes (
  visite     uuid not null,
  etape      text not null,
  source     text not null default 'direct',
  mobile     boolean not null default false,
  connecte   boolean not null default false,
  created_at timestamptz not null default now(),
  primary key (visite, etape)
);
create index if not exists entonnoir_etapes_created_idx on public.entonnoir_etapes (created_at);
alter table public.entonnoir_etapes enable row level security;
revoke all on public.entonnoir_etapes from public, anon, authenticated;

create or replace function public.secoto_etape_formulaire(
  p_visite uuid, p_etape text, p_source text default 'direct', p_mobile boolean default false, p_connecte boolean default false)
returns void language plpgsql security definer set search_path = ''
as $f$
begin
  if p_visite is null or p_etape not in (
    'arrivee', 'trajet', 'vehicule', 'mode', 'dates', 'contact', 'prix', 'erreur_prix', 'reserver'
  ) then
    return;
  end if;
  -- Garde-fou contre un envoi en masse : au-delà, on ne compte plus pendant l'heure.
  if (select count(*) from public.entonnoir_etapes e where e.created_at > now() - interval '1 hour') > 5000 then
    return;
  end if;
  insert into public.entonnoir_etapes(visite, etape, source, mobile, connecte)
  values (p_visite, p_etape,
          case when p_source in ('ads', 'naturel', 'direct', 'autre') then p_source else 'autre' end,
          coalesce(p_mobile, false), coalesce(p_connecte, false))
  on conflict do nothing;
  if random() < 0.01 then
    delete from public.entonnoir_etapes e where e.created_at < now() - interval '90 days';
  end if;
end;
$f$;
revoke all on function public.secoto_etape_formulaire(uuid, text, text, boolean, boolean) from public;
grant execute on function public.secoto_etape_formulaire(uuid, text, text, boolean, boolean) to anon, authenticated;

-- Tableau admin : visites distinctes par étape, par jour (heure de Paris) et par provenance.
create or replace function public.secoto_admin_entonnoir(p_jours integer default 7)
returns jsonb language plpgsql stable security definer set search_path = ''
as $f$
begin
  perform secoto_private.assert_admin();
  return coalesce((
    select jsonb_agg(jsonb_build_object('jour', j.jour, 'source', j.source, 'etapes', j.etapes) order by j.jour desc, j.source)
      from (
        select c.jour, c.source, jsonb_object_agg(c.etape, c.n) as etapes
          from (
            select (x.created_at at time zone 'Europe/Paris')::date as jour, x.source, x.etape, count(*) as n
              from public.entonnoir_etapes x
             where x.created_at > now() - make_interval(days => greatest(coalesce(p_jours, 7), 1))
               and not x.connecte
             group by 1, 2, 3
          ) c
         group by 1, 2
      ) j), '[]'::jsonb);
end;
$f$;
revoke all on function public.secoto_admin_entonnoir(integer) from public, anon;
grant execute on function public.secoto_admin_entonnoir(integer) to authenticated;

notify pgrst, 'reload schema';
