-- ============================================================================
-- SECOTO — Patch « circuit des documents + signature electronique »
-- ----------------------------------------------------------------------------
-- A coller tel quel dans Supabase > SQL Editor > Run. Idempotent.
-- A LANCER APRES patch_temps_reel.sql.
--
-- Circuit mis en place :
--   1. L'admin attribue une mission a un transporteur
--      -> DEVIS envoye au client (notification + signature dans l'app)
--      -> BON DE MISSION prepare mais NON visible du transporteur.
--   2. Le client signe le devis
--      -> le BON DE MISSION est automatiquement envoye au transporteur
--         (notification), sans aucune action de l'admin.
--   3. Le transporteur signe le bon de mission
--      -> l'admin est notifie (preuve d'acceptation de la mission).
--   4. L'admin envoie la FACTURE quand il le decide
--      -> notification au client, telechargeable dans l'app.
--
-- Cloisonnement conserve : le transporteur ne voit JAMAIS un devis ni une
-- facture (montants client) ; le client ne voit JAMAIS un bon de mission
-- (remuneration transporteur).
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1) COLONNES DU CYCLE DE VIE
-- ----------------------------------------------------------------------------
alter table public.documents add column if not exists recipient_id  uuid references public.accounts(id) on delete set null;
alter table public.documents add column if not exists html_snapshot text;   -- document fige a l'emission
alter table public.documents add column if not exists emitted_at    timestamptz;
alter table public.documents add column if not exists signed_at     timestamptz;
alter table public.documents add column if not exists needs_signature boolean not null default false;

comment on column public.documents.html_snapshot is
  'Document rendu et fige au moment de l''emission : ce que le destinataire '
  'consulte, signe et telecharge. Garantit qu''un document signe ne change plus.';

create index if not exists idx_documents_recipient on public.documents (recipient_id, statut);
create index if not exists idx_documents_mission_type on public.documents (mission_id, doc_type);

-- Colonnes HERITEES (file_path, file_url, type, document_type...) declarees
-- obligatoires pour les pieces justificatives : elles n'ont aucun sens pour un
-- devis genere. On les rend facultatives sans rien supprimer.
do $$
declare
  c record;
begin
  for c in
    select column_name
    from information_schema.columns
    where table_schema = 'public'
      and table_name   = 'documents'
      and is_nullable  = 'NO'
      and column_default is null
      and column_name not in ('id', 'account_id', 'created_at', 'statut', 'immutable', 'needs_signature')
  loop
    execute format('alter table public.documents alter column %I drop not null', c.column_name);
  end loop;
end $$;

-- ----------------------------------------------------------------------------
-- 2) DROITS DE LECTURE (cloisonnement strict)
-- ----------------------------------------------------------------------------
alter table public.documents enable row level security;
grant select, insert, update on public.documents to authenticated;

drop policy if exists documents_admin_all          on public.documents;
drop policy if exists documents_transporter_select on public.documents;
drop policy if exists documents_own_select         on public.documents;
drop policy if exists documents_own_insert         on public.documents;
drop policy if exists documents_recipient_select   on public.documents;
drop policy if exists documents_client_select      on public.documents;

-- Admin : acces total.
create policy documents_admin_all on public.documents
  for all to authenticated
  using (public.secoto_is_admin())
  with check (public.secoto_is_admin());

-- Chacun lit et depose ses propres pieces justificatives (assurance, KBIS...).
create policy documents_own_select on public.documents
  for select to authenticated
  using (account_id = auth.uid());

create policy documents_own_insert on public.documents
  for insert to authenticated
  with check (account_id = auth.uid() and doc_type is null);

-- Destinataire d'un document EMIS (jamais un brouillon).
create policy documents_recipient_select on public.documents
  for select to authenticated
  using (
    recipient_id = auth.uid()
    and statut::text <> 'brouillon'
  );

-- Transporteur : uniquement les bons de mission EMIS de ses propres missions.
create policy documents_transporter_select on public.documents
  for select to authenticated
  using (
    doc_type = 'bon_de_mission'
    and statut::text <> 'brouillon'
    and exists (
      select 1 from public.missions m
      where m.id = documents.mission_id
        and m.assigned_transporter_id = auth.uid()
    )
  );

-- Client : uniquement les devis et factures EMIS de ses propres courses.
create policy documents_client_select on public.documents
  for select to authenticated
  using (
    doc_type in ('devis', 'facture')
    and statut::text <> 'brouillon'
    and exists (
      select 1 from public.missions m
      where m.id = documents.mission_id
        and m.client_account_id = auth.uid()
    )
  );

-- ----------------------------------------------------------------------------
-- 3) EMISSION D'UN DOCUMENT (reservee a l'admin)
-- ----------------------------------------------------------------------------
-- p_statut : 'brouillon' (prepare, invisible) ou 'envoye' (notifie au
-- destinataire). Le numero officiel est attribue atomiquement a l'emission.
create or replace function public.secoto_emit_document(
  p_mission        uuid,
  p_type           secoto_doc_type,
  p_html           text,
  p_recipient      uuid,
  p_statut         text default 'envoye',
  p_needs_signature boolean default true,
  p_ref_devis      text default null
)
returns public.documents
language plpgsql
security definer
set search_path = public
as $$
declare
  v_doc    public.documents;
  v_numero text;
begin
  if not public.secoto_is_admin() then
    raise exception 'Emission de document reservee a l''administrateur SECOTO.';
  end if;
  if p_html is null or length(p_html) < 50 then
    raise exception 'Document vide : generation annulee.';
  end if;

  -- Un seul document de chaque type par mission : on remplace le precedent
  -- s'il n'a pas encore ete signe (evite les doublons a chaque clic).
  delete from public.documents
   where mission_id = p_mission
     and doc_type   = p_type
     and coalesce(statut::text, 'brouillon') <> 'signe'
     and immutable is not true;

  v_numero := public.secoto_next_doc_number(p_type);

  insert into public.documents (
    account_id, recipient_id, mission_id, doc_type, numero, statut,
    html_snapshot, needs_signature, ref_devis, emitted_at, file_name
  )
  values (
    p_recipient, p_recipient, p_mission, p_type, v_numero, p_statut::secoto_doc_statut,
    p_html, p_needs_signature, p_ref_devis,
    case when p_statut = 'envoye' then now() else null end,
    v_numero || '.html'
  )
  returning * into v_doc;

  return v_doc;
end $$;

grant execute on function public.secoto_emit_document(uuid, secoto_doc_type, text, uuid, text, boolean, text) to authenticated;

-- ----------------------------------------------------------------------------
-- 4) MISE EN CIRCULATION D'UN BROUILLON (bon de mission apres signature client)
-- ----------------------------------------------------------------------------
create or replace function public.secoto_release_document(p_doc uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.documents
     set statut     = 'envoye'::secoto_doc_statut,
         emitted_at = coalesce(emitted_at, now())
   where id = p_doc
     and statut::text = 'brouillon';
end $$;

-- ----------------------------------------------------------------------------
-- 5) SIGNATURE ELECTRONIQUE PAR LE DESTINATAIRE
-- ----------------------------------------------------------------------------
-- p_signature : { "data_url": "...", "signer_name": "...", "signed_at": "..." }
create or replace function public.secoto_sign_document(
  p_doc       uuid,
  p_signature jsonb
)
returns public.documents
language plpgsql
security definer
set search_path = public
as $$
declare
  v_doc  public.documents;
  v_sig  jsonb;
begin
  select * into v_doc from public.documents where id = p_doc;
  if v_doc.id is null then
    raise exception 'Document introuvable.';
  end if;
  if v_doc.recipient_id is distinct from auth.uid() then
    raise exception 'Ce document ne vous est pas destine.';
  end if;
  if v_doc.statut::text = 'brouillon' then
    raise exception 'Ce document n''est pas encore disponible.';
  end if;
  if v_doc.statut::text = 'signe' then
    raise exception 'Document deja signe.';
  end if;
  if coalesce(p_signature ->> 'data_url', '') = '' then
    raise exception 'Signature manquante.';
  end if;

  v_sig := p_signature || jsonb_build_object('signed_at', now());

  update public.documents
     set signature_client       = case when doc_type = 'bon_de_mission' then signature_client       else v_sig end,
         signature_transporteur = case when doc_type = 'bon_de_mission' then v_sig                  else signature_transporteur end,
         statut                 = 'signe'::secoto_doc_statut,
         signed_at              = now()
   where id = p_doc
  returning * into v_doc;

  return v_doc;
end $$;

grant execute on function public.secoto_sign_document(uuid, jsonb) to authenticated;

-- ----------------------------------------------------------------------------
-- 6) NOTIFICATIONS AUTOMATIQUES DU CIRCUIT
-- ----------------------------------------------------------------------------

-- 6.1 A l'emission : on previent le destinataire.
create or replace function public.secoto_trg_document_emitted()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_label text;
begin
  if new.doc_type is null or new.statut::text = 'brouillon' or new.recipient_id is null then
    return new;
  end if;

  v_label := case new.doc_type::text
               when 'devis'          then 'Devis'
               when 'bon_de_mission' then 'Bon de mission'
               when 'facture'        then 'Facture'
               else 'Document'
             end;

  perform public.secoto_notify_one(
    new.recipient_id,
    'document',
    v_label || ' disponible',
    case when new.needs_signature
         then v_label || ' ' || coalesce(new.numero, '') || ' a consulter et signer dans l''application.'
         else v_label || ' ' || coalesce(new.numero, '') || ' a consulter et telecharger dans l''application.'
    end,
    new.mission_id
  );
  return new;
end $$;

drop trigger if exists trg_secoto_document_emitted on public.documents;
create trigger trg_secoto_document_emitted
  after insert on public.documents
  for each row execute function public.secoto_trg_document_emitted();

-- 6.2 Passage brouillon -> envoye : meme notification.
drop trigger if exists trg_secoto_document_released on public.documents;
create trigger trg_secoto_document_released
  after update of statut on public.documents
  for each row
  when (old.statut::text = 'brouillon' and new.statut::text = 'envoye')
  execute function public.secoto_trg_document_emitted();

-- 6.3 A la signature : enchainement automatique du circuit.
create or replace function public.secoto_trg_document_signed()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_bon    uuid;
  v_signer text;
begin
  if new.statut::text <> 'signe' or old.statut::text = 'signe' then
    return new;
  end if;

  select a.full_name into v_signer from public.accounts a where a.id = new.recipient_id;

  if new.doc_type::text = 'devis' then
    -- Le client a signe : on met le bon de mission en circulation.
    select d.id into v_bon
      from public.documents d
     where d.mission_id = new.mission_id
       and d.doc_type   = 'bon_de_mission'
       and d.statut::text = 'brouillon'
     limit 1;

    if v_bon is not null then
      perform public.secoto_release_document(v_bon);
    end if;

    perform public.secoto_notify_admins(
      'document',
      'Devis signe',
      coalesce(v_signer, 'Le client') || ' a signe le devis ' || coalesce(new.numero, '')
        || '. Le bon de mission est parti au transporteur.',
      new.mission_id
    );

  elsif new.doc_type::text = 'bon_de_mission' then
    perform public.secoto_notify_admins(
      'document',
      'Bon de mission signe',
      coalesce(v_signer, 'Le transporteur') || ' a signe le bon de mission '
        || coalesce(new.numero, '') || '.',
      new.mission_id
    );

  elsif new.doc_type::text = 'facture' then
    perform public.secoto_notify_admins(
      'document',
      'Facture acceptee',
      coalesce(v_signer, 'Le client') || ' a valide la facture ' || coalesce(new.numero, '') || '.',
      new.mission_id
    );
  end if;

  return new;
end $$;

drop trigger if exists trg_secoto_document_signed on public.documents;
create trigger trg_secoto_document_signed
  after update of statut on public.documents
  for each row execute function public.secoto_trg_document_signed();

-- ----------------------------------------------------------------------------
-- 7) TEMPS REEL sur les documents
-- ----------------------------------------------------------------------------
do $$
begin
  begin
    execute 'alter table public.documents replica identity full';
  exception when others then null;
  end;
  begin
    execute 'alter publication supabase_realtime add table public.documents';
  exception
    when duplicate_object then null;
    when undefined_object then null;
  end;
end $$;

notify pgrst, 'reload schema';
