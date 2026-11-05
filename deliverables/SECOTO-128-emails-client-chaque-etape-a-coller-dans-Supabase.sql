-- ============================================================================
-- SECOTO — MIGRATION 128 : UN E-MAIL AU CLIENT À CHAQUE ÉTAPE DE SA COMMANDE
-- ----------------------------------------------------------------------------
-- Demande de Nawfal du 05/11/2026 : le client doit être informé, par e-mail et
-- automatiquement, à chaque étape. Jusqu'ici il ne recevait que « transporteur
-- confirmé » (125) et la demande d'avis du lendemain de livraison.
--
-- Au changement de statut de la commande (hors test) :
--   · searching_partner (après enregistrement de la carte) : demande reçue,
--     recherche d'un transporteur en cours ;
--   · partner_confirmed : transporteur confirmé (125), désormais renvoyé si un
--     NOUVEAU transporteur reprend la course (désistement) ;
--   · picked_up : véhicule pris en charge ;
--   · delivered : véhicule livré, avec la suite du règlement selon le mode ;
--   · no_partner : aucun transporteur disponible ;
--   · cancelled : commande annulée.
-- Un e-mail par étape et par commande (clé unique). Une erreur d'e-mail ne
-- bloque jamais le changement de statut. ADDITIF, rejouable.
-- ============================================================================

-- Récapitulatif commun (trajet, date, adresses).
create or replace function secoto_private.email_client_recap(p_order public.transport_orders, p_quote public.transport_quotes)
returns text language sql stable security definer set search_path = ''
as $f$
  select concat_ws(E'\n',
    'Commande : ' || p_order.public_ref,
    'Trajet : ' || coalesce(p_quote.pickup ->> 'city', 'Départ') || ' → ' || coalesce(p_quote.delivery ->> 'city', 'Arrivée'),
    case when nullif(btrim(coalesce(p_quote.vehicle ->> 'model', '')), '') is not null then 'Véhicule : ' || btrim(p_quote.vehicle ->> 'model') end,
    'Date souhaitée : ' || to_char(coalesce(p_order.pickup_at, (p_quote.schedule ->> 'pickup_date')::date) at time zone 'Europe/Paris', 'DD/MM/YYYY'),
    'Enlèvement : ' || coalesce(p_quote.pickup ->> 'label', p_quote.pickup ->> 'city', ''),
    'Livraison : ' || coalesce(p_quote.delivery ->> 'label', p_quote.delivery ->> 'city', ''),
    'Montant : ' || secoto_private.reglement_eur(p_order.client_price_cents));
$f$;
revoke all on function secoto_private.email_client_recap(public.transport_orders, public.transport_quotes) from public, anon, authenticated;

-- Contenu de l'e-mail d'une étape (null : pas d'e-mail pour ce passage).
create or replace function secoto_private.email_client_etape(p_order public.transport_orders, p_etape text)
returns jsonb language plpgsql stable security definer set search_path = ''
as $f$
declare
  v_quote public.transport_quotes%rowtype;
  v_payment public.payments%rowtype;
  v_email text;
  v_trajet text;
  v_recap text;
  v_contact jsonb;
  v_sujet text;
  v_corps text;
  v_suite text;
begin
  select * into v_quote from public.transport_quotes q where q.id = p_order.quote_id;
  if not found then return null; end if;
  select * into v_payment from public.payments p where p.id = p_order.payment_id;
  select nullif(btrim(a.email), '') into v_email from public.accounts a where a.id = p_order.account_id;
  v_email := coalesce(v_email, nullif(btrim(v_quote.contact_email), ''));
  if v_email is null then return null; end if;

  v_trajet := coalesce(v_quote.pickup ->> 'city', 'Départ') || ' → ' || coalesce(v_quote.delivery ->> 'city', 'Arrivée');
  v_recap := secoto_private.email_client_recap(p_order, v_quote);
  if secoto_private.flag('mise_en_relation_v2') and p_order.assigned_partner_id is not null then
    v_contact := secoto_private.carrier_contact_json(p_order.assigned_partner_id);
  end if;

  if p_etape = 'searching_partner' then
    v_sujet := format('Demande reçue : %s (%s)', v_trajet, p_order.public_ref);
    v_corps := concat_ws(E'\n',
      'Bonjour,', '',
      'Merci, votre demande de transport est bien enregistrée. Elle vient d''être proposée aux transporteurs validés par SECOTO.', '',
      v_recap, '',
      case when coalesce(v_payment.debit_a_livraison, false)
        then 'Rien n''est prélevé aujourd''hui : vous ne payez qu''à l''arrivée du véhicule.'
        else 'Le détail du règlement est disponible dans votre espace SECOTO.' end,
      'Dès qu''un transporteur accepte, vous recevez un e-mail avec son nom et son téléphone.');
  elsif p_etape = 'picked_up' then
    v_sujet := format('Votre véhicule est en route : %s (%s)', v_trajet, p_order.public_ref);
    v_corps := concat_ws(E'\n',
      'Bonjour,', '',
      'Votre véhicule vient d''être pris en charge par le transporteur. L''état des lieux de départ, avec photos, est disponible dans votre espace SECOTO.', '',
      v_recap,
      case when v_contact ->> 'name' is not null then 'Transporteur : ' || (v_contact ->> 'name')
        || coalesce(' · ' || nullif(regexp_replace(coalesce(v_contact ->> 'phone', ''), '^0(\d)(\d{2})(\d{2})(\d{2})(\d{2})$', '0\1 \2 \3 \4 \5'), ''), '') end, '',
      'Le transporteur prévient la personne présente à la livraison pour convenir de l''heure d''arrivée.');
  elsif p_etape = 'delivered' then
    v_suite := case
      when v_payment.status = 'paid' then 'Votre règlement est déjà effectué. Merci !'
      when coalesce(v_payment.debit_a_livraison, false) and p_order.mode_reglement = 'klarna'
        then 'Réglez maintenant avec Klarna depuis votre commande (bouton « Payer maintenant »). Sans paiement sous 24 h, la carte enregistrée sera prélevée.'
      when coalesce(v_payment.debit_a_livraison, false) and p_order.mode_reglement = 'virement'
        then 'Les coordonnées du virement vous sont envoyées dans un e-mail séparé. Sans virement reçu sous 48 h, la carte enregistrée sera prélevée.'
      when coalesce(v_payment.debit_a_livraison, false) and p_order.mode_reglement = 'especes'
        then 'Le règlement se fait en espèces auprès du transporteur. Rien n''est prélevé sur votre carte.'
      when coalesce(v_payment.debit_a_livraison, false)
        then 'Le montant est prélevé sur votre carte enregistrée. Votre facture vous est envoyée dès le paiement.'
      else 'Le détail du règlement est disponible dans votre espace SECOTO.' end;
    v_sujet := format('Votre véhicule est arrivé : %s (%s)', v_trajet, p_order.public_ref);
    v_corps := concat_ws(E'\n',
      'Bonjour,', '',
      'Votre véhicule est bien arrivé à destination. L''état des lieux de livraison, avec photos, est disponible dans votre espace SECOTO.', '',
      v_recap, '',
      v_suite, '',
      'Merci pour votre confiance !');
  elsif p_etape = 'no_partner' then
    v_sujet := format('Aucun transporteur disponible : %s (%s)', v_trajet, p_order.public_ref);
    v_corps := concat_ws(E'\n',
      'Bonjour,', '',
      'Malgré notre recherche, aucun transporteur n''a pu prendre votre transport dans le délai prévu. Votre demande est donc close.', '',
      v_recap, '',
      case when coalesce(v_payment.debit_a_livraison, false)
        then 'Aucun montant ne vous a été prélevé.'
        else 'Si un montant a été réglé, il vous est intégralement remboursé.' end,
      'Vous souhaitez une autre date ? Répondez simplement à cet e-mail, nous relançons la recherche avec vous.');
  elsif p_etape = 'cancelled' then
    v_sujet := format('Commande annulée : %s (%s)', v_trajet, p_order.public_ref);
    v_corps := concat_ws(E'\n',
      'Bonjour,', '',
      'Votre commande a été annulée.', '',
      v_recap, '',
      'Le détail (montant éventuellement retenu ou remboursé) est disponible dans votre espace SECOTO.',
      'Vous souhaitez reprogrammer ce transport ? Répondez simplement à cet e-mail.');
  else
    return null;
  end if;

  v_corps := concat_ws(E'\n', v_corps, '',
    'Suivez votre commande dans votre espace SECOTO :', 'https://app.secoto-transport.fr', '',
    'Une question ? Répondez simplement à cet e-mail ou appelez-nous au 07 83 27 82 31.', '',
    'L''Équipe SECOTO');
  return jsonb_build_object('to', v_email, 'subject', v_sujet, 'body', v_corps);
end;
$f$;
revoke all on function secoto_private.email_client_etape(public.transport_orders, text) from public, anon, authenticated;

create or replace function secoto_private.trg_email_client_etapes()
returns trigger language plpgsql security definer set search_path = ''
as $f$
declare
  v_mail jsonb;
begin
  if new.status = old.status or coalesce(new.is_test, false)
     or new.status not in ('searching_partner', 'picked_up', 'delivered', 'no_partner', 'cancelled') then
    return new;
  end if;
  -- « Demande reçue » seulement à la réservation (pas lors d'une remise en recherche).
  if new.status = 'searching_partner' and old.status <> 'awaiting_payment' then return new; end if;
  v_mail := secoto_private.email_client_etape(new, new.status);
  if v_mail is not null then
    insert into public.email_outbox(account_id, to_email, subject, body_text, event_key)
    values (new.account_id, v_mail ->> 'to', v_mail ->> 'subject', v_mail ->> 'body',
            'od-etape:' || new.status || ':' || new.id::text)
    on conflict (event_key) do nothing;
  end if;
  return new;
exception when others then
  -- Le changement de statut ne doit jamais échouer à cause de l'e-mail.
  return new;
end;
$f$;
revoke all on function secoto_private.trg_email_client_etapes() from public, anon, authenticated;

drop trigger if exists trg_secoto_email_client_etapes on public.transport_orders;
create trigger trg_secoto_email_client_etapes
  after update of status on public.transport_orders
  for each row execute function secoto_private.trg_email_client_etapes();

-- 125 : un NOUVEAU transporteur (après un désistement) déclenche un nouvel
-- e-mail « transporteur confirmé » ; le même transporteur, jamais deux fois.
create or replace function secoto_private.trg_email_transporteur_confirme()
returns trigger language plpgsql security definer set search_path = ''
as $f$
declare
  v_mail jsonb;
  v_deja boolean;
begin
  if new.status <> 'partner_confirmed' or old.status = 'partner_confirmed' or coalesce(new.is_test, false) then
    return new;
  end if;
  v_mail := secoto_private.email_transporteur_confirme_corps(new);
  if v_mail is not null then
    select exists (select 1 from public.email_outbox e where e.event_key like 'od-transporteur-confirme%:' || new.id::text || '%') into v_deja;
    insert into public.email_outbox(account_id, to_email, subject, body_text, event_key)
    values (new.account_id, v_mail ->> 'to',
            case when v_deja then 'Nouveau transporteur : ' || (v_mail ->> 'subject') else v_mail ->> 'subject' end,
            case when v_deja then replace(v_mail ->> 'body',
                   'Bonne nouvelle : un transporteur validé par SECOTO a accepté votre transport.',
                   'Bonne nouvelle : un nouveau transporteur validé par SECOTO a accepté votre transport. Il remplace celui annoncé dans notre précédent e-mail.')
                 else v_mail ->> 'body' end,
            'od-transporteur-confirme:' || new.id::text || ':' || coalesce(new.assigned_partner_id::text, ''))
    on conflict (event_key) do nothing;
  end if;
  return new;
exception when others then
  return new;
end;
$f$;

notify pgrst, 'reload schema';
