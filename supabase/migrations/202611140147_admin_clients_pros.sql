-- ============================================================================
-- SECOTO — MIGRATION 147 : ONGLET ADMIN « CLIENTS PROS »
-- ----------------------------------------------------------------------------
-- Demandé par Nawfal le 14/11/2026 : toutes les infos des clients pros dans un
-- onglet dédié de l'espace admin. Une seule fonction, LECTURE SEULE, réservée à
-- l'administrateur : identité du compte, entreprise, provenance, devis,
-- commandes (en cours, livrées, annulées), chiffre d'affaires, marge, Navette
-- Pro, trajets les plus fréquents et dernières commandes.
-- Client pro = compte client avec client_type = 'pro', ou membre d'un compte
-- entreprise client (les comptes entreprise des transporteurs sont exclus).
-- Comptes internes SECOTO et commandes de test exclus. ADDITIF, rejouable.
-- ============================================================================

create or replace function public.secoto_admin_clients_pros()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_out jsonb;
begin
  perform secoto_private.assert_admin();

  with pros as (
    select a.*
      from public.accounts a
     where a.role::text = 'client' and a.deleted_at is null and not coalesce(a.is_internal, false)
       and (a.client_type = 'pro'
            or exists (select 1 from public.business_members m join public.business_accounts b on b.id = m.business_id
                        where m.account_id = a.id and b.archived_at is null and coalesce(b.kind, '') <> 'transporteur'))
  ),
  q as (
    select q.account_id, count(*) as devis,
           count(*) filter (where q.created_at > now() - interval '30 days') as devis_30j,
           max(q.created_at) as dernier_devis_at
      from public.transport_quotes q
     where q.account_id in (select id from pros) and q.supprime_le is null
     group by 1
  ),
  o as (
    select o.*, q.pickup, q.delivery,
           greatest(jsonb_array_length(coalesce(q.vehicles, '[]'::jsonb)), 1) as nb_vehicules
      from public.transport_orders o
      left join public.transport_quotes q on q.id = o.quote_id
     where o.account_id in (select id from pros) and not coalesce(o.is_test, false)
  ),
  agg as (
    select o.account_id,
           count(*) as commandes,
           count(*) filter (where o.status = 'delivered') as livrees,
           count(*) filter (where o.status = 'cancelled') as annulees,
           count(*) filter (where o.status not in ('delivered', 'cancelled')) as en_cours,
           count(*) filter (where o.offre = 'pro') as navette,
           coalesce(sum(o.nb_vehicules) filter (where o.status <> 'cancelled'), 0) as vehicules,
           coalesce(sum(o.client_price_cents) filter (where o.status <> 'cancelled'), 0) as ca_cents,
           coalesce(sum(o.client_price_cents - coalesce(o.partner_pay_cents, 0)) filter (where o.status <> 'cancelled'), 0) as marge_cents,
           coalesce(sum(o.client_price_cents) filter (where o.status = 'delivered'), 0) as ca_livre_cents,
           max(o.created_at) as derniere_commande_at
      from o group by 1
  )
  select jsonb_build_object(
    'total', jsonb_build_object(
      'comptes', (select count(*) from pros),
      'actifs', (select count(*) from agg where commandes > 0),
      'nouveaux_30j', (select count(*) from pros where created_at > now() - interval '30 days'),
      'devis_30j', coalesce((select sum(devis_30j) from q), 0),
      'commandes', coalesce((select sum(commandes) from agg), 0),
      'livrees', coalesce((select sum(livrees) from agg), 0),
      'en_cours', coalesce((select sum(en_cours) from agg), 0),
      'navette', coalesce((select sum(navette) from agg), 0),
      'ca_cents', coalesce((select sum(ca_cents) from agg), 0),
      'marge_cents', coalesce((select sum(marge_cents) from agg), 0)),
    'clients', coalesce((select jsonb_agg(c order by (c ->> 'tri') desc) from (
      select jsonb_build_object(
        'id', p.id, 'nom', p.full_name, 'societe', p.company_name, 'email', p.email, 'telephone', p.phone,
        'ville', p.city, 'inscrit_le', p.created_at, 'statut', p.status,
        'siren', coalesce(p.billing_siren, (select b.siren from public.business_members m join public.business_accounts b on b.id = m.business_id
                                             where m.account_id = p.id and coalesce(b.kind, '') <> 'transporteur' limit 1)),
        'raison_sociale', p.billing_legal_name,
        'entreprise', (select b.name from public.business_members m join public.business_accounts b on b.id = m.business_id
                        where m.account_id = p.id and coalesce(b.kind, '') <> 'transporteur' limit 1),
        'carte_enregistree', p.stripe_customer_id is not null,
        'source', p.utm_source, 'campagne', p.utm_campaign,
        'devis', coalesce(q.devis, 0), 'devis_30j', coalesce(q.devis_30j, 0), 'dernier_devis_at', q.dernier_devis_at,
        'commandes', coalesce(g.commandes, 0), 'livrees', coalesce(g.livrees, 0), 'annulees', coalesce(g.annulees, 0),
        'en_cours', coalesce(g.en_cours, 0), 'navette', coalesce(g.navette, 0), 'vehicules', coalesce(g.vehicules, 0),
        'ca_cents', coalesce(g.ca_cents, 0), 'marge_cents', coalesce(g.marge_cents, 0), 'ca_livre_cents', coalesce(g.ca_livre_cents, 0),
        'derniere_commande_at', g.derniere_commande_at,
        'trajets', coalesce((select jsonb_agg(t.trajet) from (
            select coalesce(o.pickup ->> 'city', '?') || ' → ' || coalesce(o.delivery ->> 'city', '?') as trajet
              from o where o.account_id = p.id and o.status <> 'cancelled'
             group by 1 order by count(*) desc, 1 limit 3) t), '[]'::jsonb),
        'commandes_recentes', coalesce((select jsonb_agg(r order by r ->> 'cree_le' desc) from (
            select jsonb_build_object('ref', o.public_ref, 'statut', o.status, 'offre', o.offre,
                     'prix_cents', o.client_price_cents, 'marge_cents', o.client_price_cents - coalesce(o.partner_pay_cents, 0),
                     'vehicules', o.nb_vehicules, 'depart', o.pickup ->> 'city', 'arrivee', o.delivery ->> 'city',
                     'enlevement_le', o.pickup_at, 'cree_le', o.created_at, 'reglement', o.mode_reglement) as r
              from o where o.account_id = p.id order by o.created_at desc limit 10) x), '[]'::jsonb),
        'tri', coalesce(g.derniere_commande_at, q.dernier_devis_at, p.created_at)) as c
      from pros p
      left join q on q.account_id = p.id
      left join agg g on g.account_id = p.id) s), '[]'::jsonb))
  into v_out;
  return v_out;
end;
$$;
revoke all on function public.secoto_admin_clients_pros() from public, anon;
grant execute on function public.secoto_admin_clients_pros() to authenticated;

notify pgrst, 'reload schema';
