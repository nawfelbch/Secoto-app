-- ============================================================================
-- SECOTO — Patch « emission 100 % automatique des documents »
-- ----------------------------------------------------------------------------
-- A coller dans Supabase > SQL Editor > Run. Idempotent.
-- A lancer APRES patch_temps_reel.sql et patch_documents_signature.sql.
--
-- POURQUOI CE PATCH
-- Jusqu'ici le devis etait fabrique par le navigateur de l'administrateur puis
-- envoye a la base. Si ce navigateur echouait (page fermee, reseau, ancienne
-- version en cache), AUCUN devis ne partait et tout le circuit restait bloque.
--
-- Desormais la base fabrique et envoie les documents ELLE-MEME :
--   des que missions.status passe a 'assigned', le DEVIS est genere, envoye au
--   client et notifie ; le BON DE MISSION est prepare et partira tout seul a la
--   signature du client. Plus aucune dependance a l'application.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1) MODELES DE DOCUMENTS stockes en base
-- ----------------------------------------------------------------------------
create table if not exists public.doc_templates (
  kind       text primary key,          -- devis | bon_de_mission | facture
  html       text not null,
  updated_at timestamptz not null default now()
);

comment on table public.doc_templates is
  'Maquettes HTML des documents. Alimentees automatiquement par l''application '
  '(espace admin) et utilisees par la base pour generer les documents.';

alter table public.doc_templates enable row level security;

drop policy if exists doc_templates_read  on public.doc_templates;
drop policy if exists doc_templates_admin on public.doc_templates;

create policy doc_templates_read on public.doc_templates
  for select to authenticated using (true);

create policy doc_templates_admin on public.doc_templates
  for all to authenticated
  using (public.secoto_is_admin()) with check (public.secoto_is_admin());

-- Enregistrement d'une maquette depuis l'application (admin uniquement).
create or replace function public.secoto_save_doc_template(p_kind text, p_html text)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.secoto_is_admin() then
    raise exception 'Reserve a l''administrateur SECOTO.';
  end if;
  if p_html is null or length(p_html) < 100 then
    raise exception 'Maquette vide.';
  end if;

  insert into public.doc_templates (kind, html, updated_at)
  values (p_kind, p_html, now())
  on conflict (kind) do update
    set html = excluded.html, updated_at = now()
  where public.doc_templates.html is distinct from excluded.html;
end $$;

grant execute on function public.secoto_save_doc_template(text, text) to authenticated;

-- ----------------------------------------------------------------------------
-- 2) OUTILS DE MISE EN FORME (identiques au calcul cote application)
-- ----------------------------------------------------------------------------

-- Echappement HTML des valeurs inserees dans la maquette.
create or replace function public.secoto_esc(p text)
returns text language sql immutable as $$
  select replace(replace(replace(coalesce(p, ''), '&', '&amp;'), '<', '&lt;'), '>', '&gt;');
$$;

-- Montant au format documentaire SECOTO : « 465.00 € ».
create or replace function public.secoto_fmt_amount(p numeric)
returns text language sql immutable as $$
  select trim(to_char(coalesce(p, 0), 'FM9999999990.00')) || ' €';
$$;

-- Date au format francais.
create or replace function public.secoto_fmt_date(p timestamptz)
returns text language sql stable as $$
  select case when p is null then '' else to_char(p, 'DD/MM/YYYY') end;
$$;

-- Distance affichee : « 465 km » ou « Non renseignee ».
create or replace function public.secoto_fmt_distance(p numeric)
returns text language sql immutable as $$
  select case
    when p is null or p = 0 then 'Non renseignee'
    else rtrim(rtrim(trim(to_char(p, 'FM9999999990.99')), '0'), '.') || ' km'
  end;
$$;

-- ----------------------------------------------------------------------------
-- 3) MOTEUR DE RENDU (equivalent SQL de templateEngine + documents.js)
-- ----------------------------------------------------------------------------
create or replace function public.secoto_render_document(
  p_mission uuid,
  p_kind    text,           -- devis | bon_de_mission | facture
  p_numero  text,
  p_ref_devis text default ''
)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  m            public.missions%rowtype;
  v_html       text;
  v_tpl        text;
  v_client     numeric;
  v_carrier    numeric;
  v_especes    boolean;
  v_reglement  text;
  v_client_type text := 'Professionnel';
  v_bank       jsonb;
  v_tr         record;
  v_distance   text;
  v_date_doc   text := to_char(now(), 'DD/MM/YYYY');
  v_livraison  text;
begin
  select * into m from public.missions where id = p_mission;
  if m.id is null then
    raise exception 'Mission introuvable.';
  end if;

  select html into v_tpl from public.doc_templates where kind = p_kind;
  if v_tpl is null then
    raise exception 'Maquette « % » absente : ouvrez l''espace administrateur de '
      'l''application une fois pour la synchroniser, puis reessayez.', p_kind;
  end if;

  v_client   := public.secoto_compute_client_price(m.type::text, m.distance_km, m.carrier_cost);
  v_carrier  := public.secoto_compute_carrier_pay(m.type::text, m.distance_km, m.carrier_cost);
  v_especes  := coalesce(m.payment_method, 'virement') = 'especes';
  v_reglement := case when v_especes
                      then 'Reglement en especes a la livraison'
                      else 'Reglement par virement bancaire' end;
  v_distance := public.secoto_fmt_distance(m.distance_km);
  v_livraison := public.secoto_fmt_date(coalesce(m.mission_date::timestamptz, now()));

  if m.client_account_id is not null then
    select case when a.client_type = 'particulier' then 'Particulier' else 'Professionnel' end
      into v_client_type
    from public.accounts a where a.id = m.client_account_id;
  end if;

  v_html := v_tpl;

  -- ---- jetons communs ----
  v_html := replace(v_html, '{{NUMERO_DOC}}',      public.secoto_esc(p_numero));
  v_html := replace(v_html, '{{DATE_DOC}}',        v_date_doc);
  v_html := replace(v_html, '{{VEHICULE}}',        public.secoto_esc(coalesce(nullif(m.vehicle, ''), 'Non renseigne')));
  v_html := replace(v_html, '{{ADRESSE_DEPART}}',  public.secoto_esc(coalesce(nullif(m.pickup_address, ''), m.from_city, '')));
  v_html := replace(v_html, '{{ADRESSE_ARRIVEE}}', public.secoto_esc(coalesce(nullif(m.delivery_address, ''), m.to_city, '')));
  v_html := replace(v_html, '{{DATE_ENLEVEMENT}}', public.secoto_fmt_date(m.mission_date::timestamptz));
  v_html := replace(v_html, '{{DATE_LIVRAISON}}',  v_livraison);
  v_html := replace(v_html, '{{DISTANCE}}',        v_distance);
  v_html := replace(v_html, '{{LIGNE_DISTANCE}}',  v_distance);

  if p_kind = 'bon_de_mission' then
    -- ---- BON DE MISSION : rien d'autre que la remuneration transporteur ----
    select a.full_name, a.city, a.phone into v_tr
    from public.accounts a where a.id = m.assigned_transporter_id;

    v_html := replace(v_html, '{{TRANSPORTEUR_NOM}}',     public.secoto_esc(coalesce(v_tr.full_name, m.assigned_transporter_name, 'Transporteur')));
    v_html := replace(v_html, '{{TRANSPORTEUR_ADRESSE}}', public.secoto_esc(coalesce(v_tr.city, '')));
    v_html := replace(v_html, '{{TRANSPORTEUR_SIRET}}',   '');
    v_html := replace(v_html, '{{TRANSPORTEUR_TEL}}',     public.secoto_esc(coalesce(v_tr.phone, '')));
    v_html := replace(v_html, '{{CONTACT_DEPART}}',       public.secoto_esc(coalesce(m.client_contact, '')));
    v_html := replace(v_html, '{{CONTACT_ARRIVEE}}',      public.secoto_esc(coalesce(m.client_phone, '')));
    v_html := replace(v_html, '{{LIGNE_TRAJET}}',         public.secoto_esc(coalesce(m.from_city, '') || ' > ' || coalesce(m.to_city, '')));
    v_html := replace(v_html, '{{LIGNE_VEHICULE}}',       public.secoto_esc(coalesce(nullif(m.vehicle, ''), 'Non renseigne')));
    v_html := replace(v_html, '{{LIGNE_MONTANT}}',        public.secoto_fmt_amount(v_carrier));
    v_html := replace(v_html, '{{TOTAL_TRANSPORTEUR}}',   public.secoto_fmt_amount(v_carrier));

    -- Garde-fou : le prix client ne doit JAMAIS figurer sur ce document.
    if v_client > 0 and v_client <> v_carrier
       and position(public.secoto_fmt_amount(v_client) in v_html) > 0 then
      raise exception 'Bon de mission : fuite du montant client detectee, generation annulee.';
    end if;

  else
    -- ---- DEVIS et FACTURE : uniquement les montants client ----
    v_html := replace(v_html, '{{CLIENT_NOM}}',     public.secoto_esc(coalesce(nullif(m.client_name, ''), 'Client')));
    v_html := replace(v_html, '{{CLIENT_TYPE}}',    v_client_type);
    v_html := replace(v_html, '{{CLIENT_CONTACT}}', public.secoto_esc(coalesce(nullif(m.client_contact, ''), m.client_phone, '')));
    v_html := replace(v_html, '{{LIGNE_DETAIL}}',   'Prestation de mise en relation');
    v_html := replace(v_html, '{{LIGNE_MONTANT}}',  public.secoto_fmt_amount(v_client));
    v_html := replace(v_html, '{{TOTAL}}',          public.secoto_fmt_amount(v_client));

    if p_kind = 'devis' then
      v_html := replace(v_html, '{{CONTACT_SUR_PLACE}}', public.secoto_esc(coalesce(m.client_contact, '')));
      v_html := replace(v_html, '{{CONDITION_DATES}}',
        v_reglement || '. Dates indicatives, a confirmer selon disponibilite.');
    else
      select value into v_bank from public.app_settings where key = 'bank_details';
      v_html := replace(v_html, '{{DATE_ECHEANCE}}', v_date_doc);
      v_html := replace(v_html, '{{REF_DEVIS}}',     public.secoto_esc(coalesce(p_ref_devis, '')));
      v_html := replace(v_html, '{{TITULAIRE_COMPTE}}',
        case when v_especes then 'Especes a la livraison'
             else public.secoto_esc(coalesce(v_bank ->> 'titulaire', 'Nawfal Benchiha')) end);
      v_html := replace(v_html, '{{IBAN}}',
        case when v_especes then 'Non applicable (reglement en especes)'
             else public.secoto_esc(coalesce(v_bank ->> 'iban', '')) end);
      v_html := replace(v_html, '{{BIC}}',
        case when v_especes then 'Non applicable'
             else public.secoto_esc(coalesce(v_bank ->> 'bic', '')) end);
    end if;
  end if;

  -- Aucun jeton ne doit subsister dans le document final.
  if v_html ~ '\{\{[A-Z0-9_]+\}\}' then
    raise exception 'Document incomplet : jeton non resolu (%).',
      substring(v_html from '\{\{[A-Z0-9_]+\}\}');
  end if;

  return v_html;
end $$;

-- ----------------------------------------------------------------------------
-- 4) EMISSION INTERNE (utilisee par le declencheur ET par le bouton admin)
-- ----------------------------------------------------------------------------
create or replace function public.secoto_issue_mission_docs(p_mission uuid)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  m        public.missions%rowtype;
  v_num    text;
  v_html   text;
  v_report text := '';
begin
  select * into m from public.missions where id = p_mission;
  if m.id is null then
    raise exception 'Mission introuvable.';
  end if;
  if m.assigned_transporter_id is null then
    raise exception 'Aucun transporteur attribue a cette mission.';
  end if;

  -- ---- DEVIS au client (a signer) ----
  if m.client_account_id is not null then
    if exists (select 1 from public.documents
               where mission_id = p_mission and doc_type = 'devis' and statut::text = 'signe') then
      v_report := v_report || 'Devis deja signe (inchange). ';
    else
      delete from public.documents
       where mission_id = p_mission and doc_type = 'devis' and immutable is not true;

      v_num  := public.secoto_next_doc_number('devis');
      v_html := public.secoto_render_document(p_mission, 'devis', v_num);

      insert into public.documents (
        account_id, recipient_id, mission_id, doc_type, numero, statut,
        html_snapshot, needs_signature, emitted_at, file_name
      ) values (
        m.client_account_id, m.client_account_id, p_mission, 'devis', v_num, 'envoye',
        v_html, true, now(), v_num || '.html'
      );
      v_report := v_report || 'Devis ' || v_num || ' envoye au client. ';
    end if;
  else
    v_report := v_report || 'Course non reliee a un compte client : devis non envoyable dans l''application. ';
  end if;

  -- ---- BON DE MISSION au transporteur ----
  if exists (select 1 from public.documents
             where mission_id = p_mission and doc_type = 'bon_de_mission' and statut::text = 'signe') then
    v_report := v_report || 'Bon de mission deja signe (inchange).';
  else
    delete from public.documents
     where mission_id = p_mission and doc_type = 'bon_de_mission' and immutable is not true;

    v_num  := public.secoto_next_doc_number('bon_de_mission');
    v_html := public.secoto_render_document(p_mission, 'bon_de_mission', v_num);

    insert into public.documents (
      account_id, recipient_id, mission_id, doc_type, numero, statut,
      html_snapshot, needs_signature, emitted_at, file_name
    ) values (
      m.assigned_transporter_id, m.assigned_transporter_id, p_mission, 'bon_de_mission', v_num,
      -- Sans compte client, personne ne signera le devis : le bon part tout de suite.
      case when m.client_account_id is null then 'envoye' else 'brouillon' end,
      v_html, true,
      case when m.client_account_id is null then now() else null end,
      v_num || '.html'
    );
    v_report := v_report || case when m.client_account_id is null
                                 then 'Bon de mission ' || v_num || ' envoye au transporteur.'
                                 else 'Bon de mission ' || v_num || ' pret : il partira des la signature du client.' end;
  end if;

  return v_report;
end $$;

-- Version appelable depuis l'application (bouton « Envoyer le devis au client »).
create or replace function public.secoto_emit_mission_documents(p_mission uuid)
returns text
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.secoto_is_admin() then
    raise exception 'Reserve a l''administrateur SECOTO.';
  end if;
  return public.secoto_issue_mission_docs(p_mission);
end $$;

grant execute on function public.secoto_emit_mission_documents(uuid) to authenticated;

-- ----------------------------------------------------------------------------
-- 5) FACTURE (envoi decide par l'admin)
-- ----------------------------------------------------------------------------
create or replace function public.secoto_emit_facture(p_mission uuid)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  m      public.missions%rowtype;
  v_num  text;
  v_ref  text;
  v_html text;
begin
  if not public.secoto_is_admin() then
    raise exception 'Reserve a l''administrateur SECOTO.';
  end if;

  select * into m from public.missions where id = p_mission;
  if m.id is null then raise exception 'Mission introuvable.'; end if;
  if m.client_account_id is null then
    raise exception 'Cette course n''est reliee a aucun compte client : utilisez l''apercu imprimable pour transmettre la facture.';
  end if;

  select numero into v_ref from public.documents
   where mission_id = p_mission and doc_type = 'devis' limit 1;

  delete from public.documents
   where mission_id = p_mission and doc_type = 'facture' and immutable is not true
     and coalesce(statut::text, 'brouillon') <> 'signe';

  v_num  := public.secoto_next_doc_number('facture');
  v_html := public.secoto_render_document(p_mission, 'facture', v_num, coalesce(v_ref, ''));

  insert into public.documents (
    account_id, recipient_id, mission_id, doc_type, numero, statut,
    html_snapshot, needs_signature, ref_devis, emitted_at, file_name
  ) values (
    m.client_account_id, m.client_account_id, p_mission, 'facture', v_num, 'envoye',
    v_html, false, v_ref, now(), v_num || '.html'
  );

  return 'Facture ' || v_num || ' envoyee au client.';
end $$;

grant execute on function public.secoto_emit_facture(uuid) to authenticated;

-- ----------------------------------------------------------------------------
-- 6) LE DECLENCHEUR : attribution -> devis envoye automatiquement
-- ----------------------------------------------------------------------------
create or replace function public.secoto_trg_mission_assigned_docs()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.status::text = 'assigned'
     and (old.status::text is distinct from 'assigned'
          or old.assigned_transporter_id is distinct from new.assigned_transporter_id)
     and new.assigned_transporter_id is not null then
    begin
      perform public.secoto_issue_mission_docs(new.id);
    exception when others then
      -- L'attribution ne doit JAMAIS echouer a cause des documents : on
      -- previent l'admin, qui peut relancer l'envoi depuis la fiche mission.
      perform public.secoto_notify_admins(
        'document',
        'Documents non emis',
        'Mission ' || coalesce(new.public_ref, '') || ' : ' || sqlerrm
          || ' — utilisez « Envoyer le devis au client » sur la fiche.',
        new.id
      );
    end;
  end if;
  return new;
end $$;

drop trigger if exists trg_secoto_mission_assigned_docs on public.missions;
create trigger trg_secoto_mission_assigned_docs
  after update on public.missions
  for each row execute function public.secoto_trg_mission_assigned_docs();

-- ----------------------------------------------------------------------------
-- 7) CORRECTIF DE CLOISONNEMENT
-- ----------------------------------------------------------------------------
-- Le bon de mission est cree en brouillon AU NOM du transporteur : sans cette
-- correction il aurait pu le voir avant la signature du client.
drop policy if exists documents_own_select on public.documents;
create policy documents_own_select on public.documents
  for select to authenticated
  using (
    account_id = auth.uid()
    and (doc_type is null or coalesce(statut::text, 'brouillon') <> 'brouillon')
  );

notify pgrst, 'reload schema';
