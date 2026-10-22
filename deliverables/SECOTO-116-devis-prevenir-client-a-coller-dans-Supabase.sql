-- SECOTO 116 — à coller dans Supabase → SQL Editor, puis Run. Tout ou rien (begin/commit).
-- Aucun e-mail n'est envoyé à l'application de ce SQL : seulement aux prochains chiffrages.
begin;
-- ============================================================================
-- SECOTO — MIGRATION 116 : LE CLIENT EST PRÉVENU QUAND UN DEVIS EST CHIFFRÉ
-- ----------------------------------------------------------------------------
-- Constat du 22/10/2026 : chiffrer un devis n'envoyait rien au client sans
-- compte. Neuf devis « téléphone seul » (environ 6 340 €) ont expiré sans que
-- le client sache qu'un prix l'attendait ; deux devis « e-mail seul » aussi.
-- Décision de Nawfal : plutôt qu'un rappel téléphonique, un MESSAGE PRÉDÉFINI
-- (SMS ou WhatsApp depuis son téléphone) : il laisse une trace et permet
-- d'appeler juste après.
--   1. Chiffrer un devis envoie aussitôt un e-mail au client (compte ou e-mail
--      laissé), avec le lien de réservation.
--   2. Devis « téléphone seul » : l'admin prépare le message (lien de paiement
--      créé, devis expiré réactivé) et l'envoie ; chaque envoi est tracé.
--   3. « À traiter » : « à prévenir » ne compte que les devis sans message ;
--      « à chiffrer » ignore les devis dont la date d'enlèvement est passée.
--   4. Montants lisibles : « 1 054,28 € » (et non « 1,054,28 € ») dans les
--      relances et la notification admin.
-- Aucun SMS automatique : pas de fournisseur SMS, c'est l'admin qui envoie.
-- ADDITIF, rejouable.
-- ============================================================================

-- 1 054,28 € · 120 € — indépendant des réglages régionaux du serveur.
create or replace function secoto_private.euros_lisibles(p_cents bigint)
returns text language sql immutable set search_path = ''
as $f$
  select regexp_replace((abs(coalesce(p_cents, 0)) / 100)::text, '(\d)(?=(\d{3})+$)', '\1 ', 'g')
      || case when abs(coalesce(p_cents, 0)) % 100 = 0 then ''
              else ',' || lpad((abs(p_cents) % 100)::text, 2, '0') end
      || ' €';
$f$;

-- Trace des messages envoyés par l'admin au client d'un devis.
create table if not exists public.devis_messages (
  id uuid primary key default gen_random_uuid(),
  quote_id uuid not null references public.transport_quotes(id) on delete cascade,
  canal text not null check (canal in ('sms', 'whatsapp', 'appel')),
  par uuid references public.accounts(id),
  created_at timestamptz not null default now()
);
create index if not exists devis_messages_quote_idx on public.devis_messages (quote_id, created_at desc);
alter table public.devis_messages enable row level security;
revoke all on public.devis_messages from public, anon, authenticated;

-- Devis tarifé, sans compte ni e-mail : seul un message de l'admin le fait connaître.
create or replace function secoto_private.devis_telephone_seul(p_quote uuid)
returns boolean language sql stable security definer set search_path = ''
as $f$
  select exists (
    select 1 from public.transport_quotes q
     where q.id = p_quote
       and q.account_id is null and q.contact_email is null and q.contact_phone is not null
       and coalesce(q.client_price_cents, 0) > 0
       and q.status in ('priced', 'manual_priced', 'expired')
       and q.supprime_le is null
       and q.pickup_at > now()
       and q.created_at > now() - interval '10 days'
       and not exists (select 1 from public.transport_orders o where o.quote_id = q.id));
$f$;

-- ----------------------------------------------------------------------------
-- 1. E-mail au client dès le chiffrage
-- ----------------------------------------------------------------------------
create or replace function secoto_private.devis_prevenir_par_email(p_quote uuid)
returns boolean language plpgsql security definer set search_path = ''
as $f$
declare
  v_q public.transport_quotes%rowtype;
  v_email text;
  v_lien text;
  v_trajet text;
  v_prix text;
  v_tiers text;
begin
  select * into v_q from public.transport_quotes q where q.id = p_quote;
  if not found or coalesce(v_q.client_price_cents, 0) <= 0 or v_q.pickup_at <= now()
     or v_q.status not in ('priced', 'manual_priced') then
    return false;
  end if;
  select coalesce(nullif(btrim(a.email), ''), v_q.contact_email) into v_email
    from (select 1) x left join public.accounts a on a.id = v_q.account_id;
  if v_email is null then return false; end if;

  v_trajet := coalesce(v_q.pickup ->> 'city', '') || ' → ' || coalesce(v_q.delivery ->> 'city', '');
  if v_q.account_id is null then
    update public.transport_quotes
       set anon_token = coalesce(anon_token, replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', ''))
     where id = p_quote
    returning * into v_q;
    v_lien := 'https://app.secoto-transport.fr/?reprendre=' || v_q.anon_token
      || '&prix=' || v_q.client_price_cents
      || '&trajet=' || replace(replace(v_trajet, ' ', '%20'), '→', '%E2%86%92');
  else
    v_lien := 'https://app.secoto-transport.fr/';
  end if;
  v_prix := secoto_private.euros_lisibles(v_q.client_price_cents);
  v_tiers := secoto_private.euros_lisibles(ceil(v_q.client_price_cents / 3.0)::bigint);

  insert into public.email_outbox (account_id, to_email, subject, body_text, event_key)
  values (v_q.account_id, v_email,
    format('Votre devis SECOTO est prêt : %s pour %s', v_prix, v_trajet),
    format(E'Bonjour,\n\nVotre devis pour le transport %s (%s) est prêt : %s tout compris.\n\n'
      || E'• 0 € aujourd''hui : votre carte est seulement enregistrée, vous réglez à l''arrivée du véhicule.\n'
      || E'• Paiement par carte, virement%s, ou en plusieurs fois avec Klarna (par exemple 3 × %s, sous réserve d''acceptation).\n'
      || E'• Ce prix est garanti jusqu''au %s.\n\n'
      || E'Réservez en 1 minute :\n%s\n\n'
      || E'Une question ? Répondez simplement à cet e-mail.\n\nL''équipe SECOTO',
      v_trajet, coalesce(nullif(btrim(v_q.vehicle ->> 'model'), ''), 'votre véhicule'), v_prix,
      case when v_q.client_price_cents <= 100000 then ', espèces' else '' end, v_tiers,
      to_char(coalesce(v_q.valid_until, v_q.pickup_at) at time zone 'Europe/Paris', 'DD/MM/YYYY'), v_lien),
    'devis-chiffre:' || p_quote::text || ':' || v_q.client_price_cents)
  on conflict do nothing;
  return true;
exception when others then
  return false;  -- un e-mail ne bloque jamais un chiffrage
end;
$f$;

select secoto_private.mig074_patch('public.secoto_admin_price_quote(uuid,integer,integer,integer,text,boolean)'::regprocedure,
  'return to_jsonb(v_quote);',
  'return to_jsonb(v_quote) || jsonb_build_object(''email_envoye'', secoto_private.devis_prevenir_par_email(p_quote_id), ''telephone_seul'', secoto_private.devis_telephone_seul(p_quote_id));  -- 116');

-- La relance automatique ne double pas l'e-mail du chiffrage (moins de 20 h).
select secoto_private.mig074_patch('public.secoto_devis_relances(integer)'::regprocedure,
  'continue when v_etape is null;',
  'continue when v_etape is null;
    continue when exists (select 1 from public.email_outbox e2 where e2.event_key like ''devis-chiffre:'' || r.id::text || '':%'' and e2.created_at > now() - interval ''20 hours'');  -- 116');

-- Montants lisibles dans les relances.
select secoto_private.mig074_patch('public.secoto_devis_relances(integer)'::regprocedure,
  'v_prix := replace(to_char(r.client_price_cents / 100.0, ''FM999G990D00''), ''.'', '','') || '' €'';',
  'v_prix := secoto_private.euros_lisibles(r.client_price_cents);  -- 116');
select secoto_private.mig074_patch('public.secoto_devis_relances(integer)'::regprocedure,
  'v_tiers := replace(to_char(ceil(r.client_price_cents / 3.0) / 100.0, ''FM999G990D00''), ''.'', '','') || '' €'';',
  'v_tiers := secoto_private.euros_lisibles(ceil(r.client_price_cents / 3.0)::bigint);  -- 116');

-- Montants lisibles dans la notification admin (108).
select secoto_private.mig074_patch('secoto_private.admin_resume_demande(public.transport_quotes)'::regprocedure,
  'replace(to_char(q.client_price_cents / 100.0, ''FM999G990D00''), ''.'', '','') || '' €''',
  'secoto_private.euros_lisibles(q.client_price_cents)  /* 116 */');
select secoto_private.mig074_patch('secoto_private.admin_resume_demande(public.transport_quotes)'::regprocedure,
  '|| coalesce('' (marge '' || replace(to_char(q.margin_cents / 100.0, ''FM999G990''), ''.'', '','') || '' €)'', ''''),',
  '|| coalesce('' (marge '' || secoto_private.euros_lisibles(round(q.margin_cents / 100.0)::bigint * 100) || '')'', ''''),  /* 116 */');

-- ----------------------------------------------------------------------------
-- 2. Message prédéfini de l'admin (SMS, WhatsApp) et sa trace
-- ----------------------------------------------------------------------------
-- Prépare le message : réactive un devis expiré dont l'enlèvement est à venir,
-- puis crée (ou reprend) le lien de paiement.
create or replace function public.secoto_admin_devis_message_preparer(p_quote uuid)
returns jsonb language plpgsql volatile security definer set search_path = ''
as $f$
declare
  v_q public.transport_quotes%rowtype;
  v_lien jsonb;
begin
  perform secoto_private.assert_admin();
  select * into v_q from public.transport_quotes q where q.id = p_quote for update;
  if not found then raise exception 'Devis introuvable.' using errcode = 'P0002'; end if;
  if v_q.supprime_le is not null then raise exception 'Ce devis a été supprimé.'; end if;
  if v_q.pickup_at <= now() then
    raise exception 'La date d''enlèvement est passée : rechiffrez le devis avec une nouvelle date.';
  end if;
  if coalesce(v_q.client_price_cents, 0) <= 0 then raise exception 'Fixez d''abord le prix de ce devis.'; end if;
  if exists (select 1 from public.transport_orders o where o.quote_id = p_quote) then
    raise exception 'Ce devis est déjà réservé.';
  end if;
  if v_q.status = 'expired' then
    update public.transport_quotes
       set status = case when manual_reason is null then 'priced' else 'manual_priced' end,
           valid_until = least(greatest(now() + interval '72 hours', coalesce(valid_until, now())), pickup_at),
           updated_at = now()
     where id = p_quote
    returning * into v_q;
  end if;
  if v_q.status not in ('priced', 'manual_priced') then
    raise exception 'Ce devis ne peut pas être envoyé (%).', v_q.status;
  end if;
  v_lien := public.secoto_admin_devis_link_quote(p_quote, 30);
  return v_lien || jsonb_build_object('valid_until', v_q.valid_until,
    'messages', (select count(*) from public.devis_messages m where m.quote_id = p_quote));
end;
$f$;
revoke all on function public.secoto_admin_devis_message_preparer(uuid) from public, anon;
grant execute on function public.secoto_admin_devis_message_preparer(uuid) to authenticated;

-- Trace : appelée quand l'admin ouvre le SMS, WhatsApp ou l'appel.
create or replace function public.secoto_admin_devis_message_envoye(p_quote uuid, p_canal text)
returns jsonb language plpgsql volatile security definer set search_path = ''
as $f$
declare v_id uuid;
begin
  perform secoto_private.assert_admin();
  if p_canal not in ('sms', 'whatsapp', 'appel') then raise exception 'Canal inconnu.'; end if;
  if not exists (select 1 from public.transport_quotes q where q.id = p_quote) then
    raise exception 'Devis introuvable.' using errcode = 'P0002';
  end if;
  insert into public.devis_messages (quote_id, canal, par) values (p_quote, p_canal, auth.uid()) returning id into v_id;
  perform secoto_private.audit('quote_message', 'transport_quote', p_quote::text, jsonb_build_object('canal', p_canal));
  return jsonb_build_object('id', v_id, 'canal', p_canal, 'created_at', now());
end;
$f$;
revoke all on function public.secoto_admin_devis_message_envoye(uuid, text) from public, anon;
grant execute on function public.secoto_admin_devis_message_envoye(uuid, text) to authenticated;

-- Liste admin : les devis « téléphone seul » expirés mais encore utiles y
-- restent, avec la trace du dernier message.
create or replace function public.secoto_admin_quotes_actifs()
returns jsonb language plpgsql stable security definer set search_path = ''
as $f$
begin
  perform secoto_private.assert_admin();
  return coalesce((
    select jsonb_agg(t.e || jsonb_build_object(
        'telephone_seul', secoto_private.devis_telephone_seul((t.e ->> 'id')::uuid),
        'dernier_message', (select jsonb_build_object('canal', m.canal, 'le', m.created_at)
                              from public.devis_messages m where m.quote_id = (t.e ->> 'id')::uuid
                             order by m.created_at desc limit 1),
        'nb_messages', (select count(*) from public.devis_messages m where m.quote_id = (t.e ->> 'id')::uuid))
      order by t.n)
      from jsonb_array_elements(public.secoto_admin_quotes(null)) with ordinality as t(e, n)
     where t.e ->> 'status' in ('manual_review', 'manual_priced')
        or (t.e ->> 'status' = 'priced'
            and (t.e ->> 'valid_until' is null or (t.e ->> 'valid_until')::timestamptz > now()))
        or (t.e ->> 'status' = 'expired' and secoto_private.devis_telephone_seul((t.e ->> 'id')::uuid))
  ), '[]'::jsonb);
end;
$f$;

-- ----------------------------------------------------------------------------
-- 3. « À traiter »
-- ----------------------------------------------------------------------------
create or replace function public.secoto_admin_a_traiter()
returns jsonb language plpgsql stable security definer set search_path = ''
as $f$
begin
  perform secoto_private.assert_admin();
  return jsonb_build_object(
    -- 116 : sans les devis dont la date d'enlèvement est passée
    'devis_a_chiffrer', (select count(*) from public.transport_quotes q
                          where q.status = 'manual_review' and q.created_at > now() - interval '30 days'
                            and q.supprime_le is null and (q.pickup_at is null or q.pickup_at > now())),
    'commandes_sans_transporteur', (select count(*) from public.transport_orders o where o.status = 'searching_partner'),
    'reglements_en_attente', (select count(*) from public.transport_orders o join public.payments p on p.id = o.payment_id
                               where o.status = 'delivered' and p.debit_a_livraison and p.status in ('requires_capture', 'capture_failed')),
    'marges_dues', (select count(*) from public.commissions_dues c where c.statut = 'due'),
    -- 106, puis 116 : téléphone seul ET aucun message envoyé
    'devis_a_rappeler', (select count(*) from public.transport_quotes q
                          where secoto_private.devis_telephone_seul(q.id)
                            and not exists (select 1 from public.devis_messages m where m.quote_id = q.id)));
end;
$f$;
revoke all on function public.secoto_admin_a_traiter() from public, anon;
grant execute on function public.secoto_admin_a_traiter() to authenticated;

notify pgrst, 'reload schema';
commit;
