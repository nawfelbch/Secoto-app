-- SECOTO 104 — à coller dans Supabase › SQL Editor APRÈS validation (ne pas exécuter avant la mise en ligne du code).

-- ============================================================================
-- SECOTO — MIGRATION 104 : RÈGLEMENT À LA LIVRAISON SANS DOUBLE DÉBIT
-- ----------------------------------------------------------------------------
-- Après la livraison, deux chemins peuvent régler la même commande :
--   · le prélèvement automatique de la carte enregistrée (maintenance serveur) ;
--   · « Payer maintenant » lancé par le client (carte ou Klarna).
-- Le serveur mémorise le paiement ouvert par le client ; avant tout
-- prélèvement automatique, il le ferme (ou constate qu'il a abouti). Une seule
-- somme peut donc être encaissée. Aucune donnée existante n'est modifiée.
--
-- 2. Annulation d'une réservation réglée à la livraison : rien n'a été prélevé.
--    Le message au client ne parle plus de « remboursement » ni de « retenue ».
--    La règle d'annulation (et l'indemnité éventuelle du transporteur) est
--    inchangée : arbitrage signalé à SECOTO, voir le compte rendu.
-- 3. Barème : « vérifié et assuré » devient « validé par SECOTO » dans la liste
--    « compris dans le prix » des barèmes (texte seulement, aucun prix modifié).
--    Les devis déjà émis gardent leur texte d'origine.
-- ADDITIF : deux colonnes, une fonction complétée, deux messages, un libellé.
-- Rejouable.
-- ============================================================================

alter table public.payments add column if not exists reglement_client_intent_id text;
alter table public.payments add column if not exists reglement_client_session_id text;

create or replace function public.secoto_reglements_a_debiter(p_limit integer default 20)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_rows jsonb;
begin
  with dus as (
    select p.id from public.payments p
      join public.transport_orders o on o.id = p.order_id
     where p.debit_a_livraison and p.status in ('requires_capture', 'capture_failed')
       and o.status = 'delivered'
       and p.reglement_echeance is not null and p.reglement_echeance <= now()
       and p.reglement_tentatives < secoto_private.reglement_num('tentatives_carte_max', 3)
       and (p.reglement_debit_tente_at is null or p.reglement_debit_tente_at < now() - interval '15 minutes')
       and (o.mode_reglement is distinct from 'especes' or p.especes_statut = 'non_recu')
       and p.saved_payment_method_id is not null
     order by p.reglement_echeance
     limit greatest(coalesce(p_limit, 20), 1)
     for update of p skip locked
  ), pris as (
    update public.payments p set reglement_debit_tente_at = now(), updated_at = now()
      from dus where p.id = dus.id returning p.*
  )
  select coalesce(jsonb_agg(jsonb_build_object(
      'payment_id', pr.id, 'order_id', o.id, 'public_ref', o.public_ref,
      'amount_cents', pr.amount_cents, 'currency', coalesce(pr.currency, 'eur'),
      'customer_id', a.stripe_customer_id, 'payment_method_id', pr.saved_payment_method_id,
      'provider_intent_id', pr.provider_intent_id, 'tentative', pr.reglement_tentatives,
      'mode_reglement', o.mode_reglement, 'purpose', pr.purpose,
      -- 104 : paiement ouvert par le client, à fermer avant tout prélèvement.
      'client_intent_id', pr.reglement_client_intent_id,
      'client_session_id', pr.reglement_client_session_id)), '[]'::jsonb)
    into v_rows
    from pris pr join public.transport_orders o on o.id = pr.order_id
    join public.accounts a on a.id = pr.account_id;
  return v_rows;
end;
$$;
revoke all on function public.secoto_reglements_a_debiter(integer) from public, anon, authenticated;
grant execute on function public.secoto_reglements_a_debiter(integer) to service_role;

-- 2. Annulation : message exact pour un règlement à la livraison ---------------
select secoto_private.mig074_patch('public.secoto_od_cancel_order(uuid,uuid)'::regprocedure,
  $a$then format('Commande %s annulée. Annulation à moins de %s h de la prise en charge : %s %% retenus, %s € remboursés.',$a$,
  $n$then format(case when exists (select 1 from public.payments p where p.id = v_order.payment_id and p.debit_a_livraison)  -- 104
                  then 'Commande %s annulée. Rien n''avait été prélevé : aucun montant ne vous est débité.'
                  else 'Commande %s annulée. Annulation à moins de %s h de la prise en charge : %s %% retenus, %s € remboursés.' end,$n$);
select secoto_private.mig074_patch('public.secoto_od_cancel_order(uuid,uuid)'::regprocedure,
  $a$else format('Commande %s annulée. Vous êtes remboursé intégralement.', v_order.public_ref) end,$a$,
  $n$else format(case when exists (select 1 from public.payments p where p.id = v_order.payment_id and p.debit_a_livraison)  -- 104
                  then 'Commande %s annulée. Rien n''avait été prélevé : aucun montant ne vous est débité.'
                  else 'Commande %s annulée. Vous êtes remboursé intégralement.' end, v_order.public_ref) end,$n$);

-- 3. Barème : libellé factuel ---------------------------------------------------
update public.pricing_grids
   set params = replace(replace(params::text,
         'Transporteur plateau vérifié et assuré', 'Transporteur plateau validé par SECOTO'),
         'Convoyeur vérifié et assuré', 'Convoyeur validé par SECOTO')::jsonb
 where params::text like '%vérifié et assuré%';

notify pgrst, 'reload schema';

-- OPTIONNEL, après relecture juridique des CGU et conditions transporteur du 19/10/2026 :
-- faire réaccepter les nouvelles versions par tous les comptes (change la version en vigueur).
-- update public.app_settings set value = jsonb_set(value, '{version}', '"2026-10-19"') where key = 'terms_current';
