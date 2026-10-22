-- ============================================================================
-- SECOTO — MIGRATION 115 : CONTACTS SUR PLACE (ENLÈVEMENT ET LIVRAISON)
-- ----------------------------------------------------------------------------
-- Demande de Nawfal du 22/10/2026 : une fois la course réservée, le client
-- indique qui contacter à l'enlèvement et à la livraison :
--   · professionnel : un nom (garage, concession…) suffit, téléphone facultatif ;
--   · particulier : téléphone OBLIGATOIRE.
-- Le transporteur attribué les voit dans sa mission (« Notes », lisible même
-- avec une ancienne application), avec le téléphone du client s'il manquait.
-- Les missions vitrines (114) ne reçoivent jamais ces coordonnées.
-- ADDITIF, rejouable.
-- ============================================================================

alter table public.transport_orders
  add column if not exists contact_enlevement jsonb,
  add column if not exists contact_livraison jsonb;

-- +33612345678 -> 06 12 34 56 78 (autres pays : inchangé).
create or replace function secoto_private.tel_lisible(p text)
returns text language sql immutable set search_path = ''
as $f$
  select case when p ~ '^\+33[1-9][0-9]{8}$'
              then regexp_replace('0' || substr(p, 4), '(\d{2})(?=\d)', '\1 ', 'g')
              else p end;
$f$;

-- Valide un contact : { nom, telephone } nettoyés, ou exception claire.
create or replace function secoto_private.contact_sur_place(p jsonb, p_pro boolean, p_lieu text)
returns jsonb language plpgsql immutable set search_path = ''
as $f$
declare v_nom text; v_brut text; v_tel text;
begin
  v_nom := nullif(left(btrim(coalesce(p ->> 'nom', '')), 120), '');
  v_brut := nullif(btrim(coalesce(p ->> 'telephone', '')), '');
  v_tel := secoto_private.tel_propre(v_brut);
  if v_brut is not null and v_tel is null then
    raise exception 'Numéro de téléphone invalide pour le contact %.', p_lieu;
  end if;
  if p_pro and v_nom is null and v_tel is null then
    raise exception 'Indiquez au moins le nom (garage, société…) du contact %.', p_lieu;
  end if;
  if not p_pro and v_tel is null then
    raise exception 'Indiquez le numéro de téléphone du contact %.', p_lieu;
  end if;
  return jsonb_build_object('nom', v_nom, 'telephone', v_tel);
end;
$f$;

-- Le client enregistre (ou corrige) ses contacts, jusqu'à la livraison.
create or replace function public.secoto_od_contacts_sur_place(p_order_id uuid, p_enlevement jsonb, p_livraison jsonb)
returns jsonb language plpgsql security definer set search_path = ''
as $f$
declare
  v_user uuid := secoto_private.assert_authenticated();
  v_order public.transport_orders%rowtype;
  v_pro boolean;
begin
  select * into v_order from public.transport_orders o where o.id = p_order_id and o.account_id = v_user for update;
  if not found then raise exception 'Commande introuvable.' using errcode = 'P0002'; end if;
  if v_order.status not in ('awaiting_payment', 'searching_partner', 'partner_locked', 'partner_confirmed', 'picked_up') then
    raise exception 'Cette commande ne peut plus être modifiée.';
  end if;
  select coalesce(a.client_type, 'particulier') = 'pro' into v_pro from public.accounts a where a.id = v_user;
  update public.transport_orders
     set contact_enlevement = secoto_private.contact_sur_place(p_enlevement, v_pro, 'à l''enlèvement'),
         contact_livraison = secoto_private.contact_sur_place(p_livraison, v_pro, 'à la livraison'),
         updated_at = now()
   where id = p_order_id returning * into v_order;
  -- Particulier sans numéro sur son compte : celui de l'enlèvement le complète.
  update public.accounts a set phone = v_order.contact_enlevement ->> 'telephone'
   where a.id = v_user and nullif(btrim(coalesce(a.phone, '')), '') is null and not v_pro
     and v_order.contact_enlevement ->> 'telephone' is not null;
  return secoto_private.order_client_json(v_order);
end;
$f$;
revoke all on function public.secoto_od_contacts_sur_place(uuid, jsonb, jsonb) from public, anon;
grant execute on function public.secoto_od_contacts_sur_place(uuid, jsonb, jsonb) to authenticated;

-- Report sur la mission attribuée (bloc « [Contacts sur place] » dans les notes).
create or replace function secoto_private.od_contacts_vers_mission(p_order_id uuid)
returns void language plpgsql security definer set search_path = ''
as $f$
declare
  v_order public.transport_orders%rowtype;
  v_bloc text;
  v_tel_client text;
begin
  select * into v_order from public.transport_orders o where o.id = p_order_id;
  if v_order.mission_id is null or (v_order.contact_enlevement is null and v_order.contact_livraison is null) then return; end if;
  v_bloc := '[Contacts sur place] Enlèvement : '
    || coalesce(nullif(concat_ws(' · ', v_order.contact_enlevement ->> 'nom', secoto_private.tel_lisible(v_order.contact_enlevement ->> 'telephone')), ''), 'à préciser')
    || ' | Livraison : '
    || coalesce(nullif(concat_ws(' · ', v_order.contact_livraison ->> 'nom', secoto_private.tel_lisible(v_order.contact_livraison ->> 'telephone')), ''), 'à préciser');
  select nullif(btrim(coalesce(a.phone, '')), '') into v_tel_client from public.accounts a where a.id = v_order.account_id;
  update public.missions m
     set notes = left(btrim(regexp_replace(coalesce(m.notes, ''), '\s*\[Contacts sur place\].*$', '') || ' ' || v_bloc), 2000),
         client_phone = coalesce(nullif(btrim(coalesce(m.client_phone, '')), ''),
                                 v_tel_client,
                                 v_order.contact_enlevement ->> 'telephone',
                                 v_order.contact_livraison ->> 'telephone')
   where m.id = v_order.mission_id and m.od_order_id is null;
end;
$f$;

create or replace function secoto_private.trg_od_contacts()
returns trigger language plpgsql security definer set search_path = ''
as $f$
begin
  if new.mission_id is not null
     and (new.contact_enlevement is distinct from old.contact_enlevement
          or new.contact_livraison is distinct from old.contact_livraison
          or new.mission_id is distinct from old.mission_id) then
    perform secoto_private.od_contacts_vers_mission(new.id);
    if new.assigned_partner_id is not null and new.mission_id is not distinct from old.mission_id then
      perform secoto_private.notify_event(new.assigned_partner_id, 'course_assigned', 'Contacts sur place mis à jour',
        format('Commande %s : le client a indiqué les contacts à l''enlèvement et à la livraison.', new.public_ref),
        new.mission_id, 'assigned', 'od-contacts:' || new.id::text || ':' || md5(coalesce(new.contact_enlevement::text, '') || coalesce(new.contact_livraison::text, '')), new.id);
    end if;
  end if;
  return new;
exception when others then
  return new;  -- un contact ne bloque jamais une commande
end;
$f$;
drop trigger if exists trg_secoto_od_contacts on public.transport_orders;
create trigger trg_secoto_od_contacts
  after update of contact_enlevement, contact_livraison, mission_id on public.transport_orders
  for each row execute function secoto_private.trg_od_contacts();

-- Le client voit ses contacts et son type de compte dans sa commande.
select secoto_private.mig074_patch('secoto_private.order_client_json(public.transport_orders)'::regprocedure,
  '''mode_reglement'', o.mode_reglement, ''debit_a_livraison'', coalesce(p.debit_a_livraison, false),',
  '''mode_reglement'', o.mode_reglement, ''debit_a_livraison'', coalesce(p.debit_a_livraison, false),
    ''contact_enlevement'', o.contact_enlevement, ''contact_livraison'', o.contact_livraison,  -- 115
    ''client_pro'', (select coalesce(a.client_type, ''particulier'') = ''pro'' from public.accounts a where a.id = o.account_id),');

notify pgrst, 'reload schema';
