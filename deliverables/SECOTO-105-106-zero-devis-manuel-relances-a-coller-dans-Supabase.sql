-- SECOTO 105 + 106 — à coller dans Supabase › SQL Editor, en une seule fois, AVANT le git push.
-- Aucun prélèvement, aucun envoi immédiat : les relances partent ensuite toutes seules (maintenance Netlify).

-- ============================================================================
-- SECOTO — MIGRATION 105 : PLUS AUCUN DEVIS MANUEL, MARGE TOUJOURS GARANTIE
-- ----------------------------------------------------------------------------
-- Décision de Nawfal du 20/10/2026 : « il ne doit plus y avoir de devis manuel
-- du tout, et on doit rester rentable, même si la marge n'est pas énorme une
-- fois les frais Stripe payés ». 33 devis manuels sur 117 en 14 jours.
--
-- Chaque cas qui bloquait le prix devient une ligne de supplément, visible par
-- le client dans le détail du prix (rien de caché) :
--   · contrainte particulière (sans clé, garde au sol basse, gabarit hors norme,
--     non immatriculé, accès difficile) : + 60 € client / + 45 € transporteur
--     par contrainte ;
--   · véhicule de prestige (camion fermé) : + 30 % ;
--   · délai trop court (moins de 12 h) : + 20 % ;
--   · catégorie hors barème (« autre ») : tarif utilitaire ;
--   · trajet international hors zone (Suisse, Royaume-Uni, Maroc…) : + 30 % ;
--   · Corse <-> continent : traversée maritime + 30 % ;
--   · convoyage sans clé ou non immatriculé : refusé à la saisie (plateau proposé).
--   · itinéraire non calculable : distance estimée (vol d'oiseau × 1,35),
--     signalée dans le détail du prix ;
--   · distance au-delà du plafond automatique : tarifée au barème.
-- Marge : si la marge passe sous le minimum du barème (10 %), le prix client
-- est relevé jusqu'à ce minimum au lieu de partir en devis manuel. 10 % de
-- marge brute laissent environ 6 % une fois les frais de paiement payés
-- (carte ≈ 1,5 % + 0,25 €, Klarna ≈ 3,3 % + 0,35 €).
--
-- Tous les montants sont des réglages du barème (modifiables sans code) et de
-- app_settings['international_policy']. Les devis déjà émis ne changent pas.
-- Les seuls motifs restants sont des impossibilités : véhicule non roulant en
-- convoyage (déjà refusé à la saisie), coordonnées absentes, barème absent.
-- Rejouable.
-- ============================================================================

-- 1. Réglages par défaut, visibles dans les barèmes actifs ---------------------
update public.pricing_grids
   set params = jsonb_build_object(
         'luxury_pct', 30, 'constraint_client_eur', 60, 'constraint_partner_eur', 45, 'short_notice_pct', 20)
       || params
 where status = 'active';

-- « Véhicule de prestige : devis personnalisé » n'est plus vrai : retiré des
-- exclusions affichées (le supplément prestige figure dans le détail du prix).
update public.pricing_grids
   set params = jsonb_set(params, '{excluded}', coalesce((
         select jsonb_agg(e) from jsonb_array_elements(params -> 'excluded') e
          where e::text not ilike '%prestige%'), '[]'::jsonb))
 where status = 'active' and params -> 'excluded' is not null and params::text ilike '%prestige%devis personnalisé%';

insert into public.app_settings(key, value)
values ('international_policy', jsonb_build_object('pays_prix_immediat', jsonb_build_array('FR', 'MC'), 'hors_zone_pct', 30, 'corse_pct', 30))
on conflict (key) do update
  set value = jsonb_build_object('hors_zone_pct', 30, 'corse_pct', 30) || public.app_settings.value;

insert into public.app_settings(key, value)
values ('distance_estimee', jsonb_build_object('facteur_route', 1.35, 'max_km', 6000))
on conflict (key) do nothing;

-- 2. Distance estimée quand aucun itinéraire n'a pu être calculé --------------
create or replace function secoto_private.od_distance_estimee(p_from jsonb, p_to jsonb)
returns numeric language plpgsql stable security definer set search_path = '' as $$
declare
  v_lat1 double precision; v_lng1 double precision; v_lat2 double precision; v_lng2 double precision;
  v_facteur numeric; v_max numeric; v_km numeric;
begin
  begin
    v_lat1 := (p_from ->> 'lat')::double precision; v_lng1 := (p_from ->> 'lng')::double precision;
    v_lat2 := (p_to ->> 'lat')::double precision;   v_lng2 := (p_to ->> 'lng')::double precision;
  exception when others then return null;
  end;
  if v_lat1 is null or v_lng1 is null or v_lat2 is null or v_lng2 is null then return null; end if;
  select coalesce((s.value ->> 'facteur_route')::numeric, 1.35), coalesce((s.value ->> 'max_km')::numeric, 6000)
    into v_facteur, v_max from public.app_settings s where s.key = 'distance_estimee';
  v_facteur := coalesce(v_facteur, 1.35); v_max := coalesce(v_max, 6000);
  -- Haversine (rayon terrestre 6 371 km), puis facteur routier.
  v_km := 2 * 6371 * asin(sqrt(
            power(sin(radians(v_lat2 - v_lat1) / 2), 2)
          + cos(radians(v_lat1)) * cos(radians(v_lat2)) * power(sin(radians(v_lng2 - v_lng1) / 2), 2)));
  v_km := round(v_km * v_facteur, 1);
  if v_km <= 0 or v_km > v_max then return null; end if;
  return greatest(v_km, 1);
end;
$$;

-- 3. Majoration d'un prix déjà calculé (trajet hors zone…) --------------------
create or replace function secoto_private.od_majorer(p_price jsonb, p_pct numeric, p_label text)
returns jsonb language plpgsql immutable set search_path = '' as $$
declare v_client integer; v_partner integer;
begin
  if p_price is null or p_price ? 'manual_reason' or coalesce(p_pct, 0) <= 0 then return p_price; end if;
  v_client := round((p_price ->> 'client_cents')::numeric * (1 + p_pct / 100));
  v_partner := round((p_price ->> 'partner_cents')::numeric * (1 + p_pct / 100));
  return p_price || jsonb_build_object(
    'client_cents', v_client, 'partner_cents', v_partner, 'margin_cents', v_client - v_partner,
    'collect_cents', v_client,
    'lines', coalesce(p_price -> 'lines', '[]'::jsonb) || jsonb_build_array(jsonb_build_object(
      'label', format('%s (+%s %%)', p_label, trim(trailing '.' from trim(trailing '0' from p_pct::text))),
      'eur', round((v_client - (p_price ->> 'client_cents')::numeric) / 100, 2))));
end;
$$;

create or replace function secoto_private.od_hors_zone(p_price jsonb, p_pickup jsonb, p_delivery jsonb)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_pct numeric;
begin
  if p_price is null or p_price ? 'manual_reason' then return p_price; end if;
  -- Corse <-> continent : traversée maritime facturée (même taux réglable).
  if secoto_private.od_raison_internationale(p_pickup, p_delivery) is null then
    if (coalesce(p_pickup ->> 'postcode', '') like '20%') <> (coalesce(p_delivery ->> 'postcode', '') like '20%')
       and secoto_private.od_pays(p_pickup) = 'FR' and secoto_private.od_pays(p_delivery) = 'FR' then
      select coalesce((s.value ->> 'corse_pct')::numeric, 30) into v_pct
        from public.app_settings s where s.key = 'international_policy';
      return secoto_private.od_majorer(p_price, coalesce(v_pct, 30), 'Traversée maritime Corse');
    end if;
    return p_price;
  end if;
  select coalesce((s.value ->> 'hors_zone_pct')::numeric, 30) into v_pct
    from public.app_settings s where s.key = 'international_policy';
  return secoto_private.od_majorer(p_price, coalesce(v_pct, 30), 'Trajet international hors zone (formalités, traversée)');
end;
$$;

-- 4. Barème : plus de motif manuel, des suppléments à la place ----------------
-- Catégorie hors barème : tarif utilitaire.
select secoto_private.mig074_patch('secoto_private.price_with_grid(text,jsonb,numeric,jsonb,numeric)'::regprocedure,
  $a$if not (v_class in (select jsonb_array_elements_text(coalesce(p -> 'auto_vehicle_classes', '[]'::jsonb)))) then$a$,
  $n$if false and not (v_class in (select jsonb_array_elements_text(coalesce(p -> 'auto_vehicle_classes', '[]'::jsonb)))) then  -- 105$n$);
select secoto_private.mig074_patch('secoto_private.price_with_grid(text,jsonb,numeric,jsonb,numeric)'::regprocedure,
  $a$v_rule := p -> 'class_rates' -> v_class;$a$,
  $n$v_rule := coalesce(p -> 'class_rates' -> v_class, p -> 'class_rates' -> 'utilitaire');  -- 105 : hors barème = tarif utilitaire$n$);
-- Distance au-delà du plafond automatique : tarifée normalement (plafonds de prix du barème).
select secoto_private.mig074_patch('secoto_private.price_with_grid(text,jsonb,numeric,jsonb,numeric)'::regprocedure,
  $a$if p ? 'auto_max_km' and v_km > (p ->> 'auto_max_km')::numeric then$a$,
  $n$if false and p ? 'auto_max_km' then  -- 105 : plus de plafond kilométrique bloquant$n$);
-- Prestige, contraintes, délai court : tarifés plus bas (suppléments).
select secoto_private.mig074_patch('secoto_private.price_with_grid(text,jsonb,numeric,jsonb,numeric)'::regprocedure,
  $a$if coalesce(p_vehicle ->> 'category', 'standard') = 'luxury' and not coalesce((p ->> 'luxury_auto')::boolean, false) then$a$,
  $n$if false and coalesce(p_vehicle ->> 'category', 'standard') = 'luxury' then  -- 105 : supplément prestige$n$);
select secoto_private.mig074_patch('secoto_private.price_with_grid(text,jsonb,numeric,jsonb,numeric)'::regprocedure,
  $a$and not coalesce((p ->> 'constraints_auto')::boolean, false) then$a$,
  $n$and false then  -- 105 : supplément par contrainte$n$);
select secoto_private.mig074_patch('secoto_private.price_with_grid(text,jsonb,numeric,jsonb,numeric)'::regprocedure,
  $a$if p_hours_to_pickup is not null and p_hours_to_pickup < coalesce((p ->> 'min_notice_hours')::numeric, 0) then$a$,
  $n$if false and p_hours_to_pickup is not null then  -- 105 : supplément délai court$n$);
select secoto_private.mig074_patch('secoto_private.price_with_grid(text,jsonb,numeric,jsonb,numeric)'::regprocedure,
  $a$-- Plafond de remuneration : au-dela, la distance ne paie plus davantage$a$,
  $n$-- 105 : suppléments à la place des devis manuels (montants du barème).
    if coalesce(p_vehicle ->> 'category', 'standard') = 'luxury' and not coalesce((p ->> 'luxury_auto')::boolean, false) then
      v_lines := v_lines || jsonb_build_object('label',
        format('Véhicule de prestige, camion fermé (+%s %%)', coalesce((p ->> 'luxury_pct')::numeric, 30)),
        'eur', round(v_client * coalesce((p ->> 'luxury_pct')::numeric, 30) / 100, 2));
      v_client := v_client * (1 + coalesce((p ->> 'luxury_pct')::numeric, 30) / 100);
      v_partner := v_partner * (1 + coalesce((p ->> 'luxury_pct')::numeric, 30) / 100);
    end if;
    if jsonb_typeof(p_vehicle -> 'constraints') = 'array' and not coalesce((p ->> 'constraints_auto')::boolean, false)
       and exists (select 1 from jsonb_array_elements_text(p_vehicle -> 'constraints') as c(v) where c.v <> all (secoto_private.contraintes_sans_devis(p))) then
      v_lines := v_lines || jsonb_build_object('label',
        format('Contraintes particulières (%s)', (select string_agg(replace(c.v, '_', ' '), ', ')
          from jsonb_array_elements_text(p_vehicle -> 'constraints') as c(v) where c.v <> all (secoto_private.contraintes_sans_devis(p)))),
        'eur', round(coalesce((p ->> 'constraint_client_eur')::numeric, 60) * (select count(*)
          from jsonb_array_elements_text(p_vehicle -> 'constraints') as c(v) where c.v <> all (secoto_private.contraintes_sans_devis(p))), 2));
      v_client := v_client + coalesce((p ->> 'constraint_client_eur')::numeric, 60) * (select count(*)
          from jsonb_array_elements_text(p_vehicle -> 'constraints') as c(v) where c.v <> all (secoto_private.contraintes_sans_devis(p)));
      v_partner := v_partner + coalesce((p ->> 'constraint_partner_eur')::numeric, 45) * (select count(*)
          from jsonb_array_elements_text(p_vehicle -> 'constraints') as c(v) where c.v <> all (secoto_private.contraintes_sans_devis(p)));
    end if;
    if p_hours_to_pickup is not null and p_hours_to_pickup < coalesce((p ->> 'min_notice_hours')::numeric, 0) then
      v_lines := v_lines || jsonb_build_object('label',
        format('Délai court (+%s %%)', coalesce((p ->> 'short_notice_pct')::numeric, 20)),
        'eur', round(v_client * coalesce((p ->> 'short_notice_pct')::numeric, 20) / 100, 2));
      v_client := v_client * (1 + coalesce((p ->> 'short_notice_pct')::numeric, 20) / 100);
      v_partner := v_partner * (1 + coalesce((p ->> 'short_notice_pct')::numeric, 20) / 100);
    end if;

    -- Plafond de remuneration : au-dela, la distance ne paie plus davantage$n$);
-- Marge insuffisante : le prix client est relevé jusqu'au minimum du barème.
select secoto_private.mig074_patch('secoto_private.price_with_grid(text,jsonb,numeric,jsonb,numeric)'::regprocedure,
  $a$      return jsonb_build_object('manual_reason', 'marge_insuffisante');$a$,
  $n$      -- 105 : marge garantie, jamais de devis manuel.
      v_lines := v_lines || jsonb_build_object('label', 'Ajustement tarifaire',
        'eur', round(v_partner / (1 - coalesce((p ->> 'min_margin_pct')::numeric, 0) / 100) - v_client, 2));
      v_client := round(v_partner / (1 - coalesce((p ->> 'min_margin_pct')::numeric, 0) / 100), 2);
      v_margin := round(v_client - v_partner, 2);$n$);

-- 5. Création du devis : distance estimée et trajets hors zone tarifés --------
select secoto_private.mig074_patch('public.secoto_quote_create(uuid,jsonb,jsonb)'::regprocedure,
  $a$v_reason := 'itineraire_indisponible';$a$,
  $n$-- 105 : itinéraire non calculable -> distance estimée, signalée au client.
    v_distance := secoto_private.od_distance_estimee(v_pickup, v_delivery);
    if v_distance is null then
      v_reason := 'itineraire_indisponible';
    else
      p_route := jsonb_build_object('distance_km', v_distance, 'provider', 'estimation', 'estimee', true);
      v_price := secoto_private.price_with_grid(v_mode, v_grid.params, v_distance, v_vehicle,
        extract(epoch from (v_pickup_at - now())) / 3600);
      if v_price ? 'lines' then
        v_price := v_price || jsonb_build_object('lines', (v_price -> 'lines') || jsonb_build_array(jsonb_build_object(
          'label', format('Distance estimée : %s km (itinéraire non calculable automatiquement)', v_distance), 'eur', 0)));
      end if;
      v_price := secoto_private.od_hors_zone(v_price, v_pickup, v_delivery);
      v_reason := v_price ->> 'manual_reason';
    end if;$n$);
select secoto_private.mig074_patch('public.secoto_quote_create(uuid,jsonb,jsonb)'::regprocedure,
  $a$v_reason := coalesce(v_price ->> 'manual_reason', secoto_private.od_raison_internationale(v_pickup, v_delivery));$a$,
  $n$v_price := secoto_private.od_hors_zone(v_price, v_pickup, v_delivery);  -- 105 : hors zone tarifé
    v_reason := v_price ->> 'manual_reason';$n$);

-- Convoyage d'un véhicule sans clé ou non immatriculé : impossible sur route.
-- Le client est orienté vers le plateau dès la saisie (comme un non roulant).
select secoto_private.mig074_patch('public.secoto_quote_create(uuid,jsonb,jsonb)'::regprocedure,
  $a$v_distance := nullif(p_route ->> 'distance_km', '')::numeric;$a$,
  $n$if v_mode = 'convoyage' and exists (select 1 from jsonb_array_elements_text(coalesce(v_vehicle -> 'constraints', '[]'::jsonb)) as c(v)
                                      where c.v in ('sans_cle', 'non_immatricule')) then  -- 105
    raise exception 'Véhicule sans clé ou non immatriculé : il ne peut pas rouler, choisissez le transport sur plateau.';
  end if;
  v_distance := nullif(p_route ->> 'distance_km', '')::numeric;$n$);

revoke all on function secoto_private.od_distance_estimee(jsonb, jsonb) from public, anon, authenticated;
revoke all on function secoto_private.od_majorer(jsonb, numeric, text) from public, anon, authenticated;
revoke all on function secoto_private.od_hors_zone(jsonb, jsonb, jsonb) from public, anon, authenticated;

notify pgrst, 'reload schema';

-- ============================================================================
-- SECOTO — MIGRATION 106 : RELANCES AUTOMATIQUES DES DEVIS NON RÉSERVÉS
-- ----------------------------------------------------------------------------
-- Décision de Nawfal du 20/10/2026. Sur 14 jours, 63 prix affichés sont partis
-- sans réservation. Le visiteur qui a laissé son e-mail reçoit au plus trois
-- rappels, puis plus rien :
--   · 2 h après son prix : « votre prix est toujours disponible » ;
--   · 24 h après : 0 € aujourd'hui, règlement à l'arrivée, Klarna ;
--   · 72 h après : dernier rappel, avec la date jusqu'à laquelle le prix est
--     garanti.
-- Chaque rappel contient un lien qui rouvre le devis (création du compte en
-- 30 secondes puis réservation, même chemin que le lien de paiement 093). Si
-- le devis avait expiré, il est réactivé au même prix et sa validité prolongée
-- (72 h par défaut). Arrêt immédiat dès qu'une commande existe, que la date
-- d'enlèvement approche (moins de 12 h) ou que le devis a plus de 10 jours.
-- Un devis déjà ancien ne reçoit qu'un seul rappel : celui de son étape.
-- Interrupteur : app_settings['relances_devis'].actif (allumé).
-- Sans e-mail (téléphone seul) : compté dans « À traiter » pour un rappel
-- téléphonique (aucun SMS automatique : pas de fournisseur SMS configuré).
-- ADDITIF : un réglage, deux fonctions nouvelles, une fonction complétée.
-- Rejouable.
-- ============================================================================

insert into public.app_settings(key, value)
values ('relances_devis', jsonb_build_object('actif', true, 'etapes_h', jsonb_build_array(2, 24, 72),
        'prolongation_h', 72, 'age_max_jours', 10, 'delai_min_enlevement_h', 12))
on conflict (key) do nothing;

create or replace function public.secoto_devis_relances(p_limit integer default 50)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_cfg jsonb;
  v_etapes integer[];
  r record;
  v_etape integer;
  v_token text;
  v_lien text;
  v_jusqu_au timestamptz;
  v_prix text;
  v_tiers text;
  v_trajet text;
  v_objet text;
  v_corps text;
  v_envoyes integer := 0;
begin
  select value into v_cfg from public.app_settings where key = 'relances_devis';
  if not coalesce((v_cfg ->> 'actif')::boolean, false) then
    return jsonb_build_object('actif', false);
  end if;
  select array_agg(x::integer order by x::integer) into v_etapes
    from jsonb_array_elements_text(coalesce(v_cfg -> 'etapes_h', '[2,24,72]'::jsonb)) x;

  for r in
    select q.* from public.transport_quotes q
     where q.account_id is null
       and q.contact_email is not null
       and coalesce(q.client_price_cents, 0) > 0
       and q.status in ('priced', 'manual_priced', 'expired')
       and q.created_at > now() - make_interval(days => coalesce((v_cfg ->> 'age_max_jours')::int, 10))
       and q.pickup_at > now() + make_interval(hours => coalesce((v_cfg ->> 'delai_min_enlevement_h')::int, 12))
       and not exists (select 1 from public.transport_orders o where o.quote_id = q.id)
     order by q.created_at
     limit greatest(coalesce(p_limit, 50), 1)
  loop
    -- Étape la plus avancée déjà atteinte ; une seule par devis.
    select max(i) into v_etape from generate_subscripts(v_etapes, 1) i
     where r.created_at + make_interval(hours => v_etapes[i]) <= now();
    continue when v_etape is null;
    continue when exists (
      select 1 from public.email_outbox e
       where e.event_key like 'relance-devis:' || r.id::text || ':%'
         and split_part(e.event_key, ':', 3)::int >= v_etape);

    -- Lien de reprise et prix toujours disponible.
    v_token := r.anon_token;
    v_jusqu_au := greatest(coalesce(r.valid_until, now()), now() + make_interval(hours => coalesce((v_cfg ->> 'prolongation_h')::int, 72)));
    v_jusqu_au := least(v_jusqu_au, r.pickup_at - interval '12 hours');
    update public.transport_quotes
       set anon_token = coalesce(anon_token, replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', '')),
           status = case when status = 'expired' then case when manual_reason is null then 'priced' else 'manual_priced' end else status end,
           valid_until = greatest(coalesce(valid_until, now()), v_jusqu_au),
           updated_at = now()
     where id = r.id
    returning anon_token into v_token;

    v_trajet := coalesce(r.pickup ->> 'city', '') || ' → ' || coalesce(r.delivery ->> 'city', '');
    v_prix := replace(to_char(r.client_price_cents / 100.0, 'FM999G990D00'), '.', ',') || ' €';
    v_tiers := replace(to_char(ceil(r.client_price_cents / 3.0) / 100.0, 'FM999G990D00'), '.', ',') || ' €';
    v_lien := 'https://app.secoto-transport.fr/?reprendre=' || v_token
      || '&prix=' || r.client_price_cents
      || '&trajet=' || replace(replace(v_trajet, ' ', '%20'), '→', '%E2%86%92');

    v_objet := case v_etape
      when 1 then format('Votre prix SECOTO : %s pour %s', v_prix, v_trajet)
      when 2 then format('%s : 0 € aujourd''hui, vous réglez à l''arrivée', v_trajet)
      else format('Dernier rappel : votre prix %s est garanti jusqu''au %s', v_prix, to_char(v_jusqu_au at time zone 'Europe/Paris', 'DD/MM'))
    end;
    v_corps := format(E'Bonjour,\n\nVotre prix pour le transport %s (%s) : %s tout compris.\n\n'
      || E'• 0 € aujourd''hui : votre carte est seulement enregistrée, vous réglez à l''arrivée du véhicule.\n'
      || E'• Paiement par carte, virement%s, ou en plusieurs fois avec Klarna (par exemple 3 × %s, sous réserve d''acceptation).\n'
      || E'• Ce prix est garanti jusqu''au %s.\n\n'
      || E'Réservez en 1 minute :\n%s\n\n'
      || E'Une question ? Répondez simplement à cet e-mail.\n\nL''équipe SECOTO\n\n'
      || E'Vous recevez ce message parce que vous avez demandé ce prix sur SECOTO. Pour ne plus recevoir de rappel, répondez « STOP ».',
      v_trajet, coalesce(nullif(btrim(r.vehicle ->> 'model'), ''), 'votre véhicule'), v_prix,
      case when r.client_price_cents <= 100000 then ', espèces' else '' end, v_tiers,
      to_char(v_jusqu_au at time zone 'Europe/Paris', 'DD/MM/YYYY'), v_lien);

    insert into public.email_outbox (to_email, subject, body_text, event_key)
    values (r.contact_email, v_objet, v_corps, 'relance-devis:' || r.id::text || ':' || v_etape)
    on conflict do nothing;
    v_envoyes := v_envoyes + 1;
  end loop;
  return jsonb_build_object('actif', true, 'relances', v_envoyes);
end;
$$;
revoke all on function public.secoto_devis_relances(integer) from public, anon, authenticated;
grant execute on function public.secoto_devis_relances(integer) to service_role;

-- « À traiter » : devis avec téléphone seul, à rappeler (pas d'e-mail possible).
create or replace function public.secoto_admin_a_traiter()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  perform secoto_private.assert_admin();
  return jsonb_build_object(
    'devis_a_chiffrer', (select count(*) from public.transport_quotes q
                          where q.status = 'manual_review' and q.created_at > now() - interval '30 days'),
    'commandes_sans_transporteur', (select count(*) from public.transport_orders o where o.status = 'searching_partner'),
    'reglements_en_attente', (select count(*) from public.transport_orders o join public.payments p on p.id = o.payment_id
                               where o.status = 'delivered' and p.debit_a_livraison and p.status in ('requires_capture', 'capture_failed')),
    'marges_dues', (select count(*) from public.commissions_dues c where c.statut = 'due'),
    -- 106
    'devis_a_rappeler', (select count(*) from public.transport_quotes q
                          where q.account_id is null and q.contact_phone is not null and q.contact_email is null
                            and coalesce(q.client_price_cents, 0) > 0 and q.created_at > now() - interval '7 days'
                            and q.pickup_at > now()
                            and not exists (select 1 from public.transport_orders o where o.quote_id = q.id)));
end;
$$;
revoke all on function public.secoto_admin_a_traiter() from public, anon;
grant execute on function public.secoto_admin_a_traiter() to authenticated;

notify pgrst, 'reload schema';
