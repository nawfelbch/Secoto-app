-- 072 — « Paiement reçu » : l'administrateur est prévenu dès qu'un client paie.
--
-- Jusqu'ici aucune notification ne partait vers l'admin à l'encaissement d'un
-- client, alors que les notifications de VERSEMENT aux transporteurs (argent
-- qui sort) faisaient sonner la caisse. Désormais :
--   - argent qui entre (un paiement passe à « paid ») : notification
--     « Paiement reçu » avec le son de caisse ;
--   - argent qui sort (versements transporteurs) : son standard.
-- Le choix du son se fait dans send-mission-notifications.js, sur le préfixe
-- de clé d'événement « payment-received: » posé ici.
--
-- Déclencheur sur public.payments : il couvre tous les chemins d'encaissement
-- (commande en ligne, lien de devis, commission, abonnement). Une notification
-- ne doit JAMAIS empêcher d'enregistrer un paiement : toute erreur est avalée.

create or replace function secoto_private.trg_payment_received_notify()
returns trigger language plpgsql security definer set search_path = ''
as $f$
declare
  v_ref     text;
  v_trajet  text;
  v_montant text;
begin
  if new.status <> 'paid' then return new; end if;
  if tg_op = 'UPDATE' and old.status is not distinct from 'paid' then return new; end if;

  -- Référence et trajet : commande en ligne d'abord, sinon la mission.
  select o.public_ref,
         nullif(concat_ws(' → ', q.pickup ->> 'city', q.delivery ->> 'city'), '')
    into v_ref, v_trajet
    from public.transport_orders o
    left join public.transport_quotes q on q.id = o.quote_id
   where o.payment_id = new.id
   limit 1;

  if v_ref is null and new.mission_id is not null then
    select m.public_ref, nullif(concat_ws(' → ', m.from_city, m.to_city), '')
      into v_ref, v_trajet
      from public.missions m where m.id = new.mission_id;
  end if;

  v_montant := replace(to_char(new.amount_cents / 100.0, 'FM999990D00'), '.', ',') || ' €';

  perform secoto_private.notify_admins_event(
    'payment',
    'Paiement reçu',
    concat_ws(' · ', v_montant, v_ref, v_trajet,
              case when new.purpose = 'subscription_extension' then 'Abonnement' end),
    'requests',
    'payment-received:' || new.id::text,
    new.id);
  return new;
exception when others then
  return new;
end;
$f$;

drop trigger if exists trg_secoto_payment_received_notify on public.payments;
create trigger trg_secoto_payment_received_notify
  after insert or update of status on public.payments
  for each row execute function secoto_private.trg_payment_received_notify();

do $$
begin
  if not exists (select 1 from pg_trigger where tgname = 'trg_secoto_payment_received_notify') then
    raise exception 'Déclencheur « Paiement reçu » absent.';
  end if;
end $$;
