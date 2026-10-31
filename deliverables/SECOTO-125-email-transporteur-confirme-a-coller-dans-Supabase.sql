-- ============================================================================
-- SECOTO — MIGRATION 125 : E-MAIL AU CLIENT QUAND LE TRANSPORTEUR CONFIRME
-- ----------------------------------------------------------------------------
-- Demande de Nawfal du 31/10/2026 (deuxième client à le réclamer, Ferrari
-- CMD-2026-E2747D67) : quand un transporteur accepte la course, le client ne
-- recevait qu'une notification dans l'application, aucun e-mail.
--
-- Désormais, au passage de la commande en « transporteur confirmé », le client
-- reçoit un e-mail récapitulatif : trajet, date et créneau, adresses, nom et
-- téléphone du transporteur, montant et mode de règlement. Une seule fois par
-- commande (clé d'envoi unique). Une erreur ici ne bloque jamais la
-- confirmation. Commandes de test exclues. ADDITIF, rejouable.
-- ============================================================================

create or replace function secoto_private.email_transporteur_confirme_corps(p_order public.transport_orders)
returns jsonb language plpgsql stable security definer set search_path = ''
as $f$
declare
  v_quote public.transport_quotes%rowtype;
  v_payment public.payments%rowtype;
  v_email text;
  v_contact jsonb;
  v_trajet text;
  v_date text;
  v_creneau text;
  v_vehicule text;
  v_reglement text;
  v_tel text;
  v_corps text;
begin
  select * into v_quote from public.transport_quotes q where q.id = p_order.quote_id;
  if not found then return null; end if;
  select * into v_payment from public.payments p where p.id = p_order.payment_id;
  select nullif(btrim(a.email), '') into v_email from public.accounts a where a.id = p_order.account_id;
  v_email := coalesce(v_email, nullif(btrim(v_quote.contact_email), ''));
  if v_email is null then return null; end if;

  v_trajet := coalesce(v_quote.pickup ->> 'city', 'Départ') || ' → ' || coalesce(v_quote.delivery ->> 'city', 'Arrivée');
  v_date := to_char(coalesce(p_order.pickup_at, (v_quote.schedule ->> 'pickup_date')::date) at time zone 'Europe/Paris', 'DD/MM/YYYY');
  v_creneau := case v_quote.schedule ->> 'slot'
                 when 'matin' then 'matin (8 h – 12 h)'
                 when 'apres_midi' then 'après-midi (13 h – 18 h)'
                 else 'dans la journée' end;
  v_vehicule := nullif(btrim(coalesce(v_quote.vehicle ->> 'model', '')), '');

  if secoto_private.flag('mise_en_relation_v2') and p_order.assigned_partner_id is not null then
    v_contact := secoto_private.carrier_contact_json(p_order.assigned_partner_id);
  end if;
  v_tel := nullif(regexp_replace(coalesce(v_contact ->> 'phone', ''), '^0(\d)(\d{2})(\d{2})(\d{2})(\d{2})$', '0\1 \2 \3 \4 \5'), '');

  v_reglement := case
    when v_payment.status = 'paid' then 'déjà réglé. Merci !'
    when coalesce(v_payment.debit_a_livraison, false) and p_order.mode_reglement = 'klarna'
      then 'à régler à l''arrivée du véhicule avec Klarna, depuis votre commande. Rien n''a été prélevé à ce jour.'
    when coalesce(v_payment.debit_a_livraison, false) and p_order.mode_reglement = 'virement'
      then 'à régler par virement à l''arrivée du véhicule (les coordonnées vous seront envoyées à la livraison). Rien n''a été prélevé à ce jour.'
    when coalesce(v_payment.debit_a_livraison, false) and p_order.mode_reglement = 'especes'
      then 'à régler en espèces au transporteur à l''arrivée du véhicule. Rien n''est prélevé sur votre carte.'
    when coalesce(v_payment.debit_a_livraison, false)
      then 'prélevé sur votre carte enregistrée uniquement à l''arrivée du véhicule. Rien n''a été prélevé à ce jour.'
    else 'le détail du règlement est disponible dans votre espace SECOTO.' end;

  v_corps := concat_ws(E'\n',
    'Bonjour,',
    '',
    'Bonne nouvelle : un transporteur validé par SECOTO a accepté votre transport.',
    '',
    'Commande : ' || p_order.public_ref,
    'Trajet : ' || v_trajet,
    case when v_vehicule is not null then 'Véhicule : ' || v_vehicule end,
    'Date : ' || v_date || ', ' || v_creneau,
    'Enlèvement : ' || coalesce(v_quote.pickup ->> 'label', v_quote.pickup ->> 'city', ''),
    'Livraison : ' || coalesce(v_quote.delivery ->> 'label', v_quote.delivery ->> 'city', ''),
    'Transport : ' || case p_order.mode when 'convoyage' then 'convoyage (un convoyeur conduit votre véhicule)' else 'sur plateau' end,
    '',
    case when v_contact ->> 'name' is not null then 'Votre transporteur : ' || (v_contact ->> 'name') end,
    case when v_tel is not null then 'Téléphone : ' || v_tel end,
    case when v_contact ->> 'name' is not null
      then 'C''est votre interlocuteur pour l''enlèvement, le trajet et la livraison. Il vous contactera pour convenir de l''heure de passage.' end,
    case when v_contact ->> 'name' is not null then '' end,
    'Montant : ' || secoto_private.reglement_eur(p_order.client_price_cents) || ', ' || v_reglement,
    '',
    'Un état des lieux avec photos est réalisé au départ et à la livraison. Suivez votre commande dans votre espace SECOTO :',
    'https://app.secoto-transport.fr',
    '',
    'Une question ? Répondez simplement à cet e-mail ou appelez-nous au 07 83 27 82 31.',
    '',
    'L''Équipe SECOTO');

  return jsonb_build_object(
    'to', v_email,
    'subject', format('Transport confirmé : %s le %s (%s)', v_trajet, v_date, p_order.public_ref),
    'body', v_corps);
end;
$f$;
revoke all on function secoto_private.email_transporteur_confirme_corps(public.transport_orders) from public, anon, authenticated;

create or replace function secoto_private.trg_email_transporteur_confirme()
returns trigger language plpgsql security definer set search_path = ''
as $f$
declare
  v_mail jsonb;
begin
  if new.status <> 'partner_confirmed' or old.status = 'partner_confirmed' or coalesce(new.is_test, false) then
    return new;
  end if;
  v_mail := secoto_private.email_transporteur_confirme_corps(new);
  if v_mail is not null then
    insert into public.email_outbox(account_id, to_email, subject, body_text, event_key)
    values (new.account_id, v_mail ->> 'to', v_mail ->> 'subject', v_mail ->> 'body',
            'od-transporteur-confirme:' || new.id::text)
    on conflict (event_key) do nothing;
  end if;
  return new;
exception when others then
  -- La confirmation du transporteur ne doit jamais échouer à cause de l'e-mail.
  return new;
end;
$f$;
revoke all on function secoto_private.trg_email_transporteur_confirme() from public, anon, authenticated;

drop trigger if exists trg_secoto_email_transporteur_confirme on public.transport_orders;
create trigger trg_secoto_email_transporteur_confirme
  after update of status on public.transport_orders
  for each row execute function secoto_private.trg_email_transporteur_confirme();

notify pgrst, 'reload schema';
