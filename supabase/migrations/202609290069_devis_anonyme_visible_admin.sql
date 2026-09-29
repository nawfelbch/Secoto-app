-- 069 — Les devis manuels demandés sans compte n'apparaissaient nulle part.
--
-- secoto_admin_quotes joignait public.accounts en jointure interne pour afficher
-- le nom du client. Depuis le parcours « prix avant compte », un devis peut être
-- créé sans compte (account_id null, anon_token renseigné) : la jointure interne
-- le faisait disparaître de l'écran « Devis à établir », alors que l'admin
-- recevait bien la notification « Devis manuel à établir ».
--
-- Correction : jointure externe, et libellé explicite pour ces demandes.
-- Aucun autre écran n'est touché ; la tarification (secoto_admin_price_quote)
-- et le lien de paiement fonctionnent déjà sans compte — notify_event renvoie
-- null quand account_id est null, le client voit son prix par son lien de devis.

create or replace function public.secoto_admin_quotes(p_status text default null)
returns jsonb language plpgsql stable security definer set search_path = ''
as $f$
begin
  perform secoto_private.assert_admin();
  return coalesce((select jsonb_agg(to_jsonb(q) || jsonb_build_object(
      'client_name', coalesce(a.company_name, a.full_name,
        case when q.anon_token is not null then 'Demande sans compte' else 'Client inconnu' end),
      'client_email', a.email,
      'client_phone', a.phone,
      'client_anonyme', (q.account_id is null),
      'client_particulier', (a.client_type = 'particulier'))
    order by q.created_at desc)
    from public.transport_quotes q
    left join public.accounts a on a.id = q.account_id
    where p_status is null or q.status = p_status), '[]'::jsonb);
end;
$f$;

do $$
declare v_src text := pg_get_functiondef('public.secoto_admin_quotes(text)'::regprocedure);
begin
  if position('left join public.accounts' in v_src) = 0 then
    raise exception 'La jointure externe n''a pas ete posee.';
  end if;
  if position('Demande sans compte' in v_src) = 0 then
    raise exception 'Le libelle des demandes sans compte est absent.';
  end if;
  if not exists (
    select 1 from public.transport_quotes q
     where q.account_id is null and q.status = 'manual_review') then
    raise notice 'Aucun devis anonyme en attente : rien a verifier cote donnees.';
  end if;
end $$;
