-- ============================================================================
-- SECOTO — MIGRATION 087 : ESPACE DIRIGEANT
-- ----------------------------------------------------------------------------
-- Décision de Nawfal du 09/10/2026. Un espace réservé au seul dirigeant :
--   1. Tableau de bord financier : encaissé, versé aux transporteurs,
--      remboursé, commission SECOTO, mois par mois ; ce qui reste en attente.
--   2. Déclaration URSSAF : la commission SECOTO de la période, ligne à ligne.
--   3. Suivi des litiges (contestations bancaires) et des demandes SAV.
--
-- SÉCURITÉ
--   · Accès par liste nominative (secoto_private.dirigeants), en plus du rôle
--     administrateur. Un autre administrateur n'y a pas accès : la base refuse.
--   · La liste est vide après la migration : rien n'apparaît tant que le
--     dirigeant n'y a pas été ajouté (c'est l'interrupteur de mise en service).
--   · Lecture seule : aucune fonction de cette migration ne modifie une
--     commande, un paiement ou une mission.
--
-- ADDITIF UNIQUEMENT : une table, des fonctions nouvelles. Rien d'existant
-- n'est modifié ; aucune policy n'est affaiblie. Convoyage intact.
-- ============================================================================

-- 1. Liste nominative ---------------------------------------------------------
create table if not exists secoto_private.dirigeants (
  account_id uuid primary key references public.accounts(id) on delete cascade,
  created_at timestamptz not null default now()
);
alter table secoto_private.dirigeants enable row level security;
revoke all on table secoto_private.dirigeants from public;
do $revoke$
begin
  if exists (select 1 from pg_roles where rolname = 'anon') then
    execute 'revoke all on table secoto_private.dirigeants from anon';
  end if;
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'revoke all on table secoto_private.dirigeants from authenticated';
  end if;
end
$revoke$;
comment on table secoto_private.dirigeants is
  'Comptes ayant accès à l''espace dirigeant (chiffres, URSSAF, litiges). Administrateurs uniquement.';

create or replace function secoto_private.is_dirigeant(p_user uuid)
returns boolean language sql stable security definer set search_path = ''
as $f$
  select p_user is not null and exists (
    select 1
      from secoto_private.dirigeants d
      join public.accounts a on a.id = d.account_id
     where d.account_id = p_user
       and a.role = 'admin'
       and a.deleted_at is null);
$f$;

create or replace function secoto_private.assert_dirigeant()
returns uuid language plpgsql stable security definer set search_path = ''
as $f$
begin
  if not secoto_private.is_dirigeant(auth.uid()) then
    raise exception 'Accès réservé au dirigeant.' using errcode = '42501';
  end if;
  return auth.uid();
end;
$f$;

-- L'application demande seulement « ai-je accès ? » pour afficher l'onglet.
create or replace function public.secoto_dirigeant_acces()
returns boolean language sql stable security definer set search_path = ''
as $f$ select secoto_private.is_dirigeant(auth.uid()); $f$;

-- 2. Les lignes d'argent ------------------------------------------------------
-- Une ligne par encaissement. La commission d'une course est datée du jour où
-- le client a payé ; un remboursement la diminue sur cette même ligne.
--
--   · Paiement direct au transporteur : SECOTO ne garde que sa commission
--     (frais d'application Stripe), réduite à proportion d'un remboursement.
--   · Paiement de la seule commission (plateau, ancien circuit) : tout est
--     commission, moins le remboursé.
--   · Paiement du prix complet (convoyage, plateau ancien circuit, devis payé
--     en ligne) : commission = encaissé − remboursé − part du transporteur.
--     Tant que le versement n'est pas créé, la part prévue est déduite.
--   · Commission réglée hors application (espèces, virement du transporteur).
--   · Abonnements : facture mensuelle encaissée ; les courses faites sur
--     forfait déduisent la part du transporteur le jour où elle est due.
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

  -- Commission réglée hors application (espèces, virement) sur une mission.
  select coalesce(m.commission_settled_at, m.commission_paid_at), 'hors_application', m.public_ref,
         coalesce(nullif(a.company_name, ''), nullif(a.full_name, ''), a.email),
         case when m.from_city is not null then m.from_city || ' → ' || coalesce(m.to_city, '?') end,
         'Commission réglée hors application',
         round(coalesce(nullif(m.commission_amount, 0), m.margin, 0) * 100)::bigint, 0::bigint, 0::bigint,
         round(coalesce(nullif(m.commission_amount, 0), m.margin, 0) * 100)::bigint
    from public.missions m
    left join public.accounts a on a.id = m.client_account_id
   where m.cancelled_at is null
     and (m.commission_settled_offline or m.commission_paid_at is not null)
     and coalesce(m.commission_settled_at, m.commission_paid_at) is not null
     and coalesce(nullif(m.commission_amount, 0), m.margin, 0) > 0
     and not exists (
       select 1 from public.payments p
        where p.status in ('paid', 'refund_pending', 'refunded')
          and (p.mission_id = m.id
               or p.order_id in (select o.id from public.transport_orders o where o.mission_id = m.id)))

  union all

  -- Abonnements : facture mensuelle payée.
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

  -- Courses sur forfait : la part du transporteur est déduite le jour où elle est due.
  select coalesce(pp.due_at, pp.created_at), 'abonnement_course', coalesce(o.public_ref, '—'),
         coalesce(b.name, 'Entreprise'),
         case when q.pickup ->> 'city' is not null then (q.pickup ->> 'city') || ' → ' || coalesce(q.delivery ->> 'city', '?') end,
         'Course sur abonnement : part du transporteur',
         0::bigint, 0::bigint, pp.amount_cents::bigint, -pp.amount_cents::bigint
    from public.partner_payouts pp
    join public.transport_orders o on o.id = pp.order_id and o.funding = 'subscription'
    left join public.transport_quotes q on q.id = o.quote_id
    left join public.business_accounts b on b.id = o.business_id
   where pp.status <> 'cancelled' and pp.payment_circuit is null;
$f$;

-- 3. Tableau de bord ---------------------------------------------------------
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

  -- En attente de paiement du client.
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
       where o.status = 'awaiting_payment' and o.funding = 'card'
      union all
      select m.public_ref, coalesce(nullif(a.company_name, ''), nullif(a.full_name, ''), a.email),
             m.from_city || ' → ' || m.to_city,
             round(coalesce(m.client_total_due, m.client_price, 0) * 100)::bigint, m.created_at
        from public.missions m
        left join public.accounts a on a.id = m.client_account_id
       where m.payment_status = 'awaiting_payment' and m.cancelled_at is null
         and not exists (select 1 from public.transport_orders o where o.mission_id = m.id)
    ) x;

  -- Commissions dues par des transporteurs payés en espèces.
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
     and not coalesce(m.commission_settled_offline, false)
     and m.commission_paid_at is null;

  -- Versements aux transporteurs encore à faire (argent passé par SECOTO).
  select jsonb_build_object('nombre', count(*), 'montant_cents', coalesce(sum(pp.amount_cents), 0)::bigint)
    into v_a_verser
    from public.partner_payouts pp
   where pp.status in ('to_pay', 'processing', 'failed') and pp.payment_circuit is null;

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

-- 4. Déclaration URSSAF : commission de la période ---------------------------
-- p_debut inclus, p_fin exclu (dates en heure de Paris).
create or replace function public.secoto_dirigeant_urssaf(p_debut date, p_fin date)
returns jsonb language plpgsql stable security definer set search_path = ''
as $f$
declare
  v_total bigint;
  v_lignes jsonb;
begin
  perform secoto_private.assert_dirigeant();
  if p_debut is null or p_fin is null or p_fin <= p_debut then
    raise exception 'Période invalide.';
  end if;
  if p_fin - p_debut > 400 then
    raise exception 'Période trop longue (un an au plus).';
  end if;

  select coalesce(sum(l.commission_cents), 0),
         coalesce(jsonb_agg(jsonb_build_object(
           'jour', l.jour, 'reference', l.reference, 'client', l.client, 'trajet', l.trajet,
           'libelle', l.libelle, 'encaisse_cents', l.encaisse_cents, 'rembourse_cents', l.rembourse_cents,
           'reverse_cents', l.reverse_cents, 'commission_cents', l.commission_cents) order by l.jour), '[]'::jsonb)
    into v_total, v_lignes
    from secoto_private.dirigeant_lignes() l
   where (l.jour at time zone 'Europe/Paris')::date >= p_debut
     and (l.jour at time zone 'Europe/Paris')::date < p_fin;

  return jsonb_build_object(
    'debut', p_debut,
    'fin', p_fin,
    'commission_cents', v_total,
    -- L'URSSAF demande un montant en euros entiers : arrondi à l'euro le plus proche.
    'a_declarer_euros', round(greatest(v_total, 0) / 100.0)::bigint,
    'lignes', v_lignes);
end;
$f$;

-- 5. Litiges : contestations bancaires et SAV --------------------------------
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
   where p.dispute_status is not null;

  select jsonb_build_object(
           'ouvertes', count(*) filter (where s.status = 'ouverte'),
           'en_cours', count(*) filter (where s.status = 'en_cours'),
           'resolues', count(*) filter (where s.status = 'resolue'),
           'dommages_ouverts', count(*) filter (where s.status <> 'resolue' and s.motif = 'dommage'),
           'total', count(*))
    into v_sav
    from public.sav_requests s;

  return jsonb_build_object('contestations', v_contestations, 'sav', v_sav);
end;
$f$;

-- 6. Droits -----------------------------------------------------------------
revoke all on function secoto_private.is_dirigeant(uuid) from public, anon, authenticated;
revoke all on function secoto_private.assert_dirigeant() from public, anon, authenticated;
revoke all on function secoto_private.dirigeant_lignes() from public, anon, authenticated;
revoke all on function public.secoto_dirigeant_acces() from public;
revoke all on function public.secoto_dirigeant_tableau(integer) from public;
revoke all on function public.secoto_dirigeant_urssaf(date, date) from public;
revoke all on function public.secoto_dirigeant_litiges() from public;
do $grants$
begin
  if exists (select 1 from pg_roles where rolname = 'anon') then
    execute 'revoke all on function public.secoto_dirigeant_acces() from anon';
    execute 'revoke all on function public.secoto_dirigeant_tableau(integer) from anon';
    execute 'revoke all on function public.secoto_dirigeant_urssaf(date, date) from anon';
    execute 'revoke all on function public.secoto_dirigeant_litiges() from anon';
  end if;
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'grant execute on function public.secoto_dirigeant_acces() to authenticated';
    execute 'grant execute on function public.secoto_dirigeant_tableau(integer) to authenticated';
    execute 'grant execute on function public.secoto_dirigeant_urssaf(date, date) to authenticated';
    execute 'grant execute on function public.secoto_dirigeant_litiges() to authenticated';
  end if;
end
$grants$;
