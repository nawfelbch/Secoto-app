-- SECOTO 095 — Supprimer un devis depuis l'écran admin (et le restaurer).
-- ----------------------------------------------------------------------------
-- Demandes de test, doublons, clients injoignables : l'admin doit pouvoir les
-- retirer de ses listes. Rien n'est effacé de la base (règle absolue) :
--   * le devis passe en « cancelled » (statut existant, déjà non réservable) ;
--   * l'ancien statut, la date, l'auteur et le motif sont gardés ;
--   * les liens de paiement non payés sont révoqués : le client ne peut plus
--     payer un devis supprimé ;
--   * « Restaurer » remet le devis dans son état d'avant (expiré si sa date
--     de validité est passée ; un nouveau lien se recrée en un clic).
-- Un devis qui a déjà une commande ne se supprime pas ici : la commande se
-- gère (annulation, remboursement) dans l'onglet Commandes.
--
-- Purement additif : 4 colonnes nullable, 3 nouvelles fonctions.

alter table public.transport_quotes add column if not exists supprime_le timestamptz;
alter table public.transport_quotes add column if not exists supprime_par uuid;
alter table public.transport_quotes add column if not exists statut_avant_suppression text;
alter table public.transport_quotes add column if not exists motif_suppression text;

create or replace function public.secoto_admin_quote_supprimer(p_quote uuid, p_motif text default null)
returns jsonb language plpgsql volatile security definer set search_path = ''
as $f$
declare
  v_quote public.transport_quotes%rowtype;
  v_liens integer;
begin
  perform secoto_private.assert_admin();
  select * into v_quote from public.transport_quotes q where q.id = p_quote for update;
  if not found then raise exception 'Devis introuvable.'; end if;
  if v_quote.supprime_le is not null then
    return jsonb_build_object('id', v_quote.id, 'supprime', true, 'deja', true);
  end if;
  if v_quote.status = 'accepted'
     or exists (select 1 from public.transport_orders o where o.quote_id = p_quote) then
    raise exception 'Ce devis a déjà une commande : gérez-la dans l’onglet Commandes.';
  end if;
  if exists (select 1 from public.devis_payment_links l where l.quote_id = p_quote and l.paid_at is not null) then
    raise exception 'Ce devis a déjà été payé : il ne peut pas être supprimé.';
  end if;

  update public.transport_quotes
     set statut_avant_suppression = status,
         status = 'cancelled',
         supprime_le = now(),
         supprime_par = auth.uid(),
         motif_suppression = left(nullif(btrim(coalesce(p_motif, '')), ''), 300),
         updated_at = now()
   where id = p_quote;

  update public.devis_payment_links
     set revoked_at = now()
   where quote_id = p_quote and revoked_at is null and paid_at is null;
  get diagnostics v_liens = row_count;

  perform secoto_private.audit('quote_deleted', 'transport_quote', p_quote::text, jsonb_build_object(
    'statut_avant', v_quote.status, 'motif', p_motif, 'liens_revoques', v_liens));
  return jsonb_build_object('id', p_quote, 'supprime', true, 'liens_revoques', v_liens);
end;
$f$;

create or replace function public.secoto_admin_quote_restaurer(p_quote uuid)
returns jsonb language plpgsql volatile security definer set search_path = ''
as $f$
declare
  v_quote public.transport_quotes%rowtype;
  v_statut text;
begin
  perform secoto_private.assert_admin();
  select * into v_quote from public.transport_quotes q where q.id = p_quote for update;
  if not found then raise exception 'Devis introuvable.'; end if;
  if v_quote.supprime_le is null or v_quote.status <> 'cancelled' then
    raise exception 'Ce devis n’est pas dans les devis supprimés.';
  end if;
  v_statut := coalesce(v_quote.statut_avant_suppression, 'manual_review');
  if v_statut in ('priced', 'manual_priced')
     and (v_quote.valid_until is null or v_quote.valid_until <= now()
          or v_quote.client_price_cents is null or v_quote.partner_pay_cents is null or v_quote.collect_cents is null) then
    v_statut := 'expired';
  end if;
  if v_statut not in ('priced', 'manual_review', 'manual_priced', 'expired', 'declined', 'cancelled') then
    v_statut := 'manual_review';
  end if;

  update public.transport_quotes
     set status = v_statut,
         supprime_le = null,
         supprime_par = null,
         statut_avant_suppression = null,
         motif_suppression = null,
         updated_at = now()
   where id = p_quote;

  perform secoto_private.audit('quote_restored', 'transport_quote', p_quote::text, jsonb_build_object(
    'statut', v_statut, 'supprime_le', v_quote.supprime_le, 'motif', v_quote.motif_suppression));
  return jsonb_build_object('id', p_quote, 'status', v_statut);
end;
$f$;

-- Corbeille : les 50 derniers devis supprimés, au format de secoto_admin_quotes.
create or replace function public.secoto_admin_quotes_supprimes()
returns jsonb language plpgsql stable security definer set search_path = ''
as $f$
begin
  perform secoto_private.assert_admin();
  return coalesce((
    select jsonb_agg(t.e order by (t.e ->> 'supprime_le')::timestamptz desc)
      from (select e
              from jsonb_array_elements(public.secoto_admin_quotes('cancelled')) as x(e)
             where e ->> 'supprime_le' is not null
             order by (e ->> 'supprime_le')::timestamptz desc
             limit 50) t
  ), '[]'::jsonb);
end;
$f$;

revoke all on function public.secoto_admin_quote_supprimer(uuid, text) from public, anon;
revoke all on function public.secoto_admin_quote_restaurer(uuid) from public, anon;
revoke all on function public.secoto_admin_quotes_supprimes() from public, anon;
grant execute on function public.secoto_admin_quote_supprimer(uuid, text) to authenticated, service_role;
grant execute on function public.secoto_admin_quote_restaurer(uuid) to authenticated, service_role;
grant execute on function public.secoto_admin_quotes_supprimes() to authenticated, service_role;
