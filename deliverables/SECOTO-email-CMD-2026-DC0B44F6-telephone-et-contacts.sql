-- SECOTO — E-mail au client de la commande CMD-2026-DC0B44F6 (Serrières-en-Chautagne → Paris)
-- pour qu'il se connecte, indique son téléphone et les contacts sur place.
-- À lancer APRÈS la mise en ligne de la 115 (formulaire « Contacts sur place »).
-- Une seule fois par jour (clé unique). Aucun paiement.
insert into public.email_outbox (account_id, to_email, subject, body_text, event_key)
select o.account_id, a.email,
       'Votre transport Serrières-en-Chautagne → Paris : un transporteur est confirmé',
       E'Bonjour,\n\n'
    || E'Bonne nouvelle : un transporteur validé par SECOTO a accepté votre transport Serrières-en-Chautagne → Paris, prévu autour du 28/10.\n\n'
    || E'Pour qu''il puisse organiser l''enlèvement, il nous manque votre numéro de téléphone et les personnes à contacter sur place.\n\n'
    || E'1. Connectez-vous : https://app.secoto-transport.fr/?ecran=courses&commande=' || o.id::text || E'\n'
    || E'2. Dans votre commande, remplissez « Contacts sur place » : le téléphone à l''enlèvement et à la livraison (1 minute).\n\n'
    || E'Rappel : rien n''a été prélevé, vous réglez par carte à l''arrivée du véhicule.\n\n'
    || E'Une question ? Répondez simplement à cet e-mail.\n\nL''Équipe SECOTO',
       'contacts-commande:' || o.id::text || ':' || to_char(now() at time zone 'Europe/Paris', 'YYYY-MM-DD')
  from public.transport_orders o join public.accounts a on a.id = o.account_id
 where o.public_ref = 'CMD-2026-DC0B44F6' and a.email is not null
on conflict do nothing
returning to_email;
