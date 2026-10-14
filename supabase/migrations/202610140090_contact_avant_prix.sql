-- ============================================================================
-- SECOTO — MIGRATION 090 : CONTACT DU VISITEUR AVANT SON PRIX
-- ----------------------------------------------------------------------------
-- Décision de Nawfal du 14/10/2026 : beaucoup de visiteurs obtiennent un prix
-- puis repartent sans compte, et restent injoignables. Juste avant d'afficher
-- le prix, l'app demande un téléphone (de préférence) ou un e-mail.
--
--   1. Le devis sans compte garde ce contact (téléphone et/ou e-mail).
--   2. L'administrateur le voit sur « Devis à établir » et « Devis déjà
--      tarifés », et reçoit une notification « Nouveau contact » pour rappeler
--      vite. Le contact n'est JAMAIS visible des transporteurs.
--   3. Écriture réservée au serveur (fonction devis sans compte).
--
-- ADDITIF : trois colonnes nullables, deux fonctions nouvelles (dont l'effacement
-- des contacts après douze mois sans commande, promis aux visiteurs), une fonction
-- admin complétée par remplacement de repère. Aucune policy touchée. Rejouable.
-- ============================================================================

alter table public.transport_quotes
  add column if not exists contact_phone text,
  add column if not exists contact_email text,
  add column if not exists contact_at timestamptz;
comment on column public.transport_quotes.contact_phone is
  'Téléphone laissé par le visiteur avant son prix (090). Pour le recontacter au sujet de cette demande uniquement.';
comment on column public.transport_quotes.contact_email is
  'E-mail laissé par le visiteur avant son prix (090). Pour le recontacter au sujet de cette demande uniquement.';

-- Téléphone : chiffres seuls, « + » en tête autorisé. France : 0X XX XX XX XX
-- ou +33 X XX XX XX XX ; étranger : +indicatif, 8 à 15 chiffres.
create or replace function secoto_private.tel_propre(p text)
returns text language sql immutable set search_path = ''
as $f$
  with n as (select regexp_replace(coalesce(p, ''), '[\s.\-()/]', '', 'g') as v)
  select case
    when v ~ '^0[1-9][0-9]{8}$' then '+33' || substr(v, 2)
    when v ~ '^0033[1-9][0-9]{8}$' then '+' || substr(v, 3)
    when v ~ '^\+33[1-9][0-9]{8}$' then v
    when v ~ '^\+[1-9][0-9]{7,14}$' then v
    else null end
  from n;
$f$;

create or replace function public.secoto_devis_contact(p_quote_id uuid, p_phone text, p_email text)
returns jsonb language plpgsql volatile security definer set search_path = ''
as $f$
declare
  q public.transport_quotes%rowtype;
  v_tel text := secoto_private.tel_propre(p_phone);
  v_mail text := lower(nullif(btrim(coalesce(p_email, '')), ''));
  v_prix text;
begin
  if v_mail is not null and (length(v_mail) > 254 or v_mail !~ '^[^\s@<>]+@[^\s@<>]+\.[^\s@<>]{2,}$') then
    v_mail := null;
  end if;
  if v_tel is null and v_mail is null then
    raise exception 'Indiquez votre numéro de téléphone ou votre e-mail.';
  end if;

  select * into q from public.transport_quotes where id = p_quote_id for update;
  if not found then raise exception 'Devis introuvable.'; end if;

  update public.transport_quotes
     set contact_phone = coalesce(v_tel, contact_phone),
         contact_email = coalesce(v_mail, contact_email),
         contact_at = now()
   where id = p_quote_id;

  v_prix := case when q.client_price_cents is not null
                 then to_char(q.client_price_cents / 100.0, 'FM999990D00') || ' €'
                 else 'devis à établir' end;
  perform secoto_private.notify_admins_event('new_request', 'Nouveau contact devis',
    format('%s → %s · %s · %s · %s', q.pickup ->> 'city', q.delivery ->> 'city',
           coalesce(q.vehicle ->> 'model', 'véhicule'), v_prix, coalesce(v_tel, v_mail)),
    'requests', 'quote-contact:' || q.id::text, q.id);

  return jsonb_build_object('ok', true, 'telephone', v_tel is not null, 'email', v_mail is not null);
end;
$f$;

-- L'écran admin affiche le contact du visiteur quand il n'a pas de compte.
select secoto_private.mig074_patch(
  'public.secoto_admin_quotes(text)'::regprocedure,
  '''client_email'', a.email,',
  '''client_email'', coalesce(a.email, q.contact_email),');
select secoto_private.mig074_patch(
  'public.secoto_admin_quotes(text)'::regprocedure,
  '''client_phone'', a.phone,',
  '''client_phone'', coalesce(a.phone, q.contact_phone),');

-- Promesse de la politique de confidentialité : sans commande, le contact est
-- effacé douze mois après la demande. Appelée par la maintenance (serveur).
create or replace function public.secoto_purge_contacts_devis()
returns jsonb language plpgsql volatile security definer set search_path = ''
as $f$
declare v_n integer;
begin
  update public.transport_quotes q
     set contact_phone = null, contact_email = null
   where q.contact_at < now() - interval '12 months'
     and (q.contact_phone is not null or q.contact_email is not null)
     and not exists (select 1 from public.transport_orders o where o.quote_id = q.id);
  get diagnostics v_n = row_count;
  return jsonb_build_object('effaces', v_n);
end;
$f$;

revoke all on function secoto_private.tel_propre(text) from public, anon, authenticated;
revoke all on function public.secoto_purge_contacts_devis() from public, anon, authenticated;
grant execute on function public.secoto_purge_contacts_devis() to service_role;
revoke all on function public.secoto_devis_contact(uuid, text, text) from public, anon, authenticated;
grant execute on function public.secoto_devis_contact(uuid, text, text) to service_role;
