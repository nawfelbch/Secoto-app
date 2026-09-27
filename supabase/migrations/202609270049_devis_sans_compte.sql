-- ============================================================================
-- SECOTO — MIGRATION 049 : LE PRIX AVANT LE COMPTE
-- ----------------------------------------------------------------------------
-- La publicite promet un tarif immediat. Aujourd'hui le visiteur doit creer un
-- compte avant de voir le moindre prix : il confie son nom, son e-mail et son
-- telephone a une entreprise qu'il decouvre, sans rien avoir recu. C'est la
-- friction principale du tunnel.
--
-- Nouveau parcours : trajet + vehicule -> prix affiche -> creation du compte
-- pour reserver -> paiement. Le compte garde son role (reserver, suivre,
-- retrouver ses documents) ; il arrive simplement un cran plus tard.
--
-- Choix de conception : le devis anonyme est une VRAIE ligne transport_quotes,
-- sans proprietaire, porteuse d'un jeton. Le calcul, les validations et le
-- barème restent donc ceux du parcours normal — un seul chemin de prix, pas
-- deux qui divergeraient avec le temps. A la creation du compte, la ligne
-- change simplement de proprietaire : le client ne resaisit rien.
-- ============================================================================

-- 1. Un devis peut exister sans proprietaire ----------------------------------
alter table public.transport_quotes alter column account_id drop not null;
alter table public.transport_quotes add column if not exists anon_token text;
alter table public.transport_quotes add column if not exists anon_ip_hash text;
alter table public.transport_quotes add column if not exists claimed_at timestamptz;

comment on column public.transport_quotes.anon_token is
  'Jeton du devis etabli sans compte. Efface des que le devis est rattache a un client.';
comment on column public.transport_quotes.anon_ip_hash is
  'Empreinte de l''adresse du demandeur, pour limiter les abus. Jamais nominative, jamais reversible.';

create unique index if not exists transport_quotes_anon_token_idx
  on public.transport_quotes (anon_token) where anon_token is not null;
create index if not exists transport_quotes_anon_ip_idx
  on public.transport_quotes (anon_ip_hash, created_at desc) where anon_ip_hash is not null;

-- Un devis sans proprietaire porte toujours un jeton, pose par la fonction qui
-- le cree. Ce n'est pas une contrainte CHECK : PostgreSQL la verifierait des
-- l'insertion, avant que le jeton existe (voir le correctif 050).

-- 2. Le calcul accepte un devis sans compte -----------------------------------
do $patch$
declare
  v_src text;
  v_neuf text;
  v_ancre text := 'if not exists (select 1 from public.accounts a where a.id = p_account_id';
begin
  select pg_get_functiondef(p.oid) into v_src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'secoto_quote_create';

  if v_src is null then
    raise exception 'secoto_quote_create absente : appliquez d''abord la migration 030.';
  end if;
  if position('p_account_id is not null and not exists' in v_src) > 0 then
    raise notice 'Devis sans compte deja accepte par le calcul.';
    return;
  end if;
  if position(v_ancre in v_src) = 0 then
    raise exception 'Point d''insertion introuvable dans secoto_quote_create.';
  end if;

  v_neuf := replace(v_src, v_ancre,
    'if p_account_id is not null and not exists (select 1 from public.accounts a where a.id = p_account_id');
  execute v_neuf;
  raise notice 'Le calcul accepte desormais un devis sans compte.';
end;
$patch$;

-- 3. Etablir un devis sans compte ----------------------------------------------
-- Appelee UNIQUEMENT par la fonction Netlify « quote-public » (service_role).
-- Le visiteur ne transmet aucun montant : tout est calcule ici.
create or replace function public.secoto_anon_quote_create(
  p_payload jsonb, p_route jsonb, p_ip_hash text
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, secoto_private
as $function$
declare
  v_json  jsonb;
  v_id    uuid;
  v_token text;
  v_recents integer;
  v_max integer := coalesce(secoto_private.policy_num('anon_quotes_per_hour', 20)::int, 20);
begin
  if p_ip_hash is null or length(p_ip_hash) < 16 then
    raise exception 'Demande non identifiable.' using errcode = '42501';
  end if;

  -- Garde-fou : un visiteur peut comparer plusieurs trajets, pas aspirer le barème.
  select count(*) into v_recents
    from public.transport_quotes q
   where q.anon_ip_hash = p_ip_hash
     and q.created_at > now() - interval '1 hour';
  if v_recents >= v_max then
    raise exception 'Trop de demandes depuis cet appareil. Reessayez dans une heure ou contactez SECOTO.'
      using errcode = 'P0001';
  end if;

  v_json := public.secoto_quote_create(null, p_payload, p_route);
  v_id := (v_json ->> 'id')::uuid;
  v_token := replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', '');

  update public.transport_quotes
     set anon_token = v_token, anon_ip_hash = p_ip_hash
   where id = v_id;

  -- Menage : un devis sans compte, jamais rattache, ne sert plus a rien.
  delete from public.transport_quotes
   where account_id is null and claimed_at is null and created_at < now() - interval '30 days';

  return jsonb_build_object('token', v_token, 'quote', v_json);
end;
$function$;

revoke all on function public.secoto_anon_quote_create(jsonb, jsonb, text) from public, anon, authenticated;

-- 4. Rattacher le devis au compte qui vient d'etre cree -------------------------
create or replace function public.secoto_anon_quote_claim(p_token text)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, secoto_private
as $function$
declare
  v_user uuid := secoto_private.assert_authenticated();
  v_quote public.transport_quotes%rowtype;
begin
  if not exists (
    select 1 from public.accounts a
     where a.id = v_user and a.deleted_at is null and a.role::text in ('client', 'admin')
  ) then
    raise exception 'Seul un compte client peut reprendre un devis.' using errcode = '42501';
  end if;

  select * into v_quote
    from public.transport_quotes q
   where q.anon_token = p_token
     and q.account_id is null
   for update;

  if not found then
    raise exception 'Ce devis n''est plus disponible. Recalculez votre prix, cela prend une minute.'
      using errcode = 'P0001';
  end if;
  if v_quote.pickup_at <= now() then
    raise exception 'La date de prise en charge est depassee. Recalculez votre prix.' using errcode = 'P0001';
  end if;

  update public.transport_quotes
     set account_id = v_user,
         anon_token = null,
         anon_ip_hash = null,
         claimed_at = now(),
         updated_at = now()
   where id = v_quote.id
  returning * into v_quote;

  perform secoto_private.audit('quote_claimed', 'transport_quote', v_quote.id::text,
    jsonb_build_object('account_id', v_user));

  return secoto_private.quote_client_json(v_quote);
end;
$function$;

grant execute on function public.secoto_anon_quote_claim(text) to authenticated;

-- 5. Reglage du garde-fou --------------------------------------------------------
update public.app_settings
   set value = jsonb_set(coalesce(value, '{}'::jsonb), '{anon_quotes_per_hour}', '20'::jsonb, true)
 where key = 'dispatch_policy'
   and not (coalesce(value, '{}'::jsonb) ? 'anon_quotes_per_hour');

notify pgrst, 'reload schema';
