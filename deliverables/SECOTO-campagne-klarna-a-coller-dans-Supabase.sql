-- ============================================================================
-- SECOTO — Campagne e-mail « paiement en plusieurs fois » (octobre 2026)
-- ----------------------------------------------------------------------------
-- Destinataires :
--   · les clients inscrits (comptes « client » actifs) ;
--   · toutes les personnes qui ont laissé leur e-mail en demandant un prix.
-- Jamais : transporteurs, administrateurs, comptes supprimés, adresses de test,
-- adresses listées dans EXCLUSIONS (personnes ayant répondu STOP).
--
-- Deux messages :
--   A. devis encore réservable (date de prise en charge à venir) : trajet, prix
--      et LIEN DE PAIEMENT PERSONNEL (le lien existant est réutilisé, sinon il
--      est créé exactement comme le bouton « Lien de paiement » de l'admin) ;
--   B. tous les autres : annonce du paiement en plusieurs fois + lien du site.
--
-- MODE D'EMPLOI (Supabase → SQL Editor, coller TOUT le fichier) :
--   1. Laisser la dernière ligne sur 'apercu' → Run. Rien n'est modifié :
--      vous lisez chaque destinataire, son objet et son message.
--   2. Remplacer par 'test' → Run : UN message A et UN message B partent vers
--      contact.secoto@gmail.com uniquement (vérifiez la mise en page, cliquez
--      le lien SANS payer).
--   3. Remplacer par 'envoi' → Run : la campagne part (≈ 20 e-mails toutes les
--      2 minutes). Rejouable sans risque : une adresse ne reçoit jamais deux
--      fois cette campagne.
-- La fonction est temporaire (pg_temp) : elle disparaît à la fin de l'exécution.
-- ============================================================================

create or replace function pg_temp.campagne_klarna(p_mode text, p_test_email text default 'contact.secoto@gmail.com')
returns table (destinataire text, segment text, objet text, message text, statut text)
language plpgsql
as $$
declare
  -- Adresses à ne jamais écrire (réponses « STOP », adresses internes…).
  v_exclusions text[] := array[
    'contact.secoto@gmail.com'
  ];
  v_site constant text := 'https://app.secoto-transport.fr';
  v_cle constant text := 'campagne-klarna-2026-10';
  v_pied constant text :=
    E'\n\n* Sous réserve d''acceptation de votre demande par Klarna.\n'
    || E'\nVous recevez ce message car vous avez un compte SECOTO ou avez demandé un prix de transport sur SECOTO.'
    || E'\nPour ne plus recevoir nos messages, répondez simplement « STOP ».';
  r record;
  q record;
  v_lien text;
  v_token text;
  v_lignes text;
  v_objet text;
  v_corps text;
  v_nb int;
  v_depart text;
  v_arrivee text;
  v_test_a boolean := false;
  v_test_b boolean := false;
  v_inseres int;
begin
  if p_mode not in ('apercu', 'test', 'envoi') then
    raise exception 'Mode inconnu : %, utilisez apercu, test ou envoi.', p_mode;
  end if;

  for r in
    with contacts as (
      -- Clients inscrits.
      select lower(trim(a.email)) as email, a.id as account_id, initcap(lower(nullif(split_part(trim(coalesce(a.full_name, '')), ' ', 1), ''))) as prenom
        from public.accounts a
       where a.role::text = 'client' and a.deleted_at is null and a.email is not null
      union all
      -- Personnes ayant demandé un prix (avec ou sans compte).
      select lower(trim(coalesce(nullif(trim(dq.contact_email), ''), a.email))), dq.account_id, null
        from public.transport_quotes dq
        left join public.accounts a on a.id = dq.account_id
       where coalesce(nullif(trim(dq.contact_email), ''), a.email) is not null
    ),
    interdits as (
      -- Transporteurs, administrateurs et comptes supprimés : jamais écrits.
      select lower(trim(a.email)) as email from public.accounts a
       where a.email is not null and (a.role::text <> 'client' or a.deleted_at is not null)
    )
    select c.email,
           (array_agg(c.account_id) filter (where c.account_id is not null))[1] as account_id,
           (array_agg(c.prenom) filter (where c.prenom is not null))[1] as prenom
      from contacts c
     where c.email ~ '^[^@\s]+@[^@\s]+\.[a-z]{2,}$'
       and c.email not like '%@test.%' and c.email not like '%@example.%' and c.email not like 'test@%'
       and not (c.email = any (v_exclusions))
       and c.email not in (select email from interdits)
     group by c.email
     order by c.email
  loop
    -- Devis encore réservables de cette adresse (prise en charge dans plus de 12 h).
    v_lignes := '';
    v_nb := 0;
    v_depart := null;
    v_arrivee := null;
    for q in
      select qt.* from public.transport_quotes qt
        left join public.accounts a on a.id = qt.account_id
       where lower(trim(coalesce(nullif(trim(qt.contact_email), ''), a.email))) = r.email
         and qt.supprime_le is null
         and qt.status in ('priced', 'manual_priced', 'expired')
         and qt.pickup_at > now() + interval '12 hours'
         and coalesce(qt.client_price_cents, 0) > 0
         and not exists (select 1 from public.transport_orders o where o.quote_id = qt.id)
       order by qt.pickup_at
       limit 3
    loop
      -- Lien personnel : celui déjà envoyé s'il est encore valable et au même prix.
      select l.token into v_token from public.devis_payment_links l
       where l.quote_id = q.id and l.revoked_at is null and l.paid_at is null
         and l.expires_at > now() and l.amount_cents = q.client_price_cents
       limit 1;
      if v_token is null and p_mode <> 'apercu' then
        -- Même règle que l'admin (038/040, 096) : l'ancien lien est remplacé,
        -- le nouveau vit jusqu'à la prise en charge, 30 jours au plus.
        update public.devis_payment_links set revoked_at = now()
         where quote_id = q.id and revoked_at is null and paid_at is null;
        insert into public.devis_payment_links (quote_id, token, amount_cents, expires_at, created_by)
        values (q.id, encode(extensions.gen_random_bytes(18), 'hex'), q.client_price_cents,
                least(now() + interval '30 days', coalesce(greatest(q.pickup_at, q.valid_until), now() + interval '30 days')),
                null)
        returning token into v_token;
      end if;
      v_lien := case when v_token is null then '(lien créé au moment de l''envoi)' else v_site || '/payer?t=' || v_token end;
      v_nb := v_nb + 1;
      if v_nb = 1 then v_depart := q.pickup ->> 'city'; v_arrivee := q.delivery ->> 'city'; end if;
      v_lignes := v_lignes
        || E'\n• ' || coalesce(q.pickup ->> 'city', 'Départ') || ' → ' || coalesce(q.delivery ->> 'city', 'Arrivée')
        || case q.mode when 'plateau' then ' (sur plateau)' when 'convoyage' then ' (convoyage)' else '' end
        || E'\n  Prise en charge à partir du ' || to_char(q.pickup_at at time zone 'Europe/Paris', 'DD/MM/YYYY')
        || ' — ' || replace(trim(to_char(q.client_price_cents / 100.0, '999999990.00')), '.', ',') || ' € TTC'
        || E'\n  Réserver maintenant : ' || v_lien || E'\n';
      v_token := null;
    end loop;

    if v_nb > 0 then
      segment := 'A — devis réservable';
      v_objet := case when v_nb = 1
        then format('Votre transport %s → %s est toujours disponible', coalesce(v_depart, ''), coalesce(v_arrivee, ''))
        else 'Vos transports sont toujours disponibles' end;
      v_corps := 'Bonjour' || coalesce(' ' || r.prenom, '') || E',\n\n'
        || case when v_nb = 1 then E'Votre demande de transport est toujours disponible, au prix qui vous a été annoncé :\n'
                else E'Vos demandes de transport sont toujours disponibles, aux prix qui vous ont été annoncés :\n' end
        || v_lignes
        || E'\nNOUVEAU : payez en plusieurs fois avec Klarna*.\n'
        || E'Sur la page de paiement sécurisée, choisissez simplement « Klarna ». Carte bancaire et Apple Pay restent bien sûr disponibles.\n'
        || E'\nLe lien reste valable jusqu''à la date de prise en charge. Une question, un changement de date ? Répondez à cet e-mail, nous vous répondons rapidement.\n'
        || E'\nÀ très vite,\nL''équipe SECOTO\n' || v_site
        || v_pied;
    else
      segment := 'B — annonce';
      v_objet := 'Nouveau chez SECOTO : payez votre transport en plusieurs fois';
      v_corps := 'Bonjour' || coalesce(' ' || r.prenom, '') || E',\n\n'
        || E'Bonne nouvelle : vous pouvez désormais payer votre transport de véhicule en plusieurs fois avec Klarna*.\n'
        || E'\nC''est simple :\n'
        || '1. Obtenez votre prix en 1 minute sur ' || v_site || E'\n'
        || E'2. Au moment du paiement, choisissez « Klarna ».\n'
        || E'\nTransport sur plateau ou convoyage, avec des transporteurs vérifiés. Carte bancaire et Apple Pay restent bien sûr disponibles.\n'
        || E'\nUne question ? Répondez à cet e-mail, nous vous répondons rapidement.\n'
        || E'\nÀ très vite,\nL''équipe SECOTO\n' || v_site
        || v_pied;
    end if;

    destinataire := r.email;
    objet := v_objet;
    message := v_corps;

    if p_mode = 'apercu' then
      statut := case when exists (select 1 from public.email_outbox e where e.event_key = v_cle || ':' || r.email)
                     then 'déjà envoyé (sera ignoré)' else 'à envoyer' end;
      return next;
    elsif p_mode = 'test' then
      -- Un exemplaire de chaque message, vers l'adresse de test seulement.
      if (v_nb > 0 and not v_test_a) or (v_nb = 0 and not v_test_b) then
        insert into public.email_outbox (to_email, subject, body_text, event_key)
        values (p_test_email, '[TEST] ' || v_objet, v_corps,
                v_cle || ':test:' || left(segment, 1) || ':' || extract(epoch from clock_timestamp())::bigint);
        if v_nb > 0 then v_test_a := true; else v_test_b := true; end if;
        destinataire := p_test_email || ' (exemple de ' || r.email || ')';
        statut := 'test en file d''envoi';
        return next;
      end if;
      exit when v_test_a and v_test_b;
    else
      insert into public.email_outbox (account_id, to_email, subject, body_text, event_key)
      values (r.account_id, r.email, v_objet, v_corps, v_cle || ':' || r.email)
      on conflict (event_key) do nothing;
      get diagnostics v_inseres = row_count;
      statut := case when v_inseres = 1 then 'en file d''envoi' else 'déjà envoyé, ignoré' end;
      return next;
    end if;
  end loop;
end;
$$;

-- ▼▼▼ Remplacez 'apercu' par 'test', puis par 'envoi' (voir le mode d'emploi). ▼▼▼
select * from pg_temp.campagne_klarna('apercu');
