-- ============================================================================
-- SECOTO — MIGRATION 145 : NAVETTE PRO (TARIF PROFESSIONNEL SUR LES AXES)
-- ----------------------------------------------------------------------------
-- Validé par Nawfal le 14/11/2026. Ouverture aux professionnels sur deux axes :
--   · Paris – Lyon – Côte d'Azur (et villes sur l'axe) : le transporteur prend
--     480 € TTC par voiture ;
--   · Paris – Belgique – Allemagne : 500 € TTC par voiture + 20 € de sécurité
--     pour SECOTO (au cas où le transporteur demande plus), soit 520 €.
-- Prix pro = prix transporteur + marge SECOTO : 75 € pour 1 véhicule, 60 € par
-- véhicule à partir de 2 (même commande). Enlèvement à l'adresse du pro,
-- livraison à l'adresse qu'il choisit (porte à porte, pas de ville à ville).
--
-- ANTI-FRICTION : l'offre « Navette Pro » n'existe QUE pour un compte pro
-- (accounts.client_type = 'pro', accès immédiat à l'inscription) ou un compte
-- entreprise. Un pro ne voit pas l'Éco particulier ; un particulier ne voit
-- jamais la Navette Pro (calcul en base, selon le compte, rien côté écran).
-- Le site public n'affiche aucun prix pro.
-- La Navette Pro n'est proposée que si elle est moins chère que le Standard ;
-- elle est alors l'offre recommandée.
--
-- Réglages : app_settings['navette_pro'] (axes, départements, pays, prix
-- transporteur, marges, fenêtre). ADDITIF, rejouable. Aucune commande
-- existante n'est modifiée. Ne touche à aucun interrupteur Apple.
-- ============================================================================

insert into public.app_settings(key, value)
values ('navette_pro', jsonb_build_object(
  'actif', true,
  'libelle', 'Navette Pro',
  'marge_1_vehicule_eur', 75,
  'marge_par_vehicule_2_plus_eur', 60,
  'fenetre_h', 168,
  'gabarits', jsonb_build_array('citadine', 'berline', 'grand'),
  'axes', jsonb_build_array(
    jsonb_build_object(
      'nom', 'Paris – Lyon – Côte d''Azur',
      'type', 'france',
      'transporteur_eur', 480,
      'departements', jsonb_build_array('75','77','78','91','92','93','94','95','89','21','71','69','01','38','26','84','13','83','06','98'),
      'pays', jsonb_build_array('MC'),
      'km_min', 250, 'km_max', 1100),
    jsonb_build_object(
      'nom', 'Paris – Belgique – Allemagne',
      'type', 'international',
      'transporteur_eur', 520,
      'departements', jsonb_build_array('75','77','78','91','92','93','94','95','60','02','80','62','59'),
      'pays', jsonb_build_array('BE','DE'),
      'km_min', 200, 'km_max', 1000))))
on conflict (key) do nothing;

-- Nouvelle offre « pro » acceptée sur les devis et les commandes.
alter table public.transport_quotes drop constraint if exists transport_quotes_offre_choisie_check;
alter table public.transport_quotes add constraint transport_quotes_offre_choisie_check
  check (offre_choisie is null or offre_choisie in ('express', 'standard', 'eco', 'pro'));
alter table public.transport_orders drop constraint if exists transport_orders_offre_check;
alter table public.transport_orders add constraint transport_orders_offre_check
  check (offre is null or offre in ('express', 'standard', 'eco', 'pro'));

create or replace function secoto_private.navette_pro_reglages()
returns jsonb language sql stable security definer set search_path = '' as $$
  select coalesce((select value from public.app_settings where key = 'navette_pro'), '{}'::jsonb);
$$;
revoke all on function secoto_private.navette_pro_reglages() from public, anon, authenticated;

-- Compte professionnel : client_type 'pro' (inscription = accès immédiat) ou compte entreprise.
create or replace function secoto_private.devis_compte_pro(q public.transport_quotes)
returns boolean language sql stable security definer set search_path = '' as $$
  select q.business_id is not null
      or exists (select 1 from public.accounts a where a.id = q.account_id and a.client_type = 'pro' and a.deleted_at is null);
$$;
revoke all on function secoto_private.devis_compte_pro(public.transport_quotes) from public, anon, authenticated;

-- Un lieu est-il sur cet axe ? (département français listé, ou pays listé)
create or replace function secoto_private.navette_lieu_sur_axe(p_lieu jsonb, p_axe jsonb, p_cote text)
returns boolean language sql stable security definer set search_path = '' as $$
  select case
    when secoto_private.od_pays(p_lieu) = 'FR' then
      p_cote in ('france', 'fr')
      and secoto_private.department_of(p_lieu ->> 'postcode') in (select jsonb_array_elements_text(p_axe -> 'departements'))
    else
      p_cote in ('france', 'etranger')
      and secoto_private.od_pays(p_lieu) in (select jsonb_array_elements_text(p_axe -> 'pays'))
  end;
$$;
revoke all on function secoto_private.navette_lieu_sur_axe(jsonb, jsonb, text) from public, anon, authenticated;

-- Offre Navette Pro d'un devis, ou null (pas un compte pro, hors axe, gabarit
-- non accepté, ou pas moins chère que le Standard).
create or replace function secoto_private.offre_navette_pro(q public.transport_quotes, p_std_client integer)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  s jsonb := secoto_private.navette_pro_reglages();
  v_vehicules jsonb := case when jsonb_array_length(coalesce(q.vehicles, '[]'::jsonb)) > 0 then q.vehicles else jsonb_build_array(q.vehicle) end;
  v jsonb;
  v_n integer := 0;
  v_places numeric := 0;
  v_p numeric;
  v_km numeric := coalesce((q.route ->> 'distance_km')::numeric, 0);
  a jsonb;
  v_axe jsonb;
  v_pay integer;
  v_marge integer;
  v_client integer;
begin
  if not coalesce((s ->> 'actif')::boolean, false) or not secoto_private.devis_compte_pro(q) or v_km <= 0 then
    return null;
  end if;

  -- Voitures roulantes uniquement (citadine, berline, 4x4) ; un 4x4 compte 1,5 place.
  for v in select value from jsonb_array_elements(v_vehicules) loop
    if coalesce(v ->> 'category', 'standard') <> 'standard'
       or not coalesce((v ->> 'rolling')::boolean, true)
       or coalesce(secoto_private.gabarit_vehicule(v), '') not in (select jsonb_array_elements_text(s -> 'gabarits')) then
      return null;
    end if;
    v_p := coalesce(secoto_private.places_eco(v), 1);
    v_places := v_places + v_p;
    v_n := v_n + 1;
  end loop;
  if v_n = 0 then return null; end if;

  -- Premier axe qui couvre le trajet.
  for a in select value from jsonb_array_elements(coalesce(s -> 'axes', '[]'::jsonb)) loop
    continue when v_km < coalesce((a ->> 'km_min')::numeric, 0) or v_km > coalesce((a ->> 'km_max')::numeric, 100000);
    if a ->> 'type' = 'international' then
      -- Un bout en France sur l'axe, l'autre dans un pays de l'axe.
      if (secoto_private.navette_lieu_sur_axe(q.pickup, a, 'fr') and secoto_private.navette_lieu_sur_axe(q.delivery, a, 'etranger'))
         or (secoto_private.navette_lieu_sur_axe(q.delivery, a, 'fr') and secoto_private.navette_lieu_sur_axe(q.pickup, a, 'etranger')) then
        v_axe := a; exit;
      end if;
    else
      if secoto_private.navette_lieu_sur_axe(q.pickup, a, 'france') and secoto_private.navette_lieu_sur_axe(q.delivery, a, 'france') then
        v_axe := a; exit;
      end if;
    end if;
  end loop;
  if v_axe is null then return null; end if;

  v_pay := round((v_axe ->> 'transporteur_eur')::numeric * v_places * 100)::int;
  v_marge := round(case when v_n = 1 then coalesce((s ->> 'marge_1_vehicule_eur')::numeric, 75)
                        else coalesce((s ->> 'marge_par_vehicule_2_plus_eur')::numeric, 60) * v_n end * 100)::int;
  v_client := v_pay + v_marge;
  if p_std_client is not null and v_client >= p_std_client then return null; end if;

  return jsonb_build_object(
    'cle', 'pro', 'libelle', coalesce(s ->> 'libelle', 'Navette Pro'),
    'client_cents', v_client, 'partenaire_cents', v_pay, 'commission_cents', v_marge,
    'fenetre_h', coalesce((s ->> 'fenetre_h')::int, 168),
    'axe', v_axe ->> 'nom', 'vehicules', v_n,
    'regles', 'Tarif professionnel : enlèvement à votre adresse, livraison à l''adresse de votre choix.',
    'recommande', true);
end;
$$;
revoke all on function secoto_private.offre_navette_pro(public.transport_quotes, integer) from public, anon, authenticated;

-- Offres d'un devis : Express, Standard, puis Éco (particuliers) ou Navette Pro (pros).
create or replace function secoto_private.calculer_offres(q public.transport_quotes)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  r jsonb := secoto_private.trois_offres_reglages();
  v_km numeric := (q.route ->> 'distance_km')::numeric;
  v_coef numeric := case when secoto_private.est_lourd(secoto_private.gabarit_vehicule(q.vehicle))  -- 144
                          then coalesce((secoto_private.bareme_v3_reglages() -> 'lourds' ->> 'express_coef')::numeric, 1.20)
                          else coalesce((r -> 'express' ->> 'coef')::numeric, 1.30) end;
  v_std_client integer := q.client_price_cents;
  v_std_pay integer := q.partner_pay_cents;
  v_exp_client integer;
  v_n integer;
  v_eco jsonb;
  v_navette jsonb;
  v_pro boolean;
  v_multi boolean := jsonb_array_length(coalesce(q.vehicles, '[]'::jsonb)) > 1;
  v_out jsonb := '[]'::jsonb;
begin
  if not secoto_private.flag('trois_offres') or q.mode <> 'plateau' or q.status <> 'priced'
     or v_std_client is null or v_std_pay is null or coalesce(v_km, 0) <= 0 or (q.vehicle ->> 'class') is null
     or coalesce(q.vehicle ->> 'category', 'standard') <> 'standard' then
    return null;
  end if;
  -- 145 : Navette Pro (comptes pros, sur les axes), y compris à plusieurs véhicules.
  v_pro := secoto_private.devis_compte_pro(q);
  v_navette := case when v_pro then secoto_private.offre_navette_pro(q, v_std_client) end;
  if v_multi and v_navette is null then return null; end if;

  -- Transporteurs vérifiés qui couvrent ce trajet (affiché au client, plus bloquant).
  select count(distinct secoto_private.carrier_rate_owner(a.id)) into v_n
    from public.accounts a
   where a.role::text = 'transporter' and a.deleted_at is null
     and secoto_private.carrier_eligible_for_trip(a.id, q.vehicle, q.pickup, q.pickup_at);

  v_exp_client := round(v_std_client * v_coef)::int;
  v_out := v_out || jsonb_build_array(jsonb_build_object(
    'cle', 'express', 'libelle', 'Express',
    'client_cents', v_exp_client, 'partenaire_cents', round(v_std_pay * v_coef)::int,
    'commission_cents', v_exp_client - round(v_std_pay * v_coef)::int,
    'fenetre_h', coalesce((r -> 'express' ->> 'fenetre_h')::int, 48), 'transporteurs', v_n, 'recommande', false));
  v_out := v_out || jsonb_build_array(jsonb_build_object(
    'cle', 'standard', 'libelle', 'Standard',
    'client_cents', v_std_client, 'partenaire_cents', v_std_pay, 'commission_cents', v_std_client - v_std_pay,
    'fenetre_h', coalesce((r -> 'standard' ->> 'fenetre_h')::int, 120), 'transporteurs', v_n,
    'recommande', v_navette is null));
  if v_navette is not null then
    v_out := v_out || jsonb_build_array(v_navette || jsonb_build_object('transporteurs', v_n));
  elsif not v_pro and secoto_private.flag('bareme_v3') then
    -- Éco : particuliers seulement (un pro ne la voit pas).
    v_eco := secoto_private.offre_eco_v3(q, v_std_client);
    if v_eco is not null then
      v_out := v_out || jsonb_build_array(v_eco || jsonb_build_object('transporteurs', v_n));
    end if;
  end if;
  return v_out;
end;
$$;
revoke all on function secoto_private.calculer_offres(public.transport_quotes) from public, anon, authenticated;

-- Devis fait avant connexion puis rattaché à un compte pro : offres recalculées.
select secoto_private.mig074_patch(
  'secoto_private.trg_quote_offres()'::regprocedure,
  $a$     or new.partner_pay_cents is distinct from old.partner_pay_cents then$a$,
  $b$     or new.partner_pay_cents is distinct from old.partner_pay_cents
     or new.account_id is distinct from old.account_id or new.business_id is distinct from old.business_id then  -- 145$b$);

-- Transporteurs : titre de la notification.
select secoto_private.mig074_patch(
  'secoto_private.od_broadcast(uuid)'::regprocedure,
  $a$when 'eco' then 'Mission Éco (délai long)' else 'Mission disponible' end,$a$,
  $b$when 'eco' then 'Mission Éco (délai long)' when 'pro' then 'Mission Navette Pro' else 'Mission disponible' end,$b$);

-- Statistiques admin : la Navette Pro a sa ligne.
select secoto_private.mig074_patch(
  'public.secoto_admin_offres_stats(integer)'::regprocedure,
  $a$    with k(cle) as (values ('express'), ('standard'), ('eco')),$a$,
  $b$    with k(cle) as (values ('express'), ('standard'), ('eco'), ('pro')),$b$);
select secoto_private.mig074_patch(
  'public.secoto_admin_offres_stats(integer)'::regprocedure,
  $a$order by array_position(array['express', 'standard', 'eco'], k.cle)$a$,
  $b$order by array_position(array['express', 'standard', 'eco', 'pro'], k.cle)$b$);

notify pgrst, 'reload schema';
