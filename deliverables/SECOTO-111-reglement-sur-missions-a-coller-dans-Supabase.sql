-- ============================================================================
-- SECOTO — MIGRATION 111 : LE MODE DE RÈGLEMENT CHOISI SUIT LA MISSION
-- ----------------------------------------------------------------------------
-- La mission créée depuis une commande recopie le mode de règlement
-- (missions.payment_method), mais un changement fait ensuite par le client
-- (carte -> espèces, Klarna, virement) n'y était pas reporté : l'admin et le
-- transporteur pouvaient lire un mode périmé. Désormais, tout changement sur
-- la commande est reporté sur sa mission, et les missions existantes sont
-- réalignées. Rejouable. Aucun paiement touché.
-- ============================================================================

create or replace function secoto_private.trg_reglement_vers_mission()
returns trigger language plpgsql security definer set search_path = ''
as $f$
begin
  if new.mission_id is not null and new.mode_reglement is not null
     and (tg_op = 'INSERT' or new.mode_reglement is distinct from old.mode_reglement or new.mission_id is distinct from old.mission_id) then
    update public.missions m set payment_method = new.mode_reglement
     where m.id = new.mission_id and m.payment_method is distinct from new.mode_reglement;
  end if;
  return new;
end;
$f$;

drop trigger if exists trg_secoto_reglement_vers_mission on public.transport_orders;
create trigger trg_secoto_reglement_vers_mission
  after insert or update of mode_reglement, mission_id on public.transport_orders
  for each row execute function secoto_private.trg_reglement_vers_mission();

-- Missions existantes : réalignées sur leur commande.
update public.missions m set payment_method = o.mode_reglement
  from public.transport_orders o
 where o.mission_id = m.id and o.mode_reglement is not null
   and m.payment_method is distinct from o.mode_reglement;

notify pgrst, 'reload schema';
