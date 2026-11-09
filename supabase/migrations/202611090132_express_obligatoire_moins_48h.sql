-- ============================================================================
-- SECOTO — MIGRATION 132 : EXPRESS OBLIGATOIRE POUR UN DÉPART À MOINS DE 48 H
-- ----------------------------------------------------------------------------
-- Demande de Nawfal du 09/11/2026 : des clients réservaient pour le lendemain
-- au tarif Standard (fenêtre de 5 jours), alors qu'un départ si proche relève
-- de l'Express. Désormais, quand l'enlèvement est prévu dans moins de 48 h :
--   · seule l'offre Express peut être réservée ; Standard et Éco sont refusées
--     avec la date à partir de laquelle elles redeviennent possibles ;
--   · le devis envoyé à l'application indique « express_obligatoire » et
--     « standard_des » : l'écran grise Standard et propose de changer la date.
-- Les commandes déjà passées ne changent pas. ADDITIF, rejouable.
-- ============================================================================

-- Heure d'enlèvement du devis (créneau du matin par défaut si seule la date est connue).
create or replace function secoto_private.depart_du_devis(q public.transport_quotes)
returns timestamptz language sql stable set search_path = '' as $$
  select coalesce(q.pickup_at,
    case when nullif(q.schedule ->> 'pickup_date', '') is not null
      then ((q.schedule ->> 'pickup_date')::date + time '08:00') at time zone 'Europe/Paris' end);
$$;
revoke all on function secoto_private.depart_du_devis(public.transport_quotes) from public, anon, authenticated;

create or replace function secoto_private.express_obligatoire(q public.transport_quotes)
returns boolean language sql stable set search_path = '' as $$
  select coalesce(secoto_private.depart_du_devis(q) < now() + interval '48 hours', false);
$$;
revoke all on function secoto_private.express_obligatoire(public.transport_quotes) from public, anon, authenticated;

-- Premier jour où l'offre Standard redevient possible (même heure de créneau).
create or replace function secoto_private.standard_possible_des(q public.transport_quotes)
returns date language sql stable set search_path = '' as $$
  with l as (
    select now() + interval '48 hours' as limite,
           coalesce((secoto_private.depart_du_devis(q) at time zone 'Europe/Paris')::time, time '08:00') as heure
  )
  select case when (((l.limite at time zone 'Europe/Paris')::date + l.heure) at time zone 'Europe/Paris') >= l.limite
              then (l.limite at time zone 'Europe/Paris')::date
              else (l.limite at time zone 'Europe/Paris')::date + 1 end
    from l;
$$;
revoke all on function secoto_private.standard_possible_des(public.transport_quotes) from public, anon, authenticated;

-- Réservation : Standard / Éco refusées à moins de 48 h du départ.
select secoto_private.mig074_patch(
  'public.secoto_od_book_offre(uuid,text,uuid)'::regprocedure,
  '  if v_quote.offre_choisie is null then',
  '  -- 132 : départ à moins de 48 h -> Express obligatoire.
  if v_quote.offre_choisie is null and p_offre <> ''express'' and secoto_private.express_obligatoire(v_quote) then
    raise exception ''Départ dans moins de 48 h : seule l''''offre Express est possible. Pour le tarif Standard, choisissez un départ à partir du %.'',
      to_char(secoto_private.standard_possible_des(v_quote), ''DD/MM/YYYY'');
  end if;
  if v_quote.offre_choisie is null then');

-- Devis envoyé à l'application : l'écran grise Standard et propose de changer la date.
select secoto_private.mig074_patch(
  'secoto_private.quote_client_json(public.transport_quotes)'::regprocedure,
  '    ''offre_choisie'', q.offre_choisie,',
  '    ''offre_choisie'', q.offre_choisie,
    ''express_obligatoire'', secoto_private.express_obligatoire(q),  -- 132
    ''standard_des'', secoto_private.standard_possible_des(q),');

notify pgrst, 'reload schema';
