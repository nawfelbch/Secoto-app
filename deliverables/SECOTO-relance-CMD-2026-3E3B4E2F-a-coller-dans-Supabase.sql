-- SECOTO — Relance du client de la commande CMD-2026-3E3B4E2F
-- (Saint-Marcel-sur-Aude → Andernos-les-Bains, Peugeot 204, plateau, 605,24 €)
-- La commande attend l'enregistrement de la carte : rien n'a encore été fait.
-- Envoie 1 e-mail + 1 notification dans l'application. Aucun paiement, aucun prélèvement.
-- Rejouable : une seule relance par jour (clé unique).

with o as (
  select o.id, o.public_ref, o.account_id, o.client_price_cents, o.pickup_at,
         q.pickup ->> 'city' as depart, q.delivery ->> 'city' as arrivee,
         coalesce(nullif(btrim(q.vehicle ->> 'model'), ''), 'votre véhicule') as vehicule,
         a.email
    from public.transport_orders o
    join public.accounts a on a.id = o.account_id
    left join public.transport_quotes q on q.id = o.quote_id
   where o.public_ref = 'CMD-2026-3E3B4E2F' and o.status = 'awaiting_payment'
), mail as (
  insert into public.email_outbox (account_id, to_email, subject, body_text, event_key)
  select o.account_id, o.email,
         format('Votre transport %s → %s est prêt à être réservé', o.depart, o.arrivee),
         format(E'Bonjour,\n\n'
           || E'Votre demande de transport %s → %s (%s, sur plateau) pour le %s est presque terminée : il ne reste qu''à enregistrer votre carte.\n\n'
           || E'• 0 € aujourd''hui : votre carte est seulement enregistrée, rien n''est prélevé.\n'
           || E'• Vous réglez %s tout compris à l''arrivée du véhicule (carte, virement, espèces ou en plusieurs fois avec Klarna, sous réserve d''acceptation).\n'
           || E'• Dès que c''est fait, votre demande part à nos transporteurs validés par SECOTO.\n\n'
           || E'Finaliser ma réservation (1 minute) :\nhttps://app.secoto-transport.fr/?ecran=courses&commande=%s\n\n'
           || E'Une question ? Répondez simplement à cet e-mail, nous vous rappelons.\n\nL''Équipe SECOTO',
           o.depart, o.arrivee, o.vehicule,
           to_char(o.pickup_at at time zone 'Europe/Paris', 'DD/MM/YYYY'),
           replace(to_char(o.client_price_cents / 100.0, 'FM999G990D00'), '.', ',') || ' €',
           o.id),
         'relance-commande:' || o.id::text || ':' || to_char(now() at time zone 'Europe/Paris', 'YYYY-MM-DD')
    from o where o.email is not null
  on conflict do nothing
  returning to_email
)
select (select to_email from mail) as email_envoye_a,
       secoto_private.notify_event(o.account_id, 'order_update', 'Finalisez votre réservation',
         format('%s → %s : enregistrez votre carte (0 € aujourd''hui), vous réglez à l''arrivée.', o.depart, o.arrivee),
         null, 'courses', 'relance-commande-app:' || o.id::text || ':' || to_char(now() at time zone 'Europe/Paris', 'YYYY-MM-DD'), o.id) as notification_id
  from o;
