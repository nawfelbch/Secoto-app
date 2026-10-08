-- ============================================================================
-- SECOTO 075 — Acceptation active des conditions (clients et transporteurs)
-- ----------------------------------------------------------------------------
-- Migration UNIQUEMENT ADDITIVE et rejouable :
--   • interrupteurs `conditions_v2` et `commission_client`, éteints ;
--   • réglage `terms_current` (version en vigueur + pages publiques) ;
--   • table de preuve `terms_acceptances` (compte, version, date et heure,
--     origine) — RLS : chacun lit ses lignes, l'administrateur lit tout,
--     écriture uniquement par fonction ;
--   • deux colonnes nullables sur `payments` pour les clients qui paient un
--     devis par lien, sans compte.
--
-- Interrupteur éteint : `secoto_terms_status()` répond « rien à accepter »,
-- l'inscription n'affiche pas la case, la page de paiement par lien non plus.
-- L'application se comporte exactement comme avant.
--
-- Quand la version change, chaque client et transporteur réaccepte une fois.
-- L'administrateur n'est jamais concerné.
-- ============================================================================

-- 1. INTERRUPTEURS --------------------------------------------------------------
-- La liste autorisée est élargie (aucune clé retirée).
alter table public.secoto_feature_flags drop constraint if exists secoto_feature_flags_key_check;
alter table public.secoto_feature_flags add constraint secoto_feature_flags_key_check
  check (key in ('auto_pricing', 'od_payments', 'subscriptions', 'dispatch_notifications', 'live_tracking',
                 'direct_accept', 'connect_payouts', 'plateau_paiement_direct',
                 'conditions_v2', 'commission_client'));
insert into public.secoto_feature_flags(key) values ('conditions_v2') on conflict (key) do nothing;
insert into public.secoto_feature_flags(key) values ('commission_client') on conflict (key) do nothing;

-- 2. VERSION EN VIGUEUR -----------------------------------------------------------
-- Les chemins sont relatifs : l'application les complète avec son adresse
-- (aperçu de test ou production). Changer `version` fait réaccepter tout le monde.
insert into public.app_settings(key, value) values ('terms_current', jsonb_build_object(
  'version', '2026-10-09-projet',
  'documents', jsonb_build_object(
    'cgu', '/cgu.html',
    'confidentialite', '/politique-confidentialite.html',
    'conditions_transporteur', '/conditions-transporteur.html')))
on conflict (key) do nothing;

-- 3. TABLE DE PREUVE ----------------------------------------------------------------
-- Pas de clé étrangère vers accounts : la preuve de l'accord survit à une
-- suppression de compte (obligation de preuve), sans donnée personnelle autre
-- que l'identifiant.
create table if not exists public.terms_acceptances (
  id            uuid primary key default gen_random_uuid(),
  account_id    uuid not null,
  terms_version text not null,
  documents     text[] not null,
  source        text not null check (source in ('inscription', 'reconnexion')),
  platform      text check (platform is null or platform in ('web', 'ios', 'android')),
  user_agent    text,
  accepted_at   timestamptz not null default now(),
  unique (account_id, terms_version)
);
create index if not exists terms_acceptances_account_idx on public.terms_acceptances(account_id);

alter table public.terms_acceptances enable row level security;
revoke all on public.terms_acceptances from public, anon, authenticated;
grant select on public.terms_acceptances to authenticated;

drop policy if exists terms_acceptances_own_read on public.terms_acceptances;
create policy terms_acceptances_own_read on public.terms_acceptances
  for select to authenticated
  using (account_id = auth.uid() or secoto_private.current_is_admin());

comment on table public.terms_acceptances is
  'Preuve de l''acceptation active des conditions : compte, version, date et heure, origine. Écriture uniquement par fonction.';

-- 4. PAIEMENT PAR LIEN (client sans compte) ---------------------------------------
alter table public.payments add column if not exists terms_version text;
alter table public.payments add column if not exists terms_accepted_at timestamptz;

-- 5. FONCTIONS ------------------------------------------------------------------------
create or replace function secoto_private.terms_current()
returns jsonb language sql stable security definer set search_path = ''
as $f$
  select coalesce((select s.value from public.app_settings s where s.key = 'terms_current'),
                  jsonb_build_object('version', null, 'documents', '{}'::jsonb));
$f$;

-- Documents à accepter selon le rôle : les conditions transporteur ne
-- concernent que les transporteurs (indépendants, gérants et salariés).
create or replace function secoto_private.terms_documents_for(p_role text)
returns text[] language sql immutable set search_path = ''
as $f$
  select case when p_role = 'transporter'
              then array['cgu', 'confidentialite', 'conditions_transporteur']
              else array['cgu', 'confidentialite'] end;
$f$;

-- Public (avant connexion) : l'écran d'inscription sait s'il doit afficher la case.
create or replace function public.secoto_terms_public()
returns jsonb language sql stable security definer set search_path = ''
as $f$
  select jsonb_build_object(
    'active', secoto_private.flag('conditions_v2'),
    'version', secoto_private.terms_current() ->> 'version',
    'documents', coalesce(secoto_private.terms_current() -> 'documents', '{}'::jsonb));
$f$;

-- Pour le compte connecté : faut-il afficher la fenêtre d'acceptation ?
create or replace function public.secoto_terms_status()
returns jsonb language plpgsql stable security definer set search_path = ''
as $f$
declare
  v_role text;
  v_current jsonb := secoto_private.terms_current();
  v_version text := v_current ->> 'version';
  v_accepted timestamptz;
begin
  if auth.uid() is null then raise exception 'Connexion requise.'; end if;
  select a.role into v_role from public.accounts a where a.id = auth.uid();

  if not secoto_private.flag('conditions_v2') or v_version is null
     or coalesce(v_role, 'client') not in ('client', 'transporter') then
    return jsonb_build_object('required', false, 'active', secoto_private.flag('conditions_v2'));
  end if;

  select t.accepted_at into v_accepted from public.terms_acceptances t
   where t.account_id = auth.uid() and t.terms_version = v_version;

  return jsonb_build_object(
    'required', v_accepted is null,
    'active', true,
    'version', v_version,
    'role', v_role,
    'documents', to_jsonb(secoto_private.terms_documents_for(v_role)),
    'urls', coalesce(v_current -> 'documents', '{}'::jsonb),
    'accepted_at', v_accepted);
end;
$f$;

-- Un seul clic sur « Accepter » vaut acceptation de l'ensemble. La version
-- envoyée doit être la version en vigueur : un écran resté ouvert pendant un
-- changement de version ne peut pas valider l'ancienne.
create or replace function public.secoto_accept_terms(p_version text, p_platform text default null, p_user_agent text default null)
returns jsonb language plpgsql volatile security definer set search_path = ''
as $f$
declare
  v_role text;
  v_version text := secoto_private.terms_current() ->> 'version';
begin
  if auth.uid() is null then raise exception 'Connexion requise.'; end if;
  if not secoto_private.flag('conditions_v2') then
    return jsonb_build_object('ok', false, 'reason', 'inactif');
  end if;
  select a.role into v_role from public.accounts a where a.id = auth.uid();
  if v_role is null or v_role not in ('client', 'transporter') then
    return jsonb_build_object('ok', false, 'reason', 'non_concerne');
  end if;
  if p_version is distinct from v_version then
    raise exception 'Les conditions ont été mises à jour. Rechargez la page pour lire la nouvelle version.';
  end if;

  insert into public.terms_acceptances(account_id, terms_version, documents, source, platform, user_agent)
  values (auth.uid(), v_version, secoto_private.terms_documents_for(v_role), 'reconnexion',
          case when p_platform in ('web', 'ios', 'android') then p_platform end,
          left(p_user_agent, 300))
  on conflict (account_id, terms_version) do nothing;

  perform secoto_private.audit('terms_accepted', 'account', auth.uid()::text,
    jsonb_build_object('version', v_version, 'source', 'reconnexion'));
  return public.secoto_terms_status();
end;
$f$;

-- Inscription : la case cochée dans le formulaire voyage dans les métadonnées
-- du compte (terms_version). L'accord n'est enregistré que si l'interrupteur est
-- allumé et que la version cochée est celle en vigueur ; sinon la fenêtre
-- d'acceptation s'affichera à la première connexion.
create or replace function secoto_private.trg_terms_on_signup()
returns trigger language plpgsql volatile security definer set search_path = ''
as $f$
declare
  v_meta jsonb;
  v_version text := secoto_private.terms_current() ->> 'version';
begin
  if not secoto_private.flag('conditions_v2') or new.role not in ('client', 'transporter') then
    return new;
  end if;
  select u.raw_user_meta_data into v_meta from auth.users u where u.id = new.id;
  if v_meta ->> 'terms_version' is not null and v_meta ->> 'terms_version' = v_version then
    insert into public.terms_acceptances(account_id, terms_version, documents, source, platform)
    values (new.id, v_version, secoto_private.terms_documents_for(new.role), 'inscription',
            case when v_meta ->> 'terms_platform' in ('web', 'ios', 'android') then v_meta ->> 'terms_platform' end)
    on conflict (account_id, terms_version) do nothing;
  end if;
  return new;
exception when others then
  -- L'inscription ne doit jamais échouer à cause de la preuve : la fenêtre
  -- d'acceptation prendra le relais à la première connexion.
  return new;
end;
$f$;

drop trigger if exists trg_secoto_terms_on_signup on public.accounts;
create trigger trg_secoto_terms_on_signup
after insert on public.accounts
for each row execute function secoto_private.trg_terms_on_signup();

-- Paiement d'un devis par lien (client sans compte) : la case est sur la page
-- de paiement. Appelée par le serveur uniquement (clé de service).
create or replace function public.secoto_devis_link_accept_terms(p_token text, p_version text)
returns jsonb language plpgsql volatile security definer set search_path = ''
as $f$
declare
  v_link public.devis_payment_links%rowtype;
  v_version text := secoto_private.terms_current() ->> 'version';
begin
  if p_version is distinct from v_version then
    return jsonb_build_object('error', 'version_perimee');
  end if;
  select * into v_link from public.devis_payment_links l where l.token = p_token;
  if not found or v_link.payment_id is null then return jsonb_build_object('error', 'lien_inconnu'); end if;
  update public.payments
     set terms_version = v_version, terms_accepted_at = now(), updated_at = now()
   where id = v_link.payment_id and status in ('pending', 'processing');
  if not found then return jsonb_build_object('error', 'lien_inconnu'); end if;
  return jsonb_build_object('ok', true, 'version', v_version);
end;
$f$;

-- État des conditions pour un lien de paiement (page avant Stripe).
create or replace function public.secoto_devis_link_terms(p_token text)
returns jsonb language plpgsql stable security definer set search_path = ''
as $f$
declare
  v_link public.devis_payment_links%rowtype;
  v_accepted text;
  v_current jsonb := secoto_private.terms_current();
begin
  if not secoto_private.flag('conditions_v2') or v_current ->> 'version' is null then
    return jsonb_build_object('active', false);
  end if;
  select * into v_link from public.devis_payment_links l where l.token = p_token;
  if found and v_link.payment_id is not null then
    select p.terms_version into v_accepted from public.payments p where p.id = v_link.payment_id;
  end if;
  return jsonb_build_object(
    'active', true,
    'version', v_current ->> 'version',
    'documents', to_jsonb(array['cgu', 'confidentialite']),
    'urls', coalesce(v_current -> 'documents', '{}'::jsonb),
    'accepted', v_accepted is not null and v_accepted = v_current ->> 'version');
end;
$f$;

-- Droits : le public ne lit que la version ; seul un compte connecté accepte ;
-- la fonction du lien de paiement reste réservée au serveur.
revoke all on function public.secoto_terms_public() from public;
revoke all on function public.secoto_terms_status() from public, anon;
revoke all on function public.secoto_accept_terms(text, text, text) from public, anon;
revoke all on function public.secoto_devis_link_accept_terms(text, text) from public, anon, authenticated;
revoke all on function public.secoto_devis_link_terms(text) from public, anon, authenticated;
revoke all on function secoto_private.terms_current() from public, anon, authenticated;
revoke all on function secoto_private.trg_terms_on_signup() from public, anon, authenticated;
grant execute on function public.secoto_terms_public() to anon, authenticated;
grant execute on function public.secoto_terms_status() to authenticated;
grant execute on function public.secoto_accept_terms(text, text, text) to authenticated;
grant execute on function public.secoto_devis_link_accept_terms(text, text) to service_role;
grant execute on function public.secoto_devis_link_terms(text) to service_role;

-- 6. CONTRÔLES BLOQUANTS ----------------------------------------------------------------
do $controles$
begin
  if not exists (select 1 from public.secoto_feature_flags where key = 'conditions_v2') then
    raise exception 'Interrupteur conditions_v2 absent';
  end if;
  if exists (select 1 from public.secoto_feature_flags where key in ('conditions_v2', 'commission_client') and enabled) then
    raise notice 'Attention : un interrupteur 075 est déjà allumé (aucune modification faite).';
  end if;
  if not exists (select 1 from pg_trigger where tgname = 'trg_secoto_terms_on_signup') then
    raise exception 'Déclencheur d''inscription absent';
  end if;
  if not (select relrowsecurity from pg_class where oid = 'public.terms_acceptances'::regclass) then
    raise exception 'RLS non activée sur terms_acceptances';
  end if;
end;
$controles$;

notify pgrst, 'reload schema';
