-- ============================================================================
-- SECOTO — Correctif « la course terminee ne remonte pas »
-- ----------------------------------------------------------------------------
-- A coller dans Supabase > SQL Editor > Run. Idempotent.
--
-- LA CAUSE
-- Quand le transporteur validait la livraison, l'application tentait de mettre
-- a jour la mission (progress_status / status). Mais SEUL l'administrateur a le
-- droit d'ecrire dans public.missions : la mise a jour ne modifiait donc AUCUNE
-- ligne — et sans lever d'erreur. Le transporteur voyait « Livraison validee »,
-- alors que la mission restait « en attente de prise en charge » pour le client
-- comme pour l'admin.
--
-- LA CORRECTION
-- L'avancement est desormais applique par la BASE, au moment ou l'etat des
-- lieux est enregistre. Plus aucun droit d'ecriture n'est ouvert au
-- transporteur sur les missions (les prix restent intouchables).
-- ============================================================================

create or replace function public.secoto_trg_tracking_apply()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_progress text;
begin
  v_progress := case new.event_type::text
                  when 'pickup_inspection'   then 'pickup_completed'
                  when 'road_incident'       then 'incident_reported'
                  when 'delivery_inspection' then 'delivery_completed'
                  else null
                end;
  if v_progress is null then return new; end if;

  -- SQL construit dynamiquement : les valeurs sont passees en litteraux, ce qui
  -- les convertit automatiquement vers le type reel de la colonne (texte OU
  -- enumeration selon les bases). Securite : le filtre impose que ce soit bien
  -- le transporteur attribue a la mission.
  begin
    execute format(
      'update public.missions set progress_status = %L, last_tracking_event_at = now()
         where id = %L and assigned_transporter_id = %L',
      v_progress, new.mission_id, new.transporter_id);
  exception when others then
    -- Base sans colonne last_tracking_event_at : on applique sans elle.
    begin
      execute format(
        'update public.missions set progress_status = %L
           where id = %L and assigned_transporter_id = %L',
        v_progress, new.mission_id, new.transporter_id);
    exception when others then null;
    end;
  end;

  if new.event_type::text = 'delivery_inspection' then
    begin
      execute format(
        'update public.missions set status = %L
           where id = %L and assigned_transporter_id = %L',
        'completed', new.mission_id, new.transporter_id);
    exception when others then null;
    end;
  end if;

  return new;
end $$;

drop trigger if exists trg_secoto_tracking_apply on public.mission_tracking_events;
create trigger trg_secoto_tracking_apply
  after insert on public.mission_tracking_events
  for each row execute function public.secoto_trg_tracking_apply();

-- ----------------------------------------------------------------------------
-- RATTRAPAGE : missions deja livrees mais restees « attribuees ».
-- ----------------------------------------------------------------------------
update public.missions m
   set progress_status = 'delivery_completed',
       status          = 'completed'
where m.status::text = 'assigned'
  and exists (
    select 1 from public.mission_tracking_events e
    where e.mission_id = m.id and e.event_type::text = 'delivery_inspection'
  );

update public.missions m
   set progress_status = 'pickup_completed'
where coalesce(m.progress_status::text, '') in ('', 'assigned_pending')
  and m.status::text = 'assigned'
  and exists (
    select 1 from public.mission_tracking_events e
    where e.mission_id = m.id and e.event_type::text = 'pickup_inspection'
  );

-- ----------------------------------------------------------------------------
-- VERIFICATION
-- ----------------------------------------------------------------------------
select m.public_ref as mission,
       m.status     as statut,
       m.progress_status as avancement,
       (select count(*) from public.mission_tracking_events e where e.mission_id = m.id) as etapes
from public.missions m
where m.assigned_transporter_id is not null
order by m.created_at desc
limit 20;

notify pgrst, 'reload schema';
