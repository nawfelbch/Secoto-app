-- ============================================================================
-- SECOTO — MIGRATION 040 : TOUT SE FAIT DEPUIS « DEVIS A ETABLIR »
-- ----------------------------------------------------------------------------
-- Les demandes hors bareme arrivent sur cet ecran. Nawfal y fixe le prix et la
-- date ; le client doit alors recevoir un message avec un lien qui fait tout :
-- devis, paiement, et mise en route de la course.
--
-- Jusqu'ici le client devait ouvrir l'application pour reserver, donc avoir un
-- compte et un telephone compatible. Desormais le paiement du lien VAUT
-- reservation : il cree la commande, enregistre l'encaissement et ouvre la
-- diffusion aux transporteurs, exactement comme la reservation dans l'app.
--
-- Le particulier passe d'abord par une page de confirmation : il demande
-- l'execution immediate et renonce a son delai de retractation. Sans cette
-- trace horodatee, SECOTO devrait rembourser 14 jours apres la course.
-- ============================================================================

-- 1. Un lien peut desormais porter un devis en ligne ---------------------------
alter table public.devis_payment_links alter column mission_id drop not null;
alter table public.devis_payment_links
  add column if not exists quote_id uuid references public.transport_quotes(id) on delete cascade;

do $c$
begin
  if not exists (select 1 from pg_constraint where conname = 'devis_payment_links_cible_check') then
    alter table public.devis_payment_links add constraint devis_payment_links_cible_check
      check (num_nonnulls(mission_id, quote_id) = 1);
  end if;
end;
$c$;

drop index if exists public.devis_payment_links_actif_idx;
create unique index if not exists devis_payment_links_actif_mission_idx
  on public.devis_payment_links (mission_id)
  where mission_id is not null and revoked_at is null and paid_at is null;
create unique index if not exists devis_payment_links_actif_quote_idx
  on public.devis_payment_links (quote_id)
  where quote_id is not null and revoked_at is null and paid_at is null;

-- 2. Le telephone du client, pour le SMS ---------------------------------------
create or replace function public.secoto_admin_quotes(p_status text default null)
returns jsonb language plpgsql stable security definer set search_path = ''
as $f$
begin
  perform secoto_private.assert_admin();
  return coalesce((select jsonb_agg(to_jsonb(q) || jsonb_build_object(
      'client_name', coalesce(a.company_name, a.full_name),
      'client_email', a.email,
      'client_phone', a.phone,
      'client_particulier', (a.client_type = 'particulier'))
    order by q.created_at desc)
    from public.transport_quotes q join public.accounts a on a.id = q.account_id
    where p_status is null or q.status = p_status), '[]'::jsonb);
end;
$f$;

-- 3. Le lien d'un devis en ligne ------------------------------------------------
create or replace function public.secoto_admin_devis_link_quote(
  p_quote uuid,
  p_validity_days integer default 30
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, secoto_private
as $function$
declare
  v_quote public.transport_quotes%rowtype;
  v_link  public.devis_payment_links%rowtype;
  v_base  text;
begin
  if not exists (
    select 1 from public.accounts a
     where a.id = auth.uid() and a.role::text = 'admin' and a.deleted_at is null
  ) then
    raise exception 'Reserve a l''administrateur SECOTO.';
  end if;

  select * into v_quote from public.transport_quotes q where q.id = p_quote;
  if not found then raise exception 'Devis introuvable.'; end if;
  if v_quote.status not in ('priced', 'manual_priced') then
    raise exception 'Fixez d''abord le prix : ce devis est en % .', v_quote.status;
  end if;
  if coalesce(v_quote.client_price_cents, 0) <= 0 then
    raise exception 'Renseignez le Prix client avant de creer le lien.';
  end if;

  select * into v_link
    from public.devis_payment_links l
   where l.quote_id = p_quote
     and l.revoked_at is null and l.paid_at is null
     and l.expires_at > now()
     and l.amount_cents = v_quote.client_price_cents
   limit 1;

  if not found then
    update public.devis_payment_links
       set revoked_at = now()
     where quote_id = p_quote and revoked_at is null and paid_at is null;

    insert into public.devis_payment_links (quote_id, token, amount_cents, expires_at, created_by)
    values (p_quote, encode(gen_random_bytes(18), 'hex'), v_quote.client_price_cents,
            least(
              now() + make_interval(days => greatest(1, least(coalesce(p_validity_days, 30), 90))),
              coalesce(v_quote.valid_until, now() + interval '30 days')
            ),
            auth.uid())
    returning * into v_link;
  end if;

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

grant execute on function public.secoto_admin_devis_link_quote(uuid, integer) to authenticated;

-- 4. Payer vaut reserver ---------------------------------------------------------
-- Meme resultat que secoto_od_book_quote, mais declenche par le lien : le client
-- n'a pas de session ouverte, c'est le compte du devis qui fait foi.
create or replace function secoto_private.od_book_for_link(p_quote uuid)
returns public.payments
language plpgsql
volatile
security definer
set search_path = public, secoto_private
as $function$
declare
  v_quote   public.transport_quotes%rowtype;
  v_order   public.transport_orders%rowtype;
  v_payment public.payments%rowtype;
  v_client_type text;
begin
  select * into v_quote from public.transport_quotes q where q.id = p_quote for update;
  if not found then raise exception 'QUOTE_INTROUVABLE'; end if;
  if v_quote.status not in ('priced', 'manual_priced', 'accepted') then raise exception 'QUOTE_NON_RESERVABLE'; end if;
  if v_quote.pickup_at <= now() then raise exception 'QUOTE_DATE_DEPASSEE'; end if;
  if not secoto_private.flag('od_payments') then raise exception 'PAIEMENTS_FERMES'; end if;

  select * into v_order from public.transport_orders o where o.quote_id = p_quote;
  if not found then
    insert into public.transport_orders(public_ref, quote_id, account_id, business_id, mode, funding, status,
      payment_strategy, client_price_cents, partner_pay_cents, collect_cents, transport_direct_cents, pickup_at)
    values (secoto_private.new_order_ref(), v_quote.id, v_quote.account_id, v_quote.business_id, v_quote.mode,
      'card', 'awaiting_payment', 'capture_then_refund', v_quote.client_price_cents, v_quote.partner_pay_cents,
      v_quote.client_price_cents, 0, v_quote.pickup_at)
    returning * into v_order;

    update public.transport_quotes set status = 'accepted', updated_at = now() where id = p_quote;
    perform secoto_private.audit('order_booked_by_link', 'transport_order', v_order.id::text,
      jsonb_build_object('quote_id', p_quote));
  end if;

  if v_order.status not in ('awaiting_payment', 'paid') then raise exception 'COMMANDE_EN_COURS'; end if;

  select * into v_payment from public.payments p
   where p.order_id = v_order.id and p.status in ('pending', 'processing')
   order by p.created_at desc limit 1;
  if found then return v_payment; end if;

  select case when a.client_type = 'particulier' then 'particulier' else 'pro' end into v_client_type
    from public.accounts a where a.id = v_quote.account_id;

  insert into public.payments(mission_id, order_id, account_id, purpose, amount_cents, status, capture_method, waiver_required)
  values (null, v_order.id, v_quote.account_id,
    case when v_order.mode = 'plateau' then 'od_plateau' else 'od_convoyage' end,
    v_order.collect_cents, 'pending', 'automatic',
    coalesce(v_client_type, 'pro') = 'particulier')
  returning * into v_payment;

  update public.transport_orders set payment_id = v_payment.id where id = v_order.id;
  return v_payment;
end;
$function$;

revoke all on function secoto_private.od_book_for_link(uuid) from public, anon, authenticated;

-- 5. Ouverture du lien : mission OU devis en ligne --------------------------------
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
  v_quote   public.transport_quotes%rowtype;
  v_account uuid;
  v_payment public.payments%rowtype;
begin
  select * into v_link from public.devis_payment_links l where l.token = p_token for update;
  if not found then return jsonb_build_object('error', 'lien_inconnu'); end if;
  if v_link.paid_at is not null then return jsonb_build_object('error', 'deja_paye'); end if;
  if v_link.revoked_at is not null then return jsonb_build_object('error', 'lien_revoque'); end if;
  if v_link.expires_at <= now() then return jsonb_build_object('error', 'lien_expire'); end if;

  -- ---- Devis du transport a la demande ----------------------------------------
  if v_link.quote_id is not null then
    select * into v_quote from public.transport_quotes q where q.id = v_link.quote_id;
    if not found then return jsonb_build_object('error', 'lien_inconnu'); end if;

    begin
      v_payment := secoto_private.od_book_for_link(v_link.quote_id);
    exception
      when others then
        return jsonb_build_object('error', case
          when sqlerrm like '%DATE_DEPASSEE%' then 'date_depassee'
          when sqlerrm like '%PAIEMENTS_FERMES%' then 'compte_introuvable'
          when sqlerrm like '%COMMANDE_EN_COURS%' then 'deja_paye'
          else 'lien_inconnu' end);
    end;

    if v_payment.status = 'paid' then return jsonb_build_object('error', 'deja_paye'); end if;

    update public.devis_payment_links set payment_id = v_payment.id where id = v_link.id;

    return jsonb_build_object(
      'payment_id',      v_payment.id,
      'amount_cents',    v_payment.amount_cents,
      'currency',        v_payment.currency,
      'purpose',         v_payment.purpose,
      'waiver_required', coalesce(v_payment.waiver_required, false) and not coalesce(v_payment.waiver_accepted, false),
      'reference',       coalesce((select o.public_ref from public.transport_orders o where o.id = v_payment.order_id), ''),
      'trajet',          coalesce(v_quote.pickup ->> 'city', '') || ' - ' || coalesce(v_quote.delivery ->> 'city', ''),
      'vehicule',        coalesce(v_quote.vehicle ->> 'model', '')
    );
  end if;

  -- ---- Mission creee a la main --------------------------------------------------
  select * into v_mission from public.missions m where m.id = v_link.mission_id;
  if not found then return jsonb_build_object('error', 'lien_inconnu'); end if;
  if v_mission.cancelled_at is not null then return jsonb_build_object('error', 'course_annulee'); end if;
  if lower(coalesce(v_mission.payment_method, '')) in ('especes', 'espèces', 'cash') then
    return jsonb_build_object('error', 'reglement_especes');
  end if;
  if coalesce(v_mission.payment_status, '') = 'paid' then return jsonb_build_object('error', 'deja_paye'); end if;

  v_account := v_mission.client_account_id;
  if v_account is null then
    select a.id into v_account from public.accounts a
     where a.role::text = 'admin' and a.deleted_at is null
     order by a.created_at limit 1;
  end if;
  if v_account is null then return jsonb_build_object('error', 'compte_introuvable'); end if;

  select * into v_payment from public.payments p
   where p.mission_id = v_link.mission_id
     and p.purpose = 'devis_course'
     and p.status in ('pending', 'processing')
     and p.amount_cents = v_link.amount_cents
   order by p.created_at desc limit 1;

  if not found then
    insert into public.payments (mission_id, account_id, purpose, amount_cents, currency, status)
    values (v_link.mission_id, v_account, 'devis_course', v_link.amount_cents, v_link.currency, 'pending')
    returning * into v_payment;
  end if;

  update public.devis_payment_links set payment_id = v_payment.id where id = v_link.id;

  return jsonb_build_object(
    'payment_id',      v_payment.id,
    'amount_cents',    v_payment.amount_cents,
    'currency',        v_payment.currency,
    'purpose',         v_payment.purpose,
    'waiver_required', false,
    'reference',       coalesce(v_mission.public_ref, ''),
    'trajet',          coalesce(v_mission.from_city, '') || ' - ' || coalesce(v_mission.to_city, ''),
    'vehicule',        coalesce(nullif(v_mission.vehicle, ''), '')
  );
end;
$function$;

revoke all on function public.secoto_devis_link_open(text) from public, anon, authenticated;

-- 6. La renonciation au delai de retractation -------------------------------------
create or replace function public.secoto_devis_link_waiver(p_token text, p_accepted boolean)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, secoto_private
as $function$
declare
  v_link    public.devis_payment_links%rowtype;
  v_payment public.payments%rowtype;
begin
  if not coalesce(p_accepted, false) then return jsonb_build_object('error', 'consentement_refuse'); end if;

  select * into v_link from public.devis_payment_links l where l.token = p_token;
  if not found or v_link.payment_id is null then return jsonb_build_object('error', 'lien_inconnu'); end if;

  update public.payments
     set waiver_accepted    = true,
         waiver_accepted_at = now(),
         waiver_text_version = coalesce(waiver_text_version, 'lien-devis-2026-09'),
         updated_at         = now()
   where id = v_link.payment_id and status in ('pending', 'processing')
  returning * into v_payment;

  if not found then return jsonb_build_object('error', 'lien_inconnu'); end if;
  return jsonb_build_object('ok', true, 'payment_id', v_payment.id);
end;
$function$;

revoke all on function public.secoto_devis_link_waiver(text, boolean) from public, anon, authenticated;

notify pgrst, 'reload schema';
