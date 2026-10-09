-- ============================================================================
-- SECOTO — MIGRATION 088 : MESURE DE L'ACQUISITION, DONNÉES DE TEST, RÉSEAU
-- ----------------------------------------------------------------------------
-- Décisions de Nawfal du 9-10/10/2026.
--   1. Provenance (utm_*, gclid, fbclid) conservée sur les devis, les comptes
--      clients et les commandes ; recopiée du devis vers la commande.
--   2. Consentement publicitaire du visiteur conservé : AUCUNE donnée n'est
--      transmise à Meta ou Google sans lui.
--   3. Commande payée -> une ligne « conversion » (valeur = commission SECOTO),
--      envoyée par le serveur (API Conversions Meta, import Google Ads par gclid).
--   4. is_test sur missions et commandes : exclues de tous les chiffres.
--   5. is_internal sur les comptes SECOTO : exclus des statistiques du réseau.
--   6. Couverture transporteur : départements + moto, confirmés par chacun.
--
-- ADDITIF : colonnes nullables ou à valeur par défaut, tables et fonctions
-- nouvelles, déclencheurs nouveaux. Les fonctions 087 (espace dirigeant) sont
-- réécrites à l'identique, avec en plus l'exclusion des données de test.
-- Aucune policy touchée. Un déclencheur de mesure ne peut JAMAIS faire échouer
-- un paiement ni une commande (erreur avalée et journalisée).
-- ============================================================================

-- 1. Colonnes de provenance --------------------------------------------------
alter table public.transport_quotes
  add column if not exists utm_source text,
  add column if not exists utm_medium text,
  add column if not exists utm_campaign text,
  add column if not exists utm_content text,
  add column if not exists gclid text,
  add column if not exists fbclid text,
  add column if not exists attribution_at timestamptz,
  add column if not exists consentement_pub boolean;

alter table public.accounts
  add column if not exists utm_source text,
  add column if not exists utm_medium text,
  add column if not exists utm_campaign text,
  add column if not exists utm_content text,
  add column if not exists gclid text,
  add column if not exists fbclid text,
  add column if not exists attribution_at timestamptz,
  add column if not exists consentement_pub boolean,
  add column if not exists consentement_pub_at timestamptz,
  add column if not exists is_internal boolean not null default false;

alter table public.transport_orders
  add column if not exists utm_source text,
  add column if not exists utm_medium text,
  add column if not exists utm_campaign text,
  add column if not exists utm_content text,
  add column if not exists gclid text,
  add column if not exists fbclid text,
  add column if not exists attribution_at timestamptz,
  add column if not exists consentement_pub boolean,
  add column if not exists is_test boolean not null default false;

alter table public.missions
  add column if not exists is_test boolean not null default false;

comment on column public.accounts.is_internal is
  'Compte appartenant à SECOTO / Nawfal Benchiha : exclu des statistiques du réseau.';
comment on column public.missions.is_test is 'Mission de test : exclue de tous les tableaux de bord et calculs financiers.';
comment on column public.transport_orders.is_test is 'Commande de test : exclue de tous les tableaux de bord et calculs financiers.';

-- 2. Nettoyage des valeurs venues du navigateur -------------------------------
create or replace function secoto_private.attr_clean(p_value text)
returns text language sql immutable set search_path = ''
as $f$
  select nullif(left(regexp_replace(btrim(coalesce(p_value, '')), '[^A-Za-z0-9 _.~:/+@%=|,()\-]', '', 'g'), 200), '');
$f$;

create or replace function secoto_private.attr_time(p_value text)
returns timestamptz language plpgsql immutable set search_path = ''
as $f$
begin
  if p_value is null or p_value = '' then return null; end if;
  return least(greatest(p_value::timestamptz, now() - interval '90 days'), now());
exception when others then
  return null;
end;
$f$;

-- 3. Devis : provenance posée par le serveur (fonctions quote-public / quote-transport)
create or replace function public.secoto_attribution_devis(p_quote_id uuid, p_attr jsonb, p_consentement boolean)
returns void language plpgsql volatile security definer set search_path = ''
as $f$
begin
  if p_quote_id is null then return; end if;
  update public.transport_quotes q set
    utm_source     = coalesce(q.utm_source, secoto_private.attr_clean(p_attr ->> 'utm_source')),
    utm_medium     = coalesce(q.utm_medium, secoto_private.attr_clean(p_attr ->> 'utm_medium')),
    utm_campaign   = coalesce(q.utm_campaign, secoto_private.attr_clean(p_attr ->> 'utm_campaign')),
    utm_content    = coalesce(q.utm_content, secoto_private.attr_clean(p_attr ->> 'utm_content')),
    gclid          = coalesce(q.gclid, secoto_private.attr_clean(p_attr ->> 'gclid')),
    fbclid         = coalesce(q.fbclid, secoto_private.attr_clean(p_attr ->> 'fbclid')),
    attribution_at = coalesce(q.attribution_at, secoto_private.attr_time(p_attr ->> 'at')),
    consentement_pub = coalesce(p_consentement, q.consentement_pub)
  where q.id = p_quote_id;
end;
$f$;

-- 4. Comptes : provenance lue dans les métadonnées d'inscription --------------
create or replace function secoto_private.trg_account_attribution()
returns trigger language plpgsql security definer set search_path = ''
as $f$
declare v_meta jsonb; v_attr jsonb;
begin
  begin
    select u.raw_user_meta_data into v_meta from auth.users u where u.id = new.id;
    v_attr := coalesce(v_meta -> 'attribution', '{}'::jsonb);
    new.utm_source     := coalesce(new.utm_source, secoto_private.attr_clean(v_attr ->> 'utm_source'));
    new.utm_medium     := coalesce(new.utm_medium, secoto_private.attr_clean(v_attr ->> 'utm_medium'));
    new.utm_campaign   := coalesce(new.utm_campaign, secoto_private.attr_clean(v_attr ->> 'utm_campaign'));
    new.utm_content    := coalesce(new.utm_content, secoto_private.attr_clean(v_attr ->> 'utm_content'));
    new.gclid          := coalesce(new.gclid, secoto_private.attr_clean(v_attr ->> 'gclid'));
    new.fbclid         := coalesce(new.fbclid, secoto_private.attr_clean(v_attr ->> 'fbclid'));
    new.attribution_at := coalesce(new.attribution_at, secoto_private.attr_time(v_attr ->> 'at'));
    if new.consentement_pub is null and jsonb_typeof(v_meta -> 'consentement_pub') = 'boolean' then
      new.consentement_pub := (v_meta ->> 'consentement_pub')::boolean;
      new.consentement_pub_at := now();
    end if;
  exception when others then
    raise warning 'SECOTO attribution compte ignorée : %', sqlerrm;
  end;
  return new;
end;
$f$;

drop trigger if exists trg_secoto_account_attribution on public.accounts;
create trigger trg_secoto_account_attribution
  before insert on public.accounts
  for each row execute function secoto_private.trg_account_attribution();

-- Compte connecté : complète sa provenance (si vide) et met à jour son choix
-- de cookies. Ne touche à rien d'autre.
create or replace function public.secoto_mon_attribution(p_attr jsonb default null, p_consentement boolean default null)
returns void language plpgsql volatile security definer set search_path = ''
as $f$
declare v_uid uuid := auth.uid();
begin
  if v_uid is null then raise exception 'Connexion requise.'; end if;
  update public.accounts a set
    utm_source     = coalesce(a.utm_source, secoto_private.attr_clean(p_attr ->> 'utm_source')),
    utm_medium     = coalesce(a.utm_medium, secoto_private.attr_clean(p_attr ->> 'utm_medium')),
    utm_campaign   = coalesce(a.utm_campaign, secoto_private.attr_clean(p_attr ->> 'utm_campaign')),
    utm_content    = coalesce(a.utm_content, secoto_private.attr_clean(p_attr ->> 'utm_content')),
    gclid          = coalesce(a.gclid, secoto_private.attr_clean(p_attr ->> 'gclid')),
    fbclid         = coalesce(a.fbclid, secoto_private.attr_clean(p_attr ->> 'fbclid')),
    attribution_at = coalesce(a.attribution_at, secoto_private.attr_time(p_attr ->> 'at')),
    consentement_pub    = coalesce(p_consentement, a.consentement_pub),
    consentement_pub_at = case when p_consentement is not null then now() else a.consentement_pub_at end
  where a.id = v_uid;
end;
$f$;

-- 5. Commandes : provenance recopiée du devis (sinon du compte) ---------------
create or replace function secoto_private.trg_order_attribution()
returns trigger language plpgsql security definer set search_path = ''
as $f$
declare q public.transport_quotes%rowtype; a public.accounts%rowtype;
begin
  begin
    select * into q from public.transport_quotes where id = new.quote_id;
    select * into a from public.accounts where id = new.account_id;
    if new.utm_source is null and new.utm_campaign is null and new.gclid is null and new.fbclid is null then
      if q.utm_source is not null or q.utm_campaign is not null or q.gclid is not null or q.fbclid is not null then
        new.utm_source := q.utm_source; new.utm_medium := q.utm_medium; new.utm_campaign := q.utm_campaign;
        new.utm_content := q.utm_content; new.gclid := q.gclid; new.fbclid := q.fbclid; new.attribution_at := q.attribution_at;
      else
        new.utm_source := a.utm_source; new.utm_medium := a.utm_medium; new.utm_campaign := a.utm_campaign;
        new.utm_content := a.utm_content; new.gclid := a.gclid; new.fbclid := a.fbclid; new.attribution_at := a.attribution_at;
      end if;
    end if;
    -- Le choix le plus récent fait foi : celui du compte, sinon celui du devis.
    new.consentement_pub := coalesce(new.consentement_pub, a.consentement_pub, q.consentement_pub);
  exception when others then
    raise warning 'SECOTO attribution commande ignorée : %', sqlerrm;
  end;
  return new;
end;
$f$;

drop trigger if exists trg_secoto_order_attribution on public.transport_orders;
create trigger trg_secoto_order_attribution
  before insert on public.transport_orders
  for each row execute function secoto_private.trg_order_attribution();

-- 6. Conversions publicitaires (commande payée) -------------------------------
create table if not exists public.ad_conversions (
  id               uuid primary key default gen_random_uuid(),
  payment_id       uuid not null unique references public.payments(id) on delete cascade,
  order_id         uuid references public.transport_orders(id) on delete set null,
  event_id         text not null unique,
  event_time       timestamptz not null default now(),
  value_cents      integer not null default 0,
  currency         text not null default 'EUR',
  gclid            text,
  fbclid           text,
  attribution_at   timestamptz,
  consentement_pub boolean,
  email_sha256     text,
  phone_sha256     text,
  external_id_sha256 text,
  meta_status      text not null default 'pending' check (meta_status in ('pending', 'sent', 'skipped', 'failed')),
  meta_attempts    integer not null default 0,
  meta_sent_at     timestamptz,
  meta_error       text,
  created_at       timestamptz not null default now()
);
create index if not exists ad_conversions_meta_idx on public.ad_conversions (meta_status, created_at);
alter table public.ad_conversions enable row level security;
revoke all on table public.ad_conversions from public, anon, authenticated;
comment on table public.ad_conversions is
  'Commandes payées à déclarer aux régies (Meta, Google). Réservée au serveur. Valeur = commission SECOTO.';

create or replace function secoto_private.sha256_hex(p_value text)
returns text language sql immutable set search_path = ''
as $f$ select case when coalesce(p_value, '') = '' then null else encode(sha256(convert_to(p_value, 'UTF8')), 'hex') end; $f$;

-- Téléphone au format attendu par Meta : chiffres seuls, indicatif 33.
create or replace function secoto_private.phone_e164_digits(p_phone text)
returns text language sql immutable set search_path = ''
as $f$
  select case
    when d ~ '^0[1-9][0-9]{8}$' then '33' || substr(d, 2)
    when d ~ '^33[1-9][0-9]{8}$' then d
    when d ~ '^0033[1-9][0-9]{8}$' then substr(d, 3)
    else null end
  from (select regexp_replace(coalesce(p_phone, ''), '[^0-9]', '', 'g') as d) x;
$f$;

create or replace function secoto_private.trg_payment_conversion()
returns trigger language plpgsql security definer set search_path = ''
as $f$
declare o public.transport_orders%rowtype; a public.accounts%rowtype;
begin
  if new.status <> 'paid' or new.order_id is null then return null; end if;
  if tg_op = 'UPDATE' and old.status = 'paid' then return null; end if;
  begin
    select * into o from public.transport_orders where id = new.order_id;
    if not found or o.is_test then return null; end if;
    select * into a from public.accounts where id = o.account_id;
    insert into public.ad_conversions(payment_id, order_id, event_id, event_time, value_cents, gclid, fbclid,
      attribution_at, consentement_pub, email_sha256, phone_sha256, external_id_sha256, meta_status)
    values (new.id, o.id, 'cmd-' || new.id::text, coalesce(new.captured_at, new.paid_at, now()),
      greatest(o.client_price_cents - o.partner_pay_cents, 0), o.gclid, o.fbclid, o.attribution_at,
      o.consentement_pub,
      secoto_private.sha256_hex(lower(btrim(a.email))),
      secoto_private.sha256_hex(secoto_private.phone_e164_digits(a.phone)),
      secoto_private.sha256_hex(a.id::text),
      case when coalesce(o.consentement_pub, false) then 'pending' else 'skipped' end)
    on conflict do nothing;
  exception when others then
    raise warning 'SECOTO conversion ignorée : %', sqlerrm;
  end;
  return null;
end;
$f$;

drop trigger if exists trg_secoto_payment_conversion on public.payments;
create trigger trg_secoto_payment_conversion
  after insert or update of status on public.payments
  for each row execute function secoto_private.trg_payment_conversion();

-- Serveur : conversions à envoyer à Meta (consentement donné uniquement).
create or replace function public.secoto_conversions_meta_a_envoyer(p_limit integer default 20)
returns jsonb language sql stable security definer set search_path = ''
as $f$
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', c.id, 'event_id', c.event_id, 'event_time', extract(epoch from c.event_time)::bigint,
    'value', round(c.value_cents / 100.0, 2), 'currency', c.currency,
    'fbclid', c.fbclid, 'fbclid_at_ms', (extract(epoch from coalesce(c.attribution_at, c.event_time)) * 1000)::bigint,
    'email_sha256', c.email_sha256, 'phone_sha256', c.phone_sha256, 'external_id_sha256', c.external_id_sha256,
    'order_ref', o.public_ref) order by c.created_at), '[]'::jsonb)
  from (select * from public.ad_conversions
         where meta_status in ('pending', 'failed') and meta_attempts < 6 and coalesce(consentement_pub, false)
         order by created_at limit greatest(1, least(coalesce(p_limit, 20), 100))) c
  left join public.transport_orders o on o.id = c.order_id;
$f$;

create or replace function public.secoto_conversion_meta_resultat(p_id uuid, p_ok boolean, p_error text default null)
returns void language sql volatile security definer set search_path = ''
as $f$
  update public.ad_conversions set
    meta_status = case when p_ok then 'sent' else 'failed' end,
    meta_attempts = meta_attempts + 1,
    meta_sent_at = case when p_ok then now() else meta_sent_at end,
    meta_error = case when p_ok then null else left(p_error, 500) end
  where id = p_id and meta_status <> 'sent';
$f$;

-- Serveur : conversions Google Ads (gclid + consentement, 90 derniers jours).
create or replace function public.secoto_conversions_google()
returns jsonb language sql stable security definer set search_path = ''
as $f$
  select coalesce(jsonb_agg(jsonb_build_object(
    'gclid', c.gclid, 'event_time', c.event_time, 'value', round(c.value_cents / 100.0, 2),
    'currency', c.currency, 'event_id', c.event_id) order by c.event_time), '[]'::jsonb)
  from public.ad_conversions c
  join public.transport_orders o on o.id = c.order_id
  where c.gclid is not null and coalesce(c.consentement_pub, false)
    and not o.is_test and o.status <> 'cancelled'
    and c.event_time >= now() - interval '90 days';
$f$;

-- 7. Espace dirigeant (087) : mêmes calculs, sans les données de test ---------
create or replace function secoto_private.dirigeant_lignes()
returns table (
  jour timestamptz,
  source text,
  reference text,
  client text,
  trajet text,
  libelle text,
  encaisse_cents bigint,
  rembourse_cents bigint,
  reverse_cents bigint,
  commission_cents bigint
)
language sql stable security definer set search_path = ''
as $f$
  with pay as (
    select p.id, p.purpose, p.amount_cents::bigint as amount, p.refunded_amount_cents::bigint as refunded,
           p.payment_circuit, coalesce(p.application_fee_cents, 0)::bigint as fee,
           p.order_id, p.mission_id,
           coalesce(p.captured_at, p.paid_at, p.updated_at) as jour,
           o.public_ref as o_ref, o.status as o_status, o.partner_pay_cents::bigint as o_partner,
           m.public_ref as m_ref, m.cancelled_at as m_cancelled, m.carrier_pay as m_carrier,
           coalesce(q.pickup ->> 'city', m.from_city) as ville_depart,
           coalesce(q.delivery ->> 'city', m.to_city) as ville_arrivee,
           coalesce(nullif(a.company_name, ''), nullif(a.full_name, ''), a.email) as client,
           (select sum(pp.amount_cents)::bigint
              from public.partner_payouts pp
             where pp.status <> 'cancelled'
               and pp.payment_circuit is null
               and (pp.order_id = p.order_id or (p.order_id is null and pp.mission_id = p.mission_id))) as payouts
      from public.payments p
      left join public.transport_orders o on o.id = p.order_id
      left join public.transport_quotes q on q.id = o.quote_id
      left join public.missions m on m.id = coalesce(p.mission_id, o.mission_id)
      left join public.accounts a on a.id = p.account_id
     where p.status in ('paid', 'refund_pending', 'refunded')
       and (p.captured_at is not null or p.paid_at is not null)
       and not coalesce(o.is_test, false)
       and not coalesce(m.is_test, false)
  ), pay2 as (
    select pay.*,
      case
        when payment_circuit = 'direct' then
          greatest(fee - round(fee::numeric * refunded / nullif(amount, 0))::bigint, 0)
        when purpose in ('commission_plateau', 'od_plateau_commission') then amount - refunded
        else amount - refunded - coalesce(payouts,
          case
            when order_id is not null then case when o_status in ('cancelled', 'no_partner') then 0 else coalesce(o_partner, 0) end
            when mission_id is not null and purpose in ('convoyage_livraison', 'devis_course')
              then case when m_cancelled is not null then 0 else round(coalesce(m_carrier, 0) * 100)::bigint end
            else 0
          end)
      end as commission
    from pay
  )
  select jour, 'paiement'::text, coalesce(o_ref, m_ref, '—'), client,
         case when ville_depart is not null then ville_depart || ' → ' || coalesce(ville_arrivee, '?') end,
         case purpose
           when 'commission_plateau' then 'Commission de mise en relation (plateau)'
           when 'od_plateau_commission' then 'Commission de mise en relation (plateau)'
           when 'od_plateau' then case when payment_circuit = 'direct' then 'Plateau, paiement direct au transporteur' else 'Plateau, prix complet encaissé' end
           when 'od_convoyage' then 'Convoyage'
           when 'convoyage_livraison' then 'Convoyage'
           when 'devis_course' then 'Devis payé en ligne'
           when 'subscription_extension' then 'Complément d''abonnement'
           else purpose
         end,
         amount, refunded,
         greatest(amount - refunded - commission, 0),
         commission
    from pay2

  union all

  select coalesce(m.commission_settled_at, m.commission_paid_at), 'hors_application', m.public_ref,
         coalesce(nullif(a.company_name, ''), nullif(a.full_name, ''), a.email),
         case when m.from_city is not null then m.from_city || ' → ' || coalesce(m.to_city, '?') end,
         'Commission réglée hors application',
         round(coalesce(nullif(m.commission_amount, 0), m.margin, 0) * 100)::bigint, 0::bigint, 0::bigint,
         round(coalesce(nullif(m.commission_amount, 0), m.margin, 0) * 100)::bigint
    from public.missions m
    left join public.accounts a on a.id = m.client_account_id
   where m.cancelled_at is null
     and not m.is_test
     and (m.commission_settled_offline or m.commission_paid_at is not null)
     and coalesce(m.commission_settled_at, m.commission_paid_at) is not null
     and coalesce(nullif(m.commission_amount, 0), m.margin, 0) > 0
     and not exists (
       select 1 from public.payments p
        where p.status in ('paid', 'refund_pending', 'refunded')
          and (p.mission_id = m.id
               or p.order_id in (select o.id from public.transport_orders o where o.mission_id = m.id)))

  union all

  select e.created_at, 'abonnement', coalesce(b.name, 'Abonnement'),
         coalesce(b.name, 'Entreprise'), null::text, 'Abonnement mensuel',
         coalesce(sp.monthly_price_cents, 0)::bigint, 0::bigint, 0::bigint,
         coalesce(sp.monthly_price_cents, 0)::bigint
    from public.subscription_billing_events e
    join public.subscriptions s on s.id = e.subscription_id
    left join public.subscription_proposals sp on sp.id = s.proposal_id
    left join public.business_accounts b on b.id = s.business_id
   where e.event_type = 'invoice.paid'

  union all

  select coalesce(pp.due_at, pp.created_at), 'abonnement_course', coalesce(o.public_ref, '—'),
         coalesce(b.name, 'Entreprise'),
         case when q.pickup ->> 'city' is not null then (q.pickup ->> 'city') || ' → ' || coalesce(q.delivery ->> 'city', '?') end,
         'Course sur abonnement : part du transporteur',
         0::bigint, 0::bigint, pp.amount_cents::bigint, -pp.amount_cents::bigint
    from public.partner_payouts pp
    join public.transport_orders o on o.id = pp.order_id and o.funding = 'subscription' and not o.is_test
    left join public.transport_quotes q on q.id = o.quote_id
    left join public.business_accounts b on b.id = o.business_id
   where pp.status <> 'cancelled' and pp.payment_circuit is null;
$f$;

create or replace function public.secoto_dirigeant_tableau(p_annee integer default null)
returns jsonb language plpgsql stable security definer set search_path = ''
as $f$
declare
  v_annee integer := coalesce(p_annee, extract(year from now() at time zone 'Europe/Paris')::int);
  v_mois jsonb;
  v_annees jsonb;
  v_attente jsonb;
  v_especes jsonb;
  v_a_verser jsonb;
begin
  perform secoto_private.assert_dirigeant();

  with l as (
    select extract(month from jour at time zone 'Europe/Paris')::int as mois, *
      from secoto_private.dirigeant_lignes()
     where extract(year from jour at time zone 'Europe/Paris')::int = v_annee
  ), parmois as (
    select g as mois,
           coalesce(sum(l.encaisse_cents), 0) as encaisse,
           coalesce(sum(l.rembourse_cents), 0) as rembourse,
           coalesce(sum(l.reverse_cents), 0) as reverse,
           coalesce(sum(l.commission_cents), 0) as commission,
           count(l.mois) as operations
      from generate_series(1, 12) g
      left join l on l.mois = g
     group by g
  )
  select jsonb_agg(jsonb_build_object(
           'mois', mois, 'encaisse_cents', encaisse, 'rembourse_cents', rembourse,
           'reverse_cents', reverse, 'commission_cents', commission, 'operations', operations) order by mois)
    into v_mois
    from parmois;

  select coalesce(jsonb_agg(a order by a desc), '[]'::jsonb) into v_annees
    from (select distinct extract(year from jour at time zone 'Europe/Paris')::int as a
            from secoto_private.dirigeant_lignes()
          union select extract(year from now() at time zone 'Europe/Paris')::int) y;

  select jsonb_build_object(
           'nombre', count(*),
           'montant_cents', coalesce(sum(x.cents), 0),
           'liste', coalesce(jsonb_agg(jsonb_build_object('reference', x.ref, 'client', x.client, 'trajet', x.trajet,
                      'montant_cents', x.cents, 'depuis', x.depuis) order by x.depuis desc), '[]'::jsonb))
    into v_attente
    from (
      select o.public_ref as ref, coalesce(nullif(a.company_name, ''), nullif(a.full_name, ''), a.email) as client,
             (q.pickup ->> 'city') || ' → ' || (q.delivery ->> 'city') as trajet,
             o.client_price_cents::bigint as cents, o.created_at as depuis
        from public.transport_orders o
        left join public.transport_quotes q on q.id = o.quote_id
        left join public.accounts a on a.id = o.account_id
       where o.status = 'awaiting_payment' and o.funding = 'card' and not o.is_test
      union all
      select m.public_ref, coalesce(nullif(a.company_name, ''), nullif(a.full_name, ''), a.email),
             m.from_city || ' → ' || m.to_city,
             round(coalesce(m.client_total_due, m.client_price, 0) * 100)::bigint, m.created_at
        from public.missions m
        left join public.accounts a on a.id = m.client_account_id
       where m.payment_status = 'awaiting_payment' and m.cancelled_at is null and not m.is_test
         and not exists (select 1 from public.transport_orders o where o.mission_id = m.id)
    ) x;

  select jsonb_build_object(
           'nombre', count(*),
           'montant_cents', coalesce(sum(round(coalesce(nullif(m.commission_amount, 0), m.margin, 0) * 100)), 0)::bigint,
           'liste', coalesce(jsonb_agg(jsonb_build_object(
               'reference', m.public_ref,
               'transporteur', coalesce(nullif(t.company_name, ''), t.full_name, m.assigned_transporter_name),
               'trajet', m.from_city || ' → ' || m.to_city,
               'montant_cents', round(coalesce(nullif(m.commission_amount, 0), m.margin, 0) * 100)::bigint,
               'depuis', m.commission_due_since) order by m.commission_due_since), '[]'::jsonb))
    into v_especes
    from public.missions m
    left join public.accounts t on t.id = m.assigned_transporter_id
   where m.commission_due_since is not null
     and m.cancelled_at is null
     and not m.is_test
     and not coalesce(m.commission_settled_offline, false)
     and m.commission_paid_at is null;

  select jsonb_build_object('nombre', count(*), 'montant_cents', coalesce(sum(pp.amount_cents), 0)::bigint)
    into v_a_verser
    from public.partner_payouts pp
    left join public.transport_orders o on o.id = pp.order_id
    left join public.missions m on m.id = pp.mission_id
   where pp.status in ('to_pay', 'processing', 'failed') and pp.payment_circuit is null
     and not coalesce(o.is_test, false) and not coalesce(m.is_test, false);

  return jsonb_build_object(
    'annee', v_annee,
    'annees', v_annees,
    'mois', v_mois,
    'en_attente', v_attente,
    'commissions_especes_dues', v_especes,
    'versements_a_faire', v_a_verser,
    'genere_le', now());
end;
$f$;

create or replace function public.secoto_dirigeant_litiges()
returns jsonb language plpgsql stable security definer set search_path = ''
as $f$
declare
  v_contestations jsonb;
  v_sav jsonb;
begin
  perform secoto_private.assert_dirigeant();

  select coalesce(jsonb_agg(jsonb_build_object(
           'reference', coalesce(o.public_ref, m.public_ref, '—'),
           'client', coalesce(nullif(a.company_name, ''), nullif(a.full_name, ''), a.email),
           'montant_cents', p.amount_cents,
           'statut', p.dispute_status,
           'depuis', coalesce(p.last_event_at, p.updated_at))
           order by (p.dispute_status = 'open') desc, coalesce(p.last_event_at, p.updated_at) desc), '[]'::jsonb)
    into v_contestations
    from public.payments p
    left join public.transport_orders o on o.id = p.order_id
    left join public.missions m on m.id = coalesce(p.mission_id, o.mission_id)
    left join public.accounts a on a.id = p.account_id
   where p.dispute_status is not null
     and not coalesce(o.is_test, false) and not coalesce(m.is_test, false);

  select jsonb_build_object(
           'ouvertes', count(*) filter (where s.status = 'ouverte'),
           'en_cours', count(*) filter (where s.status = 'en_cours'),
           'resolues', count(*) filter (where s.status = 'resolue'),
           'dommages_ouverts', count(*) filter (where s.status <> 'resolue' and s.motif = 'dommage'),
           'total', count(*))
    into v_sav
    from public.sav_requests s
    left join public.transport_orders o on o.id = s.order_id
    left join public.missions m on m.id = s.mission_id
   where not coalesce(o.is_test, false) and not coalesce(m.is_test, false);

  return jsonb_build_object('contestations', v_contestations, 'sav', v_sav);
end;
$f$;

-- 8. Tableau d'acquisition (admin) --------------------------------------------
-- p_debut inclus, p_fin exclu (heure de Paris).
create or replace function public.secoto_admin_acquisition(p_debut date, p_fin date)
returns jsonb language plpgsql stable security definer set search_path = ''
as $f$
declare v_lignes jsonb; v_total jsonb;
begin
  perform secoto_private.assert_admin();
  if p_debut is null or p_fin is null or p_fin <= p_debut or p_fin - p_debut > 400 then
    raise exception 'Période invalide.';
  end if;

  with src as (
    -- Prix affichés : un devis chiffré = un prix vu par le visiteur.
    select coalesce(q.utm_source, case when q.gclid is not null then 'google' when q.fbclid is not null then 'facebook' end, '(direct)') as source,
           coalesce(q.utm_campaign, '—') as campagne, 1 as prix, 0 as comptes, 0 as commandes, 0::bigint as commission
      from public.transport_quotes q
     where q.client_price_cents is not null
       and (q.created_at at time zone 'Europe/Paris')::date >= p_debut
       and (q.created_at at time zone 'Europe/Paris')::date < p_fin
    union all
    select coalesce(a.utm_source, case when a.gclid is not null then 'google' when a.fbclid is not null then 'facebook' end, '(direct)'),
           coalesce(a.utm_campaign, '—'), 0, 1, 0, 0
      from public.accounts a
     where a.role = 'client' and a.deleted_at is null
       and (a.created_at at time zone 'Europe/Paris')::date >= p_debut
       and (a.created_at at time zone 'Europe/Paris')::date < p_fin
    union all
    select coalesce(o.utm_source, case when o.gclid is not null then 'google' when o.fbclid is not null then 'facebook' end, '(direct)'),
           coalesce(o.utm_campaign, '—'), 0, 0, 1, coalesce(l.commission_cents, 0)
      from secoto_private.dirigeant_lignes() l
      join public.transport_orders o on o.public_ref = l.reference and not o.is_test
     where l.source = 'paiement'
       and (l.jour at time zone 'Europe/Paris')::date >= p_debut
       and (l.jour at time zone 'Europe/Paris')::date < p_fin
  ), agg as (
    select source, campagne, sum(prix) as prix_affiches, sum(comptes) as comptes_crees,
           sum(commandes) as commandes_payees, sum(commission)::bigint as commission_cents
      from src group by source, campagne
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'source', source, 'campagne', campagne, 'prix_affiches', prix_affiches,
           'comptes_crees', comptes_crees, 'commandes_payees', commandes_payees,
           'commission_cents', commission_cents)
           order by commission_cents desc, commandes_payees desc, prix_affiches desc), '[]'::jsonb),
         jsonb_build_object('prix_affiches', coalesce(sum(prix_affiches), 0), 'comptes_crees', coalesce(sum(comptes_crees), 0),
                            'commandes_payees', coalesce(sum(commandes_payees), 0), 'commission_cents', coalesce(sum(commission_cents), 0))
    into v_lignes, v_total
    from agg;

  return jsonb_build_object('debut', p_debut, 'fin', p_fin, 'lignes', v_lignes, 'total', v_total);
end;
$f$;

-- 9. Réseau de transporteurs par département (admin, hors comptes internes) --
create or replace function public.secoto_admin_reseau()
returns jsonb language plpgsql stable security definer set search_path = ''
as $f$
declare v jsonb;
begin
  perform secoto_private.assert_admin();
  with t as (
    select a.id, a.transporter_type,
           coalesce(p.zones, '{}') as zones, coalesce(p.vehicle_classes, '{}') as classes,
           coalesce(p.available, false) as disponible, p.coverage_confirmed_at
      from public.accounts a
      left join public.partner_dispatch_preferences p on p.account_id = a.id
     where a.role = 'transporter' and a.status = 'active' and coalesce(a.is_verified, false)
       and a.deleted_at is null and not a.is_internal
       and secoto_private.carrier_rate_owner(a.id) = a.id
  ), d as (
    select z as departement, count(*) as n, count(*) filter (where t.disponible) as dispo,
           count(*) filter (where cardinality(t.classes) = 0 or 'moto' = any(t.classes)) as moto
      from t cross join lateral unnest(case when cardinality(t.zones) = 0 then array['Toute la France'] else t.zones end) z
     group by z
  )
  select jsonb_build_object(
    'departements', (select coalesce(jsonb_agg(jsonb_build_object('departement', departement, 'transporteurs', n,
                       'disponibles', dispo, 'moto', moto) order by n desc, departement), '[]'::jsonb) from d),
    'resume', (select jsonb_build_object(
       'transporteurs', count(*),
       'disponibles', count(*) filter (where disponible),
       'moto', count(*) filter (where cardinality(classes) = 0 or 'moto' = any(classes)),
       'couverture_confirmee', count(*) filter (where coverage_confirmed_at is not null),
       'plateau', count(*) filter (where transporter_type in ('vl', 'pl')),
       'convoyeurs', count(*) filter (where transporter_type = 'convoyeur')) from t))
    into v;
  return v;
end;
$f$;

-- 10. Couverture du transporteur : départements + moto ------------------------
alter table public.partner_dispatch_preferences
  add column if not exists coverage_confirmed_at timestamptz;

create or replace function secoto_private.departements_valides()
returns text[] language sql immutable set search_path = ''
as $f$
  select array_agg(d order by d) from (
    select lpad(g::text, 2, '0') as d from generate_series(1, 95) g where g <> 20
    union all select '2A' union all select '2B') x;
$f$;

create or replace function public.secoto_carrier_coverage_status()
returns jsonb language plpgsql stable security definer set search_path = ''
as $f$
declare v_uid uuid := auth.uid(); a public.accounts%rowtype; p public.partner_dispatch_preferences%rowtype;
begin
  select * into a from public.accounts where id = v_uid and deleted_at is null;
  if not found or a.role <> 'transporter' then return jsonb_build_object('required', false); end if;
  -- Un chauffeur salarié ne fixe pas la couverture : c'est son gérant.
  if secoto_private.carrier_rate_owner(v_uid) <> v_uid then return jsonb_build_object('required', false); end if;
  select * into p from public.partner_dispatch_preferences where account_id = v_uid;
  return jsonb_build_object(
    'required', p.coverage_confirmed_at is null,
    'zones', coalesce(to_jsonb(p.zones), '[]'::jsonb),
    'moto', coalesce(p.coverage_confirmed_at is not null and 'moto' = any(p.vehicle_classes), false),
    'convoyeur', a.transporter_type = 'convoyeur',
    'confirmed_at', p.coverage_confirmed_at);
end;
$f$;

create or replace function public.secoto_carrier_coverage_save(p_zones text[], p_moto boolean)
returns jsonb language plpgsql volatile security definer set search_path = ''
as $f$
declare v_uid uuid := auth.uid(); a public.accounts%rowtype; v_zones text[]; v_classes text[];
begin
  select * into a from public.accounts where id = v_uid and deleted_at is null;
  if not found or a.role <> 'transporter' then raise exception 'Réservé aux transporteurs.'; end if;
  if secoto_private.carrier_rate_owner(v_uid) <> v_uid then raise exception 'Seul le gérant fixe la couverture.'; end if;
  if exists (select 1 from unnest(coalesce(p_zones, '{}')) z
              where upper(btrim(z)) <> all(secoto_private.departements_valides())) then
    raise exception 'Département inconnu.';
  end if;
  select array_agg(distinct upper(btrim(z))) into v_zones from unnest(coalesce(p_zones, '{}')) z;
  if coalesce(cardinality(v_zones), 0) = 0 then raise exception 'Choisissez au moins un département.'; end if;
  v_classes := case when coalesce(p_moto, false) then array['voiture', 'utilitaire', 'moto', 'autre']
                    else array['voiture', 'utilitaire', 'autre'] end;
  insert into public.partner_dispatch_preferences as p(account_id, zones, vehicle_classes, coverage_confirmed_at, updated_at)
  values (v_uid, v_zones, v_classes, now(), now())
  on conflict (account_id) do update
     set zones = excluded.zones,
         -- Les autres catégories déjà choisies sont conservées ; seule la moto suit la réponse.
         vehicle_classes = case
           when cardinality(p.vehicle_classes) = 0 then excluded.vehicle_classes
           when coalesce(p_moto, false) then (select array_agg(distinct c) from unnest(p.vehicle_classes || array['moto']) c)
           else coalesce((select array_agg(c) from unnest(p.vehicle_classes) c where c <> 'moto'), array['voiture', 'utilitaire', 'autre'])
         end,
         coverage_confirmed_at = now(),
         updated_at = now();
  perform secoto_private.audit('carrier_coverage_saved', 'account', v_uid::text,
    jsonb_build_object('zones', v_zones, 'moto', coalesce(p_moto, false)));
  return public.secoto_carrier_coverage_status();
end;
$f$;

-- 11. Droits -----------------------------------------------------------------
revoke all on function secoto_private.attr_clean(text) from public, anon, authenticated;
revoke all on function secoto_private.attr_time(text) from public, anon, authenticated;
revoke all on function secoto_private.trg_account_attribution() from public, anon, authenticated;
revoke all on function secoto_private.trg_order_attribution() from public, anon, authenticated;
revoke all on function secoto_private.trg_payment_conversion() from public, anon, authenticated;
revoke all on function secoto_private.sha256_hex(text) from public, anon, authenticated;
revoke all on function secoto_private.phone_e164_digits(text) from public, anon, authenticated;
revoke all on function secoto_private.departements_valides() from public, anon, authenticated;
revoke all on function secoto_private.dirigeant_lignes() from public, anon, authenticated;

revoke all on function public.secoto_attribution_devis(uuid, jsonb, boolean) from public, anon, authenticated;
revoke all on function public.secoto_conversions_meta_a_envoyer(integer) from public, anon, authenticated;
revoke all on function public.secoto_conversion_meta_resultat(uuid, boolean, text) from public, anon, authenticated;
revoke all on function public.secoto_conversions_google() from public, anon, authenticated;
grant execute on function public.secoto_attribution_devis(uuid, jsonb, boolean) to service_role;
grant execute on function public.secoto_conversions_meta_a_envoyer(integer) to service_role;
grant execute on function public.secoto_conversion_meta_resultat(uuid, boolean, text) to service_role;
grant execute on function public.secoto_conversions_google() to service_role;

revoke all on function public.secoto_mon_attribution(jsonb, boolean) from public, anon;
revoke all on function public.secoto_admin_acquisition(date, date) from public, anon;
revoke all on function public.secoto_admin_reseau() from public, anon;
revoke all on function public.secoto_carrier_coverage_status() from public, anon;
revoke all on function public.secoto_carrier_coverage_save(text[], boolean) from public, anon;
revoke all on function public.secoto_dirigeant_tableau(integer) from public, anon;
revoke all on function public.secoto_dirigeant_litiges() from public, anon;
grant execute on function public.secoto_mon_attribution(jsonb, boolean) to authenticated;
grant execute on function public.secoto_admin_acquisition(date, date) to authenticated;
grant execute on function public.secoto_admin_reseau() to authenticated;
grant execute on function public.secoto_carrier_coverage_status() to authenticated;
grant execute on function public.secoto_carrier_coverage_save(text[], boolean) to authenticated;
grant execute on function public.secoto_dirigeant_tableau(integer) to authenticated;
grant execute on function public.secoto_dirigeant_litiges() to authenticated;
