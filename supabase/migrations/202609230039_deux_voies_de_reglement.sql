-- ============================================================================
-- SECOTO — MIGRATION 039 : DEUX VOIES DE REGLEMENT POUR LA MISE EN RELATION
-- ----------------------------------------------------------------------------
-- Decision de Nawfal du 23/09/2026. Sur une mission plateau, le client choisit :
--
--   · ESPECES — il regle le transporteur de la main a la main. SECOTO n'encaisse
--     rien : c'est le TRANSPORTEUR qui doit virer la commission de mise en
--     relation. L'app envoie une relance unique, deux jours apres la livraison,
--     au transporteur et a l'administrateur. Elle s'arrete des que la commission
--     est marquee encaissee.
--
--   · CARTE — il regle tout en une fois depuis le lien du devis. Stripe garde la
--     commission sur le compte SECOTO et verse sa part au transporteur sur SON
--     compte bancaire : rien ne transite par la banque de SECOTO.
--
-- Le versement du transporteur suit la mecanique de la migration 036 : il attend
-- que le transporteur ait active ses versements, sans bloquer l'encaissement.
-- ============================================================================

-- 1. Depuis quand la commission est-elle due ? ---------------------------------
alter table public.missions add column if not exists commission_due_since timestamptz;
alter table public.missions add column if not exists commission_reminder_sent_at timestamptz;

comment on column public.missions.commission_due_since is
  'Livraison d''une mission plateau reglee en especes : point de depart de la relance.';
comment on column public.missions.commission_reminder_sent_at is
  'Date de la relance envoyee au transporteur. NULL = jamais relance.';

create index if not exists missions_commission_relance_idx
  on public.missions (commission_due_since)
  where commission_due_since is not null and commission_reminder_sent_at is null;

-- 2. Marquer la dette a la livraison -------------------------------------------
create or replace function secoto_private.trg_commission_especes_due()
returns trigger language plpgsql volatile security definer set search_path = ''
as $f$
declare v_done_new boolean; v_done_old boolean;
begin
  v_done_new := coalesce(new.progress_status, '') in ('delivery_completed', 'completed') or new.status::text = 'completed';
  v_done_old := coalesce(old.progress_status, '') in ('delivery_completed', 'completed') or old.status::text = 'completed';
  if not v_done_new or v_done_old then return new; end if;
  if new.type::text <> 'plateau' then return new; end if;
  if lower(coalesce(new.payment_method, '')) not in ('especes', 'espèces', 'cash') then return new; end if;
  if coalesce(new.commission_amount, 0) <= 0 then return new; end if;
  if coalesce(new.commission_settled_offline, false) or new.commission_paid_at is not null then return new; end if;

  update public.missions
     set commission_due_since = coalesce(commission_due_since, now())
   where id = new.id;
  return new;
end;
$f$;

drop trigger if exists trg_secoto_commission_especes_due on public.missions;
create trigger trg_secoto_commission_especes_due
  after update of status, progress_status on public.missions
  for each row execute function secoto_private.trg_commission_especes_due();

-- 3. La relance, une seule fois, deux jours apres ------------------------------
-- Appelee a chaque passage de la maintenance. Elle est sans effet tant que
-- l'echeance n'est pas atteinte, et ne relance jamais deux fois la meme course.
create or replace function public.secoto_commission_relances()
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, secoto_private
as $function$
declare
  v_delai   numeric;
  v_mission record;
  v_envoyees integer := 0;
  v_total_du numeric := 0;
  v_montant text;
begin
  v_delai := coalesce(secoto_private.policy_num('commission_relance_hours', 48), 48);

  for v_mission in
    select m.id, m.public_ref, m.commission_amount, m.assigned_transporter_id,
           m.from_city, m.to_city
      from public.missions m
     where m.commission_due_since is not null
       and m.commission_reminder_sent_at is null
       and m.cancelled_at is null
       and coalesce(m.commission_settled_offline, false) = false
       and m.commission_paid_at is null
       and m.assigned_transporter_id is not null
       and m.commission_due_since + make_interval(hours => v_delai::int) <= now()
     order by m.commission_due_since
     limit 50
  loop
    v_montant := replace(to_char(v_mission.commission_amount, 'FM999990D00'), '.', ',');

    perform secoto_private.notify_event(
      v_mission.assigned_transporter_id, 'payment',
      'Commission SECOTO a regler',
      format('Mission %s (%s - %s) : il reste %s € de frais de mise en relation a virer a SECOTO. '
             || 'Le RIB figure sur votre facture.',
             coalesce(v_mission.public_ref, ''), coalesce(v_mission.from_city, ''),
             coalesce(v_mission.to_city, ''), v_montant),
      v_mission.id, 'paiement', 'commission-relance:' || v_mission.id::text, v_mission.id);

    update public.missions
       set commission_reminder_sent_at = now()
     where id = v_mission.id;

    v_envoyees := v_envoyees + 1;
    v_total_du := v_total_du + coalesce(v_mission.commission_amount, 0);
  end loop;

  -- Un seul recapitulatif pour l'administrateur, pas une notification par course.
  if v_envoyees > 0 then
    perform secoto_private.notify_admins_event(
      'payment', 'Commissions en attente',
      format('%s transporteur(s) relance(s) : %s € de commissions restent a encaisser.',
             v_envoyees, replace(to_char(v_total_du, 'FM999990D00'), '.', ',')),
      'paiement', 'commission-relance-admin:' || to_char(now(), 'YYYYMMDDHH24'), null);
  end if;

  return jsonb_build_object('relances', v_envoyees, 'montant_du', v_total_du);
end;
$function$;

revoke all on function public.secoto_commission_relances() from public, anon, authenticated;

-- 4. Carte bancaire : le transporteur est paye par Stripe ----------------------
-- Le garde-fou « plateau » de la migration 036 protegeait d'un double paiement :
-- le client payait le transporteur en direct. Quand la course a ete reglee par
-- carte via le lien du devis, ce n'est plus vrai, et le versement doit partir.
create or replace function secoto_private.trg_manual_mission_payout()
returns trigger language plpgsql volatile security definer set search_path = ''
as $f$
declare v_done_new boolean; v_done_old boolean; v_cutover timestamptz; v_regle_par_carte boolean;
begin
  v_done_new := coalesce(new.progress_status, '') in ('delivery_completed', 'completed') or new.status::text = 'completed';
  v_done_old := coalesce(old.progress_status, '') in ('delivery_completed', 'completed') or old.status::text = 'completed';
  if not v_done_new or v_done_old then return new; end if;
  if new.assigned_transporter_id is null or coalesce(new.carrier_pay, 0) <= 0 then return new; end if;
  if lower(coalesce(new.payment_method, '')) in ('especes', 'espèces', 'cash') then return new; end if;
  -- Commandes en ligne : versement créé par trg_od_sync_from_mission.
  if exists (select 1 from public.transport_orders o where o.mission_id = new.id) then return new; end if;

  -- La course a-t-elle ete reglee entierement a SECOTO par le lien du devis ?
  select exists (
    select 1 from public.payments p
     where p.mission_id = new.id and p.purpose = 'devis_course' and p.status = 'paid'
  ) into v_regle_par_carte;

  -- Plateau antérieur à la sous-traitance totale : le client payait le
  -- transport en direct au transporteur. Verser en plus serait payer deux fois.
  select (s.value ->> 'sous_traitance_totale_since')::timestamptz into v_cutover
    from public.app_settings s where s.key = 'dispatch_policy';
  if new.type::text = 'plateau'
     and not v_regle_par_carte
     and (v_cutover is null or coalesce(new.created_at, now()) < v_cutover) then
    return new;
  end if;

  insert into public.partner_payouts(mission_id, order_id, partner_id, amount_cents, due_at, mode, kind)
  values (new.id, null, new.assigned_transporter_id, round(new.carrier_pay * 100)::int,
          now() + make_interval(hours => secoto_private.policy_num('payout_delay_hours', 48)::int),
          new.type::text, 'mission')
  on conflict (mission_id) do nothing;
  if found then
    perform secoto_private.notify_event(new.assigned_transporter_id, 'payment', 'Paiement programmé',
      format('Mission %s livrée : paiement de %s € déclenché sous 48 heures.', new.public_ref,
        replace(to_char(new.carrier_pay, 'FM999990D00'), '.', ',')),
      new.id, 'paiement', 'manual-payout:' || new.id::text, new.id);
  end if;
  return new;
end;
$f$;

drop trigger if exists trg_secoto_manual_mission_payout on public.missions;
create trigger trg_secoto_manual_mission_payout
  after update of status, progress_status on public.missions
  for each row execute function secoto_private.trg_manual_mission_payout();

-- 5. Le lien du devis refuse les missions reglees en especes -------------------
-- Sinon le client paierait SECOTO alors qu'il a deja paye le transporteur.
do $patch$
declare v_src text;
begin
  select pg_get_functiondef(p.oid) into v_src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'secoto_devis_link_open';
  if v_src is null or position('reglement_especes' in v_src) > 0 then return; end if;
  v_src := replace(v_src,
    '  if coalesce(v_mission.payment_status, '''') = ''paid'' then',
    '  if lower(coalesce(v_mission.payment_method, '''')) in (''especes'', ''espèces'', ''cash'') then'
    || chr(10) || '    return jsonb_build_object(''error'', ''reglement_especes'');'
    || chr(10) || '  end if;'
    || chr(10) || '  if coalesce(v_mission.payment_status, '''') = ''paid'' then');
  execute v_src;
end;
$patch$;

-- 6. Delai de relance reglable -------------------------------------------------
update public.app_settings
   set value = jsonb_set(coalesce(value, '{}'::jsonb), '{commission_relance_hours}', '48'::jsonb, true)
 where key = 'dispatch_policy'
   and not (coalesce(value, '{}'::jsonb) ? 'commission_relance_hours');

notify pgrst, 'reload schema';
