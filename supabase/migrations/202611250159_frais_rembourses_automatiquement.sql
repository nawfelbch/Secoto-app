-- ============================================================================
-- SECOTO 159 — Frais de convoyage (carburant, péages) remboursés automatiquement
-- ----------------------------------------------------------------------------
-- Demande de Nawfal du 25/11/2026 (cas réel : MIS-2026-8DE3801D, 49,40 €).
-- Depuis la 158, carburant et péages sont à la charge de SECOTO, mais un frais
-- validé dans Admin → Frais n'était versé nulle part : il fallait un virement
-- à la main. Désormais, dès qu'un frais de CONVOYAGE est validé :
--   · si le versement de la mission n'est pas encore parti (statut 'to_pay'),
--     le montant du frais lui est AJOUTÉ (un seul transfert Stripe) ;
--   · s'il est déjà parti (ou en cours), un petit versement séparé
--     (kind 'frais', échéance immédiate) est créé ; od-maintenance l'envoie
--     par Stripe Connect dans la minute, comme tout versement ;
--   · paiement direct (074) ou mission sans versement : rien d'automatique,
--     l'admin est prévenu (virement à la main).
-- Un frais validé AVANT la création du versement (livraison) y est ajouté
-- au moment où le versement est créé.
-- Garde-fous : un frais n'est versé qu'une fois (frais.payout_id) ; un
-- versement 'processing' n'est jamais modifié (on crée un versement séparé) ;
-- le transporteur du frais doit être celui du versement.
-- Rattrapage : seuls les frais validés depuis le 23/11/2026 (158) sont repris.
-- Migration ADDITIVE et rejouable.
-- ============================================================================

alter table public.partner_payouts add column if not exists frais_cents integer not null default 0;
alter table public.frais add column if not exists payout_id uuid references public.partner_payouts(id);

alter table public.partner_payouts drop constraint if exists partner_payouts_kind_check;
alter table public.partner_payouts add constraint partner_payouts_kind_check
  check (kind = any (array['mission', 'late_cancel', 'frais']));

-- Rattache UN frais validé au bon versement. Renvoie ce qui a été fait.
create or replace function secoto_private.frais_vers_versement(p_frais_id uuid)
returns text language plpgsql security definer set search_path = '' as $$
declare
  f public.frais%rowtype;
  m public.missions%rowtype;
  p public.partner_payouts%rowtype;
  v_cents integer;
  v_nouveau uuid;
begin
  select * into f from public.frais where id = p_frais_id for update;
  if not found or f.statut::text <> 'valide' or f.payout_id is not null then return 'ignore'; end if;
  v_cents := round(coalesce(f.montant, 0) * 100)::int;
  if v_cents <= 0 then return 'montant_nul'; end if;

  select * into m from public.missions where id = f.mission_id;
  if not found or m.type <> 'convoyage' then return 'pas_un_convoyage'; end if;

  -- Versement de la mission (mission_id, sinon commande liée à la mission).
  select pp.* into p from public.partner_payouts pp
   where pp.kind = 'mission' and pp.partner_id = f.transporter_id
     and (pp.mission_id = m.id
          or pp.order_id in (select o.id from public.transport_orders o where o.mission_id = m.id))
   order by pp.created_at desc limit 1
   for update;

  if not found then
    -- Mission livrée mais versement pas encore créé : le déclencheur
    -- trg_payout_frais l'ajoutera à la création. Sinon, l'admin règle à la main.
    return 'en_attente_du_versement';
  end if;

  if p.payment_circuit = 'direct' then
    perform secoto_private.notify_admins_event('payment', 'Frais à rembourser à la main',
      format('%s : %s € de frais validés, mission en paiement direct : virement manuel au transporteur.',
        coalesce(m.public_ref, m.id::text), replace(to_char(v_cents / 100.0, 'FM999990D00'), '.', ',')),
      'paiement', 'frais-manuel:' || f.id::text, p.id);
    return 'paiement_direct_manuel';
  end if;

  if p.status = 'to_pay' then
    update public.partner_payouts
       set amount_cents = amount_cents + v_cents, frais_cents = frais_cents + v_cents
     where id = p.id;
    update public.frais set payout_id = p.id where id = f.id;
    perform secoto_private.audit('frais_ajoute_au_versement', 'partner_payout', p.id::text,
      jsonb_build_object('frais_id', f.id, 'frais_cents', v_cents, 'mission', m.public_ref));
    return 'ajoute_au_versement';
  end if;

  if p.status in ('paid', 'processing', 'failed') then
    insert into public.partner_payouts(order_id, mission_id, partner_id, amount_cents, frais_cents,
                                       status, due_at, kind, reference)
    values (p.order_id, null, f.transporter_id, v_cents, v_cents, 'to_pay', now(), 'frais',
            left('Frais carburant / péages ' || coalesce(m.public_ref, ''), 120))
    returning id into v_nouveau;
    update public.frais set payout_id = v_nouveau where id = f.id;
    perform secoto_private.audit('frais_versement_separe', 'partner_payout', v_nouveau::text,
      jsonb_build_object('frais_id', f.id, 'frais_cents', v_cents, 'mission', m.public_ref));
    return 'versement_separe';
  end if;

  return 'versement_annule';  -- 'cancelled' : rien d'automatique.
end;
$$;
revoke all on function secoto_private.frais_vers_versement(uuid) from public, anon, authenticated;

-- 1. Frais validé -> versement.
create or replace function secoto_private.trg_frais_valide()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.statut::text = 'valide' and new.payout_id is null
     and (tg_op = 'INSERT' or old.statut::text is distinct from 'valide') then
    perform secoto_private.frais_vers_versement(new.id);
  end if;
  return null;
end;
$$;
create or replace trigger trg_frais_valide
  after insert or update of statut on public.frais
  for each row execute function secoto_private.trg_frais_valide();

-- 2. Versement de mission créé -> frais déjà validés de cette mission ajoutés.
create or replace function secoto_private.trg_payout_frais()
returns trigger language plpgsql security definer set search_path = '' as $$
declare r record;
begin
  if new.kind = 'mission' then
    for r in
      select f.id from public.frais f
       where f.statut::text = 'valide' and f.payout_id is null and f.transporter_id = new.partner_id
         and (f.mission_id = new.mission_id
              or f.mission_id in (select o.mission_id from public.transport_orders o where o.id = new.order_id))
    loop
      perform secoto_private.frais_vers_versement(r.id);
    end loop;
  end if;
  return null;
end;
$$;
create or replace trigger trg_payout_frais
  after insert on public.partner_payouts
  for each row execute function secoto_private.trg_payout_frais();

-- 3. Rattrapage : frais validés depuis la 158 et pas encore versés.
select f.id, secoto_private.frais_vers_versement(f.id) as resultat
  from public.frais f
 where f.statut::text = 'valide' and f.payout_id is null and f.validated_at >= '2026-11-23';

notify pgrst, 'reload schema';
