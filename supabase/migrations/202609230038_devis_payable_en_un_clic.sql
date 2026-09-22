-- ============================================================================
-- SECOTO — MIGRATION 038 : DEVIS PAYABLE EN UN CLIC
-- ----------------------------------------------------------------------------
-- Jusqu'ici, un client sans compte SECOTO ne pouvait pas payer : le devis
-- partait par e-mail avec une signature, et l'encaissement supposait l'appli.
--
-- Decision de Nawfal du 23/09/2026 :
--   · le devis porte un bouton « Payer la course » au montant du Prix client ;
--   · le paiement VAUT acceptation du devis (plus d'etape de signature) ;
--   · le meme lien peut partir par SMS depuis la fiche mission de l'admin.
--
-- Le lien est une adresse-capacite : celui qui la detient peut payer, et rien
-- d'autre. Il ne porte aucun identifiant de mission, expire, et refuse de
-- servir deux fois. Le montant n'est JAMAIS lu dans l'URL : il est relu en
-- base au moment du clic.
-- ============================================================================

-- 1. Un nouveau motif de paiement -------------------------------------------
alter table public.payments drop constraint if exists payments_purpose_check;
alter table public.payments add constraint payments_purpose_check
  check (purpose in ('commission_plateau', 'convoyage_livraison', 'od_convoyage',
                     'od_plateau_commission', 'od_plateau', 'subscription_extension',
                     'devis_course'));

comment on constraint payments_purpose_check on public.payments is
  'devis_course : la course entiere reglee par le client depuis le lien du devis.';

-- 2. Les liens de paiement ----------------------------------------------------
create table if not exists public.devis_payment_links (
  id           uuid primary key default gen_random_uuid(),
  mission_id   uuid not null references public.missions(id) on delete cascade,
  token        text not null unique,
  amount_cents integer not null check (amount_cents > 0),
  currency     text not null default 'eur',
  expires_at   timestamptz not null,
  revoked_at   timestamptz,
  paid_at      timestamptz,
  payment_id   uuid references public.payments(id),
  created_by   uuid references public.accounts(id),
  created_at   timestamptz not null default now()
);

create index if not exists devis_payment_links_mission_idx
  on public.devis_payment_links (mission_id, created_at desc);

-- Un seul lien vivant par mission : on ne veut pas deux adresses valides qui
-- encaisseraient deux fois la meme course.
create unique index if not exists devis_payment_links_actif_idx
  on public.devis_payment_links (mission_id)
  where revoked_at is null and paid_at is null;

alter table public.devis_payment_links enable row level security;
revoke all on table public.devis_payment_links from anon, authenticated;
comment on table public.devis_payment_links is
  'Liens de paiement des devis. Aucune politique RLS : seules les fonctions '
  'SECURITY DEFINER et le service_role y accedent.';

-- 3. Fabrication du lien -------------------------------------------------------
create or replace function secoto_private.devis_link(
  p_mission uuid,
  p_amount_cents integer default null,
  p_validity_days integer default 30,
  p_created_by uuid default null
)
returns public.devis_payment_links
language plpgsql
volatile
security definer
set search_path = public, secoto_private
as $function$
declare
  v_mission public.missions%rowtype;
  v_amount  integer;
  v_link    public.devis_payment_links%rowtype;
begin
  select * into v_mission from public.missions m where m.id = p_mission;
  if not found then raise exception 'Mission introuvable.'; end if;
  if v_mission.cancelled_at is not null then
    raise exception 'Mission annulee : aucun lien de paiement.';
  end if;

  -- Le montant par defaut est ce que le client doit reellement : le total
  -- calcule si la base le tient, sinon le Prix client saisi par l'admin.
  v_amount := coalesce(
    p_amount_cents,
    round(coalesce(nullif(v_mission.client_total_due, 0), v_mission.client_price, 0) * 100)::integer
  );
  if v_amount is null or v_amount <= 0 then
    raise exception 'Renseignez le Prix client avant de creer le lien de paiement.';
  end if;

  -- Un lien vivant au bon montant est reutilise : le client qui a recu le
  -- devis puis le SMS doit tomber sur la meme page.
  select * into v_link
    from public.devis_payment_links l
   where l.mission_id = p_mission
     and l.revoked_at is null
     and l.paid_at is null
     and l.expires_at > now()
     and l.amount_cents = v_amount
   limit 1;
  if found then return v_link; end if;

  -- Sinon les anciens liens sont revoques : une seule adresse valide.
  update public.devis_payment_links
     set revoked_at = now()
   where mission_id = p_mission and revoked_at is null and paid_at is null;

  insert into public.devis_payment_links (mission_id, token, amount_cents, expires_at, created_by)
  values (
    p_mission,
    encode(gen_random_bytes(18), 'hex'),
    v_amount,
    now() + make_interval(days => greatest(1, least(coalesce(p_validity_days, 30), 90))),
    p_created_by
  )
  returning * into v_link;

  return v_link;
end;
$function$;

revoke all on function secoto_private.devis_link(uuid, integer, integer, uuid) from public, anon, authenticated;

-- 4. Cote administrateur : creer et relire le lien -----------------------------
create or replace function public.secoto_admin_devis_link(
  p_mission uuid,
  p_amount_cents integer default null,
  p_validity_days integer default 30
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, secoto_private
as $function$
declare
  v_link public.devis_payment_links%rowtype;
  v_base text;
begin
  if not exists (
    select 1 from public.accounts a
     where a.id = auth.uid() and a.role::text = 'admin' and a.deleted_at is null
  ) then
    raise exception 'Reserve a l''administrateur SECOTO.';
  end if;

  v_link := secoto_private.devis_link(p_mission, p_amount_cents, p_validity_days, auth.uid());

  select coalesce(value ->> 'app_url', 'https://app.secoto-transport.fr')
    into v_base from public.app_settings where key = 'branding';
  v_base := coalesce(v_base, 'https://app.secoto-transport.fr');

  return jsonb_build_object(
    'url',          v_base || '/.netlify/functions/devis-pay?t=' || v_link.token,
    'amount_cents', v_link.amount_cents,
    'expires_at',   v_link.expires_at
  );
end;
$function$;

grant execute on function public.secoto_admin_devis_link(uuid, integer, integer) to authenticated;

-- 5. Cote serveur : ouvrir le lien et preparer le paiement ----------------------
-- Appelee uniquement par la fonction Netlify devis-pay (service_role). Elle ne
-- renvoie jamais d'identifiant de mission au client.
create or replace function public.secoto_devis_link_open(p_token text)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, secoto_private
as $function$
declare
  v_link    public.devis_payment_links%rowtype;
  v_mission public.missions%rowtype;
  v_account uuid;
  v_payment public.payments%rowtype;
begin
  select * into v_link
    from public.devis_payment_links l
   where l.token = p_token
   for update;
  if not found then return jsonb_build_object('error', 'lien_inconnu'); end if;
  if v_link.paid_at is not null then return jsonb_build_object('error', 'deja_paye'); end if;
  if v_link.revoked_at is not null then return jsonb_build_object('error', 'lien_revoque'); end if;
  if v_link.expires_at <= now() then return jsonb_build_object('error', 'lien_expire'); end if;

  select * into v_mission from public.missions m where m.id = v_link.mission_id;
  if not found then return jsonb_build_object('error', 'lien_inconnu'); end if;
  if v_mission.cancelled_at is not null then return jsonb_build_object('error', 'course_annulee'); end if;
  if coalesce(v_mission.payment_status, '') = 'paid' then
    return jsonb_build_object('error', 'deja_paye');
  end if;

  -- payments.account_id est obligatoire : faute de compte client, la ligne est
  -- rattachee au compte SECOTO, qui reste le beneficiaire de l'encaissement.
  v_account := v_mission.client_account_id;
  if v_account is null then
    select a.id into v_account from public.accounts a
     where a.role::text = 'admin' and a.deleted_at is null
     order by a.created_at limit 1;
  end if;
  if v_account is null then return jsonb_build_object('error', 'compte_introuvable'); end if;

  -- Une seule ligne de paiement par lien : un client qui recharge la page ne
  -- doit pas semer des paiements en attente.
  select * into v_payment
    from public.payments p
   where p.mission_id = v_link.mission_id
     and p.purpose = 'devis_course'
     and p.status in ('pending', 'processing')
     and p.amount_cents = v_link.amount_cents
   order by p.created_at desc
   limit 1;

  if not found then
    insert into public.payments (mission_id, account_id, purpose, amount_cents, currency, status)
    values (v_link.mission_id, v_account, 'devis_course', v_link.amount_cents, v_link.currency, 'pending')
    returning * into v_payment;
  end if;

  update public.devis_payment_links
     set payment_id = v_payment.id
   where id = v_link.id;

  return jsonb_build_object(
    'payment_id',   v_payment.id,
    'amount_cents', v_payment.amount_cents,
    'currency',     v_payment.currency,
    'reference',    coalesce(v_mission.public_ref, ''),
    'trajet',       coalesce(v_mission.from_city, '') || ' - ' || coalesce(v_mission.to_city, ''),
    'vehicule',     coalesce(nullif(v_mission.vehicle, ''), '')
  );
end;
$function$;

revoke all on function public.secoto_devis_link_open(text) from public, anon, authenticated;

-- 6. Le paiement vaut acceptation ----------------------------------------------
-- secoto_settle_payment marque deja la mission payee. Il reste a considerer le
-- devis comme accepte : on le passe en « signe », ce qui declenche la chaine
-- documentaire existante, puis on libere le bon de mission.
create or replace function secoto_private.devis_course_paid()
returns trigger
language plpgsql
security definer
set search_path = public, secoto_private
as $function$
declare
  v_devis public.documents%rowtype;
begin
  if new.purpose <> 'devis_course' or new.status <> 'paid' or coalesce(old.status, '') = 'paid' then
    return new;
  end if;

  update public.devis_payment_links
     set paid_at = now(), payment_id = new.id
   where mission_id = new.mission_id and paid_at is null;

  select * into v_devis
    from public.documents d
   where d.mission_id = new.mission_id
     and d.doc_type::text = 'devis'
   order by d.created_at desc
   limit 1;

  if found and v_devis.statut::text <> 'signe' then
    update public.documents
       set statut = 'signe'::public.secoto_doc_statut,
           signed_at = now()
     where id = v_devis.id;
  end if;

  perform public.secoto_release_mission_order(new.mission_id);
  return new;
end;
$function$;

drop trigger if exists trg_devis_course_paid on public.payments;
create trigger trg_devis_course_paid
after update of status on public.payments
for each row execute function secoto_private.devis_course_paid();

-- 7. Le bouton dans le devis ----------------------------------------------------
-- La maquette porte desormais {{BOUTON_PAIEMENT}} : on l'alimente au moment du
-- rendu, sans toucher au reste de secoto_render_document.
do $patch$
declare
  v_src  text;
  v_new  text;
  v_anchor text := '      v_html := replace(v_html, ''{{CONTACT_SUR_PLACE}}''';
  v_insert text;
begin
  select pg_get_functiondef(p.oid) into v_src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'secoto_render_document'
   limit 1;
  if v_src is null then
    raise notice 'secoto_render_document absente : bouton de paiement non pose.';
    return;
  end if;
  if position('{{BOUTON_PAIEMENT}}' in v_src) > 0 then
    raise notice 'Bouton de paiement deja pose.';
    return;
  end if;
  if position(v_anchor in v_src) = 0 then
    raise notice 'Point d''insertion introuvable : bouton de paiement non pose.';
    return;
  end if;

  v_insert :=
    '      declare' || chr(10) ||
    '        v_lien public.devis_payment_links%rowtype;' || chr(10) ||
    '        v_url  text;' || chr(10) ||
    '      begin' || chr(10) ||
    '        v_lien := secoto_private.devis_link(p_mission, null, 30, null);' || chr(10) ||
    '        select coalesce(value ->> ''app_url'', ''https://app.secoto-transport.fr'')' || chr(10) ||
    '          into v_url from public.app_settings where key = ''branding'';' || chr(10) ||
    '        v_url := coalesce(v_url, ''https://app.secoto-transport.fr'')' || chr(10) ||
    '                 || ''/.netlify/functions/devis-pay?t='' || v_lien.token;' || chr(10) ||
    '        v_html := replace(v_html, ''{{BOUTON_PAIEMENT}}'',' || chr(10) ||
    '          ''<a href="'' || v_url || ''" style="display:inline-block;padding:14px 26px;'' ||' || chr(10) ||
    '          ''background:#e8622a;color:#ffffff;border-radius:10px;font-weight:700;'' ||' || chr(10) ||
    '          ''text-decoration:none">Payer la course — '' ||' || chr(10) ||
    '          public.secoto_fmt_amount(v_lien.amount_cents / 100.0) || ''</a>'');' || chr(10) ||
    '      exception when others then' || chr(10) ||
    '        -- Un devis doit sortir meme si le lien ne peut pas etre fabrique.' || chr(10) ||
    '        v_html := replace(v_html, ''{{BOUTON_PAIEMENT}}'', '''');' || chr(10) ||
    '      end;' || chr(10);

  v_new := replace(v_src, v_anchor, v_insert || v_anchor);
  execute v_new;
end;
$patch$;

-- 8. Rechargement du schema pour PostgREST --------------------------------------
notify pgrst, 'reload schema';
