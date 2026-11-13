-- ============================================================================
-- SECOTO — MIGRATION 141 : RELANCE AUTOMATIQUE « CARTE NON ENREGISTRÉE »
-- ----------------------------------------------------------------------------
-- Demandé par Nawfal le 13/11/2026 (entonnoir : 9 commandes bloquées à l'étape
-- de la carte en 30 jours). 10 minutes après une réservation restée « paiement
-- à valider » (carte jamais enregistrée), le client reçoit UN e-mail :
-- rien n'est prélevé, la carte sert de garantie, il règle à l'arrivée ; il lui
-- suffit de se connecter pour terminer (bandeau « Paiement à finaliser »).
--
-- Garde-fous :
--   · une seule relance par commande (clé od-relance-carte:<commande>) ;
--   · uniquement les commandes créées APRÈS cette migration (pas de relance
--     des anciennes), de moins de 48 h, enlèvement pas encore passé ;
--   · paiement « pending » seulement (jamais un paiement en cours de
--     traitement) et règlement à l'arrivée uniquement, compte client, hors
--     commandes de test ;
--   · pas de relance si le client a depuis réservé une autre commande ;
--   · interrupteur : app_settings['relance_carte'].actif (délai : delai_min).
-- Branchée dans secoto_od_maintenance_tick (chaque minute), sans jamais
-- pouvoir le faire échouer. Aucun appel Stripe, aucun prélèvement.
-- ADDITIF, rejouable.
-- ============================================================================

insert into public.app_settings(key, value)
values ('relance_carte', jsonb_build_object('actif', true, 'delai_min', 10, 'depuis', now()))
on conflict (key) do nothing;

create or replace function secoto_private.od_relance_carte()
returns integer language plpgsql security definer set search_path = '' as $$
declare
  s jsonb := coalesce((select value from public.app_settings where key = 'relance_carte'), '{}'::jsonb);
  v_delai integer := coalesce((s ->> 'delai_min')::int, 10);
  v_depuis timestamptz := coalesce((s ->> 'depuis')::timestamptz, now());
  r public.transport_orders%rowtype;
  v_quote public.transport_quotes%rowtype;
  v_email text;
  v_trajet text;
  v_reglement text;
  v_n integer := 0;
begin
  if not coalesce((s ->> 'actif')::boolean, false) then return 0; end if;
  for r in
    select o.* from public.transport_orders o
      join public.payments p on p.id = o.payment_id
      join public.accounts a on a.id = o.account_id
     where o.status = 'awaiting_payment'
       and o.funding = 'card'
       and not coalesce(o.is_test, false)
       and a.role::text = 'client'
       and p.status = 'pending'
       and coalesce(p.debit_a_livraison, false)          -- « rien n'est prélevé aujourd'hui » doit être vrai
       and o.created_at >= v_depuis
       and o.created_at <= now() - make_interval(mins => v_delai)
       and o.created_at > now() - interval '48 hours'
       and (o.pickup_at is null or o.pickup_at > now())
       and not exists (select 1 from public.email_outbox e where e.event_key = 'od-relance-carte:' || o.id::text)
       and not exists (select 1 from public.transport_orders o2
                        where o2.account_id = o.account_id and o2.id <> o.id and o2.created_at > o.created_at
                          and o2.status not in ('awaiting_payment', 'cancelled'))
     limit 20
  loop
    select * into v_quote from public.transport_quotes q where q.id = r.quote_id;
    select nullif(btrim(a.email), '') into v_email from public.accounts a where a.id = r.account_id;
    v_email := coalesce(v_email, nullif(btrim(v_quote.contact_email), ''));
    continue when v_email is null;
    v_trajet := coalesce(v_quote.pickup ->> 'city', 'Départ') || ' → ' || coalesce(v_quote.delivery ->> 'city', 'Arrivée');
    v_reglement := case r.mode_reglement
      when 'especes' then 'en espèces au transporteur'
      when 'virement' then 'par virement'
      when 'klarna' then 'en plusieurs fois avec Klarna'
      else 'par carte' end;
    insert into public.email_outbox(account_id, to_email, subject, body_text, event_key)
    values (r.account_id, v_email,
      format('Votre réservation n''est pas terminée : %s (%s)', v_trajet, r.public_ref),
      concat_ws(E'\n',
        'Bonjour,', '',
        'Votre demande de transport est presque terminée : il ne reste qu''à enregistrer votre carte bancaire.', '',
        secoto_private.email_client_recap(r, v_quote), '',
        format('Rien n''est prélevé aujourd''hui : votre carte sert seulement de garantie. Vous réglez à l''arrivée du véhicule, %s.', v_reglement), '',
        'Pour terminer, connectez-vous sur https://app.secoto-transport.fr avec cette adresse e-mail : votre réservation vous attend en haut de l''écran.', '',
        'Un souci avec l''application ou une question sur le prix ? Répondez simplement à cet e-mail ou appelez-nous au 07 83 27 82 31.', '',
        'L''Équipe SECOTO'),
      'od-relance-carte:' || r.id::text)
    on conflict (event_key) do nothing;
    v_n := v_n + 1;
  end loop;
  return v_n;
end;
$$;
revoke all on function secoto_private.od_relance_carte() from public, anon, authenticated;

-- Branchement dans la maintenance (chaque minute). Une erreur ici ne bloque jamais le reste.
select secoto_private.mig074_patch(
  'public.secoto_od_maintenance_tick()'::regprocedure,
  '  -- Versements transporteurs échus (livraison + 48 h) : rappel à l''administrateur.',
  '  -- 141 : relance « carte non enregistrée » 10 minutes après la réservation.
  begin
    perform secoto_private.od_relance_carte();
  exception when others then
    null;
  end;

  -- Versements transporteurs échus (livraison + 48 h) : rappel à l''administrateur.');

notify pgrst, 'reload schema';
