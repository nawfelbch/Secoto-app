-- SECOTO — Mission manuelle : Nissan Navara non roulant (moteur HS), Nantes (44190) → Nîmes (30900).
-- Les transporteurs proposent leur prix et leur date dans l'app (aucun prix imposé).
-- E-mail envoyé UNIQUEMENT aux transporteurs VL et PL actifs et validés.
-- À coller une seule fois dans Supabase → SQL Editor, puis « Run ».

do $$
declare r jsonb;
begin
  -- Agir en tant qu'administrateur SECOTO (comme depuis l'app).
  perform set_config('request.jwt.claim.sub', 'fafe72ce-ae47-4a36-8fd6-e230dde4d2be', true);
  perform set_config('request.jwt.claims', '{"sub":"fafe72ce-ae47-4a36-8fd6-e230dde4d2be","role":"authenticated"}', true);

  r := public.secoto_create_mission(jsonb_build_object(
    'type', 'plateau', 'vehicle_category', 'standard',
    'from_city', 'Nantes (44190)', 'to_city', 'Nîmes (30900)',
    'pickup_address', '44190 (secteur Nantes) — adresse exacte communiquée au transporteur retenu',
    'delivery_address', '30900 Nîmes — adresse exacte communiquée au transporteur retenu',
    'mission_date', (date_trunc('day', now() at time zone 'Europe/Paris') + interval '3 days 8 hours') at time zone 'Europe/Paris',
    'vehicle', 'Nissan Navara (pick-up) — NON ROULANT, moteur HS',
    'distance_km', 790, 'carrier_cost', 0,
    'price_mode', 'fixed', 'payment_method', 'virement',
    'notes', 'Nissan Navara pick-up NON ROULANT (moteur HS) : plateau avec treuil obligatoire. Nantes (44190) → Nîmes (30900), environ 790 km. Proposez votre prix et votre date d''enlèvement dans l''application.'),
    gen_random_uuid());

  perform set_config('secoto.navara', r ->> 'id', false);
end $$;

-- E-mail aux transporteurs VL et PL actifs et validés (une seule fois par transporteur).
insert into public.email_outbox(account_id, to_email, subject, body_text, event_key)
select a.id, btrim(a.email),
  'Nouvelle mission plateau · Nissan Navara non roulant · Nantes (44) → Nîmes (30) · faites votre prix',
  concat_ws(E'\n',
    'Bonjour,', '',
    'Une nouvelle mission plateau vient d''être publiée sur SECOTO :', '',
    'Mission : ' || m.public_ref,
    'Trajet : Nantes (44190) → Nîmes (30900), environ 790 km',
    'Véhicule : Nissan Navara (pick-up), NON ROULANT (moteur HS) : treuil nécessaire', '',
    'Faites-nous votre meilleur prix et proposez votre date d''enlèvement directement dans l''application SECOTO (Missions publiées) : https://app.secoto-transport.fr',
    'Une question ? Appelez-nous au 07 83 27 82 31.', '',
    'Merci,',
    'L''Équipe SECOTO',
    '07 83 27 82 31'),
  'mission-navara-mail:' || m.id::text || ':' || a.id::text
from public.accounts a
cross join public.missions m
where m.id = current_setting('secoto.navara')::uuid
  and a.role::text = 'transporter' and a.deleted_at is null
  and a.status::text = 'active' and a.is_verified
  and a.transporter_type::text in ('vl', 'pl')
  and nullif(btrim(a.email), '') is not null and a.email not ilike '%+demo%'
on conflict (event_key) do nothing;

-- Vérification : la mission créée et le nombre d'e-mails en file.
select m.public_ref, m.status, m.from_city || ' → ' || m.to_city as trajet, m.vehicle,
       (select count(*) from public.email_outbox e where e.event_key like 'mission-navara-mail:' || m.id::text || ':%') as emails_vl_pl
from public.missions m where m.id = current_setting('secoto.navara')::uuid;
