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
