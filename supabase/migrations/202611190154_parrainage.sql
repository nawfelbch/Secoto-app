-- ============================================================================
-- SECOTO 154 — Parrainage (décision de Nawfal du 19/11/2026)
-- ----------------------------------------------------------------------------
--   · client → client      : filleul −20 € sur son 1er transport, parrain 20 € de crédit ;
--   · pro    → pro         : filleul −30 €, parrain 30 € de crédit par filleul ;
--   · transporteur → transporteur : parrain 50 € quand le filleul a livré 3 missions
--     (prime « à verser », payée par SECOTO avec ses paiements habituels).
-- Règles :
--   · récompense du parrain SEULEMENT après une 1re commande du filleul livrée ET payée ;
--   · le crédit ne sert que sur un transport, jamais remboursé en argent ;
--   · pas de cumul avec la remise Black Friday / Noël (153) : le meilleur des deux ;
--   · la commission SECOTO ne descend jamais sous 75 € (même règle que la 153) ;
--   · anti-fraude : pas soi-même, pas le même téléphone ni le même SIREN, un seul
--     parrain par filleul, filleul sans commande / mission livrée, 10 filleuls par an.
-- Réglages app_settings['parrainage'] ; « actif » à false coupe tout.
-- Prérequis : 153 collée (le branchement remplace la ligne de la 153).
-- Migration ADDITIVE et rejouable.
-- ============================================================================

insert into public.app_settings(key, value)
values ('parrainage', jsonb_build_object(
  'actif', true,
  'client_filleul_cents', 2000, 'client_parrain_cents', 2000,
  'pro_filleul_cents', 3000, 'pro_parrain_cents', 3000,
  'transporteur_parrain_cents', 5000, 'transporteur_missions', 3,
  'max_filleuls_an', 10, 'commission_min_cents', 7500))
on conflict (key) do nothing;

-- 1. TABLES --------------------------------------------------------------------
create table if not exists public.parrainage_codes (
  account_id uuid primary key references public.accounts(id),
  code       text not null unique check (code ~ '^[A-Z0-9-]{4,24}$'),
  created_at timestamptz not null default now()
);

create table if not exists public.parrainages (
  id                 uuid primary key default gen_random_uuid(),
  parrain_id         uuid not null references public.accounts(id),
  filleul_id         uuid not null unique references public.accounts(id),
  type               text not null check (type in ('client', 'pro', 'transporteur')),
  statut             text not null default 'en_attente'
                     check (statut in ('en_attente', 'valide', 'prime_a_verser', 'prime_versee', 'refuse')),
  filleul_cents      integer not null default 0,
  parrain_cents      integer not null default 0,
  commande_quote_id  uuid references public.transport_quotes(id),
  valide_at          timestamptz,
  prime_versee_at    timestamptz,
  created_at         timestamptz not null default now(),
  check (parrain_id <> filleul_id)
);
create index if not exists parrainages_parrain_idx on public.parrainages(parrain_id);

-- Crédit parrain : écritures (+ gain, − utilisation, + recrédit si annulation).
create table if not exists public.parrainage_credits (
  id            uuid primary key default gen_random_uuid(),
  account_id    uuid not null references public.accounts(id),
  montant_cents integer not null,
  motif         text not null check (motif in ('gain', 'utilisation', 'recredit')),
  parrainage_id uuid references public.parrainages(id),
  quote_id      uuid references public.transport_quotes(id),
  created_at    timestamptz not null default now()
);
create unique index if not exists parrainage_credits_gain_uniq on public.parrainage_credits(parrainage_id) where motif = 'gain';
create unique index if not exists parrainage_credits_util_uniq on public.parrainage_credits(quote_id) where motif = 'utilisation';
create unique index if not exists parrainage_credits_recredit_uniq on public.parrainage_credits(quote_id) where motif = 'recredit';
create index if not exists parrainage_credits_account_idx on public.parrainage_credits(account_id);

alter table public.parrainage_codes enable row level security;
alter table public.parrainages enable row level security;
alter table public.parrainage_credits enable row level security;
revoke all on table public.parrainage_codes, public.parrainages, public.parrainage_credits from public, anon, authenticated;

-- 2. OUTILS --------------------------------------------------------------------
create or replace function secoto_private.parrainage_reglages()
returns jsonb language sql stable security definer set search_path = '' as $$
  select value from public.app_settings where key = 'parrainage' and coalesce((value ->> 'actif')::boolean, false);
$$;

create or replace function secoto_private.parrainage_solde(p_account uuid)
returns integer language sql stable security definer set search_path = '' as $$
  select coalesce(sum(montant_cents), 0)::int from public.parrainage_credits where account_id = p_account;
$$;

-- Code lisible et unique : prénom ou société (lettres A-Z) + 3 caractères.
create or replace function secoto_private.parrainage_code_de(p_account uuid)
returns text language plpgsql volatile security definer set search_path = '' as $$
declare
  v_code text;
  v_base text;
  a public.accounts%rowtype;
begin
  select code into v_code from public.parrainage_codes where account_id = p_account;
  if v_code is not null then return v_code; end if;
  select * into a from public.accounts where id = p_account;
  if not found then return null; end if;
  v_base := upper(regexp_replace(translate(coalesce(
              nullif(case when a.role::text = 'transporter' or a.client_type::text = 'pro' then a.company_name end, ''),
              nullif(split_part(btrim(coalesce(a.full_name, '')), ' ', 1), ''), 'SECOTO'),
            'àâäéèêëîïôöùûüçÀÂÄÉÈÊËÎÏÔÖÙÛÜÇ', 'aaaeeeeiioouuucAAAEEEEIIOOUUUC'), '[^A-Za-z]', '', 'g'));
  v_base := left(coalesce(nullif(v_base, ''), 'SECOTO'), 12);
  for i in 1..20 loop
    v_code := v_base || '-' || upper(substr(translate(md5(gen_random_uuid()::text), '01', ''), 1, 3));
    begin
      insert into public.parrainage_codes(account_id, code) values (p_account, v_code);
      return v_code;
    exception when unique_violation then
      -- autre code identique, ou compte déjà doté entre-temps
      select code into v_code from public.parrainage_codes where account_id = p_account;
      if v_code is not null then return v_code; end if;
    end;
  end loop;
  raise exception 'Code de parrainage impossible à créer, réessayez.';
end;
$$;

-- Avantage parrainage d'un devis : remise de bienvenue du filleul (1re commande),
-- sinon crédit du parrain. Renvoie {cents, source, libelle} ou null.
create or replace function secoto_private.parrainage_avantage(q public.transport_quotes)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  s jsonb := secoto_private.parrainage_reglages();
  p public.parrainages%rowtype;
  v_solde integer;
begin
  if s is null or q.account_id is null then return null; end if;
  select * into p from public.parrainages
   where filleul_id = q.account_id and statut = 'en_attente' and type in ('client', 'pro')
     and (commande_quote_id is null or commande_quote_id = q.id);
  if found and p.filleul_cents > 0 then
    return jsonb_build_object('cents', p.filleul_cents, 'source', 'parrainage_filleul', 'libelle', 'Offre de bienvenue (parrainage)');
  end if;
  v_solde := secoto_private.parrainage_solde(q.account_id);
  if v_solde > 0 then
    return jsonb_build_object('cents', v_solde, 'source', 'credit_parrainage', 'libelle', 'Crédit parrainage');
  end if;
  return null;
end;
$$;

-- Toutes les remises d'un devis : remise des fêtes (153) OU parrainage, la meilleure.
create or replace function secoto_private.appliquer_avantages(p_offres jsonb, q public.transport_quotes)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_promo jsonb := secoto_private.appliquer_promo_noel(p_offres);
  v_av jsonb := secoto_private.parrainage_avantage(q);
  v_min integer := coalesce((secoto_private.parrainage_reglages() ->> 'commission_min_cents')::int, 7500);
  o jsonb;
  op jsonb;
  v_client integer;
  v_pay integer;
  v_remise integer;
  v_out jsonb := '[]'::jsonb;
begin
  if v_av is null or p_offres is null or jsonb_typeof(p_offres) <> 'array' then return v_promo; end if;
  for o in select e from jsonb_array_elements(p_offres) e loop
    select e into op from jsonb_array_elements(v_promo) e where e ->> 'cle' = o ->> 'cle' limit 1;
    v_client := (o ->> 'client_cents')::int;
    v_pay := (o ->> 'partenaire_cents')::int;
    v_remise := 0;
    if v_client is not null and v_pay is not null and not (o ? 'remise_cents') then
      v_remise := greatest(least((v_av ->> 'cents')::int, v_client - v_pay - v_min), 0);
      v_remise := (v_remise / 100) * 100;
    end if;
    if v_remise >= 100 and v_remise > coalesce((op ->> 'remise_cents')::int, 0) then
      v_out := v_out || jsonb_build_array(o || jsonb_build_object(
        'client_avant_remise_cents', v_client, 'remise_cents', v_remise,
        'remise_libelle', v_av ->> 'libelle', 'remise_source', v_av ->> 'source',
        'client_cents', v_client - v_remise, 'commission_cents', v_client - v_remise - v_pay));
    else
      v_out := v_out || jsonb_build_array(coalesce(op, o));
    end if;
  end loop;
  return v_out;
end;
$$;

revoke all on function secoto_private.parrainage_reglages() from public, anon, authenticated;
revoke all on function secoto_private.parrainage_solde(uuid) from public, anon, authenticated;
revoke all on function secoto_private.parrainage_code_de(uuid) from public, anon, authenticated;
revoke all on function secoto_private.parrainage_avantage(public.transport_quotes) from public, anon, authenticated;
revoke all on function secoto_private.appliquer_avantages(jsonb, public.transport_quotes) from public, anon, authenticated;

-- 3. BRANCHEMENTS --------------------------------------------------------------
-- Calcul des offres : la 153 appliquait la remise des fêtes, la 154 choisit la meilleure.
select secoto_private.mig074_patch(
  'secoto_private.trg_quote_offres()'::regprocedure,
  $a$      new.offres := secoto_private.appliquer_promo_noel(secoto_private.calculer_offres(new));  -- 153$a$,
  $b$      new.offres := secoto_private.appliquer_avantages(secoto_private.calculer_offres(new), new);  -- 153 + 154$b$);

-- Réservation : la remise de bienvenue est « prise », le crédit est débité.
create or replace function secoto_private.parrainage_reserver(q public.transport_quotes, p_offre jsonb)
returns void language plpgsql volatile security definer set search_path = '' as $$
begin
  if p_offre ->> 'remise_source' = 'parrainage_filleul' then
    update public.parrainages set commande_quote_id = q.id
     where filleul_id = q.account_id and statut = 'en_attente' and (commande_quote_id is null or commande_quote_id = q.id);
    if not found then
      raise exception 'Votre offre de bienvenue a déjà été utilisée sur une autre réservation : recalculez le prix.';
    end if;
  elsif p_offre ->> 'remise_source' = 'credit_parrainage' and (p_offre ->> 'remise_cents')::int > 0 then
    if not exists (select 1 from public.parrainage_credits where quote_id = q.id and motif = 'utilisation')
       and secoto_private.parrainage_solde(q.account_id) < (p_offre ->> 'remise_cents')::int then
      raise exception 'Votre crédit parrainage a déjà été utilisé sur une autre réservation : recalculez le prix.';
    end if;
    insert into public.parrainage_credits(account_id, montant_cents, motif, quote_id)
    values (q.account_id, -(p_offre ->> 'remise_cents')::int, 'utilisation', q.id)
    on conflict do nothing;
  end if;
end;
$$;
revoke all on function secoto_private.parrainage_reserver(public.transport_quotes, jsonb) from public, anon, authenticated;

select secoto_private.mig074_patch(
  'public.secoto_od_book_offre(uuid, text, uuid)'::regprocedure,
  $a$  elsif v_quote.offre_choisie <> p_offre then$a$,
  $b$    perform secoto_private.parrainage_reserver(v_quote, v_offre);  -- 154
  elsif v_quote.offre_choisie <> p_offre then$b$);

-- Commande annulée : la remise de bienvenue redevient disponible, le crédit est rendu.
create or replace function secoto_private.trg_parrainage_annulation()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  v_util integer;
begin
  if new.status::text = 'cancelled' and old.status::text is distinct from 'cancelled' and new.quote_id is not null then
    update public.parrainages set commande_quote_id = null
     where commande_quote_id = new.quote_id and statut = 'en_attente';
    select -montant_cents into v_util from public.parrainage_credits
     where quote_id = new.quote_id and motif = 'utilisation';
    if v_util > 0 then
      insert into public.parrainage_credits(account_id, montant_cents, motif, quote_id)
      select account_id, v_util, 'recredit', quote_id from public.parrainage_credits
       where quote_id = new.quote_id and motif = 'utilisation'
      on conflict do nothing;
    end if;
  end if;
  return new;
end;
$$;
create or replace trigger trg_parrainage_annulation after update of status on public.transport_orders
  for each row execute function secoto_private.trg_parrainage_annulation();

-- 4. VALIDATION (appelée par l'automatisation, chaque minute) ---------------------
create or replace function secoto_private.parrainage_valider()
returns integer language plpgsql volatile security definer set search_path = '' as $$
declare
  s jsonb := secoto_private.parrainage_reglages();
  p record;
  n integer := 0;
begin
  if s is null then return 0; end if;
  -- Clients et pros : 1re commande du filleul livrée ET payée.
  for p in
    select pa.* from public.parrainages pa
     where pa.statut = 'en_attente' and pa.type in ('client', 'pro')
       and exists (select 1 from public.transport_orders o
                     join public.payments py on py.id = o.payment_id
                    where o.account_id = pa.filleul_id and o.status::text = 'delivered'
                      and py.status = 'paid' and o.created_at >= pa.created_at)
     limit 50
  loop
    update public.parrainages set statut = 'valide', valide_at = now() where id = p.id and statut = 'en_attente';
    insert into public.parrainage_credits(account_id, montant_cents, motif, parrainage_id)
    values (p.parrain_id, p.parrain_cents, 'gain', p.id) on conflict do nothing;
    perform secoto_private.notify_event(p.parrain_id, 'payment', 'Parrainage validé',
      format('Votre filleul a réalisé son premier transport : %s € de crédit vous attendent sur votre prochain transport.', p.parrain_cents / 100),
      null, null, 'parrainage-gain:' || p.id::text, null);
    n := n + 1;
  end loop;
  -- Transporteurs : N missions livrées par le filleul depuis le parrainage.
  for p in
    select pa.* from public.parrainages pa
     where pa.statut = 'en_attente' and pa.type = 'transporteur'
       and (select count(*) from public.missions m
             where m.assigned_transporter_id = pa.filleul_id and m.status::text = 'completed'
               and m.created_at >= pa.created_at) >= coalesce((s ->> 'transporteur_missions')::int, 3)
     limit 50
  loop
    update public.parrainages set statut = 'prime_a_verser', valide_at = now() where id = p.id and statut = 'en_attente';
    perform secoto_private.notify_event(p.parrain_id, 'payment', 'Parrainage validé',
      format('Le transporteur que vous avez parrainé a livré ses premières missions : une prime de %s € vous sera versée avec vos prochains paiements.', p.parrain_cents / 100),
      null, null, 'parrainage-prime:' || p.id::text, null);
    perform secoto_private.notify_admins_event('new_request', 'Prime de parrainage à verser',
      format('%s € à verser au parrain (parrainage transporteur validé). Onglet Parrainage.', p.parrain_cents / 100),
      'requests', 'parrainage-admin:' || p.id::text, null);
    n := n + 1;
  end loop;
  return n;
end;
$$;
revoke all on function secoto_private.parrainage_valider() from public, anon, authenticated;

select secoto_private.mig074_patch(
  'public.secoto_automatisation_tick()'::regprocedure,
  $a$  return jsonb_build_object('rappels', v_rappels,$a$,
  $b$  perform secoto_private.parrainage_valider();  -- 154
  return jsonb_build_object('rappels', v_rappels,$b$);

-- 5. API DE L'APP ---------------------------------------------------------------
-- Mon parrainage : code, lien, crédit, filleuls.
create or replace function public.secoto_parrainage_moi()
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare
  v_user uuid := auth.uid();
  s jsonb := secoto_private.parrainage_reglages();
  a public.accounts%rowtype;
  v_code text;
  v_type text;
begin
  if v_user is null then raise exception 'Connexion requise.'; end if;
  if s is null then return jsonb_build_object('actif', false); end if;
  select * into a from public.accounts where id = v_user;
  v_code := secoto_private.parrainage_code_de(v_user);
  v_type := case when a.role::text = 'transporter' then 'transporteur' when a.client_type::text = 'pro' then 'pro' else 'client' end;
  return jsonb_build_object(
    'actif', true, 'code', v_code, 'type', v_type,
    'lien', 'https://app.secoto-transport.fr/?parrain=' || v_code,
    'filleul_eur', case v_type when 'pro' then (s ->> 'pro_filleul_cents')::int / 100
                               when 'client' then (s ->> 'client_filleul_cents')::int / 100 else 0 end,
    'parrain_eur', case v_type when 'pro' then (s ->> 'pro_parrain_cents')::int / 100
                               when 'client' then (s ->> 'client_parrain_cents')::int / 100
                               else (s ->> 'transporteur_parrain_cents')::int / 100 end,
    'missions_requises', (s ->> 'transporteur_missions')::int,
    'credit_cents', secoto_private.parrainage_solde(v_user),
    'parrain', (select jsonb_build_object('statut', p.statut, 'filleul_eur', p.filleul_cents / 100,
                                          'utilise', p.commande_quote_id is not null)
                  from public.parrainages p where p.filleul_id = v_user),
    'filleuls', coalesce((select jsonb_agg(jsonb_build_object(
                   'prenom', coalesce(nullif(split_part(btrim(coalesce(f.full_name, '')), ' ', 1), ''), 'Filleul'),
                   'statut', p.statut, 'depuis', p.created_at::date) order by p.created_at desc)
                 from public.parrainages p join public.accounts f on f.id = p.filleul_id
                where p.parrain_id = v_user), '[]'::jsonb));
end;
$$;
revoke all on function public.secoto_parrainage_moi() from public, anon;
grant execute on function public.secoto_parrainage_moi() to authenticated;

-- Saisie du code par le filleul.
create or replace function public.secoto_parrainage_utiliser(p_code text)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare
  v_user uuid := auth.uid();
  s jsonb := secoto_private.parrainage_reglages();
  f public.accounts%rowtype;
  pa public.accounts%rowtype;
  v_parrain uuid;
  v_type text;
  v_tf text;
  v_tp text;
begin
  if v_user is null then raise exception 'Connexion requise.'; end if;
  if s is null then return jsonb_build_object('ok', false, 'raison', 'Le parrainage n''est pas ouvert pour le moment.'); end if;
  select account_id into v_parrain from public.parrainage_codes where code = upper(btrim(coalesce(p_code, '')));
  if v_parrain is null then return jsonb_build_object('ok', false, 'raison', 'Code de parrainage inconnu.'); end if;
  if v_parrain = v_user then return jsonb_build_object('ok', false, 'raison', 'Vous ne pouvez pas utiliser votre propre code.'); end if;
  if exists (select 1 from public.parrainages where filleul_id = v_user) then
    return jsonb_build_object('ok', false, 'raison', 'Un code de parrainage est déjà enregistré sur votre compte.');
  end if;
  select * into f from public.accounts where id = v_user;
  select * into pa from public.accounts where id = v_parrain and deleted_at is null;
  if not found then return jsonb_build_object('ok', false, 'raison', 'Code de parrainage inconnu.'); end if;
  v_tf := case when f.role::text = 'transporter' then 'transporteur' when f.client_type::text = 'pro' then 'pro' else 'client' end;
  v_tp := case when pa.role::text = 'transporter' then 'transporteur' when pa.client_type::text = 'pro' then 'pro' else 'client' end;
  if (v_tf = 'transporteur') <> (v_tp = 'transporteur') then
    return jsonb_build_object('ok', false, 'raison', case when v_tf = 'transporteur'
      then 'Ce code est un code client : utilisez le code d''un transporteur SECOTO.'
      else 'Ce code est un code transporteur : utilisez le code d''un client SECOTO.' end);
  end if;
  -- Anti-fraude : même téléphone ou même SIREN que le parrain.
  if (secoto_private.tel_international(f.phone) is not null and secoto_private.tel_international(f.phone) = secoto_private.tel_international(pa.phone))
     or (nullif(f.billing_siren, '') is not null and f.billing_siren = pa.billing_siren) then
    return jsonb_build_object('ok', false, 'raison', 'Ce code ne peut pas être utilisé sur ce compte.');
  end if;
  -- Filleul vraiment nouveau.
  if exists (select 1 from public.transport_orders o where o.account_id = v_user and o.status::text in ('delivered', 'partner_confirmed'))
     or exists (select 1 from public.missions m where m.assigned_transporter_id = v_user and m.status::text = 'completed') then
    return jsonb_build_object('ok', false, 'raison', 'Le parrainage est réservé aux nouveaux comptes.');
  end if;
  if (select count(*) from public.parrainages where parrain_id = v_parrain and created_at > now() - interval '1 year')
     >= coalesce((s ->> 'max_filleuls_an')::int, 10) then
    return jsonb_build_object('ok', false, 'raison', 'Ce code a atteint son nombre maximal de filleuls.');
  end if;
  v_type := case when v_tf = 'transporteur' then 'transporteur' when v_tf = 'pro' then 'pro' else 'client' end;
  insert into public.parrainages(parrain_id, filleul_id, type, filleul_cents, parrain_cents)
  values (v_parrain, v_user, v_type,
          case v_type when 'pro' then (s ->> 'pro_filleul_cents')::int when 'client' then (s ->> 'client_filleul_cents')::int else 0 end,
          case v_type when 'pro' then (s ->> 'pro_parrain_cents')::int when 'client' then (s ->> 'client_parrain_cents')::int
                      else (s ->> 'transporteur_parrain_cents')::int end);
  return jsonb_build_object('ok', true, 'type', v_type,
    'message', case v_type
      when 'transporteur' then 'Code enregistré : votre parrain sera récompensé quand vous aurez livré vos premières missions.'
      else format('Code enregistré : %s € de remise sur votre premier transport, déjà incluse dans les prix affichés.',
                  case v_type when 'pro' then (s ->> 'pro_filleul_cents')::int / 100 else (s ->> 'client_filleul_cents')::int / 100 end) end);
end;
$$;
revoke all on function public.secoto_parrainage_utiliser(text) from public, anon;
grant execute on function public.secoto_parrainage_utiliser(text) to authenticated;

-- Administration : liste et prime versée.
create or replace function public.secoto_admin_parrainages()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  perform secoto_private.assert_admin();
  return coalesce((select jsonb_agg(jsonb_build_object(
      'id', p.id, 'type', p.type, 'statut', p.statut, 'created_at', p.created_at, 'valide_at', p.valide_at,
      'parrain', coalesce(nullif(pa.company_name, ''), pa.full_name), 'parrain_tel', pa.phone,
      'filleul', coalesce(nullif(fi.company_name, ''), fi.full_name),
      'parrain_eur', p.parrain_cents / 100, 'filleul_eur', p.filleul_cents / 100) order by
      (p.statut = 'prime_a_verser') desc, p.created_at desc)
    from public.parrainages p
    join public.accounts pa on pa.id = p.parrain_id
    join public.accounts fi on fi.id = p.filleul_id), '[]'::jsonb);
end;
$$;
revoke all on function public.secoto_admin_parrainages() from public, anon;
grant execute on function public.secoto_admin_parrainages() to authenticated;

create or replace function public.secoto_admin_parrainage_prime_versee(p_id uuid)
returns void language plpgsql volatile security definer set search_path = '' as $$
begin
  perform secoto_private.assert_admin();
  update public.parrainages set statut = 'prime_versee', prime_versee_at = now()
   where id = p_id and statut = 'prime_a_verser';
  if not found then raise exception 'Prime introuvable ou déjà versée.'; end if;
  perform secoto_private.audit('parrainage_prime_versee', 'parrainage', p_id::text, '{}'::jsonb);
end;
$$;
revoke all on function public.secoto_admin_parrainage_prime_versee(uuid) from public, anon;
grant execute on function public.secoto_admin_parrainage_prime_versee(uuid) to authenticated;

notify pgrst, 'reload schema';
