-- SECOTO 094 — Écran « Devis à établir » : ne charger que les devis utiles.
-- ----------------------------------------------------------------------------
-- L'écran admin chargeait tout l'historique des devis à chaque ouverture.
-- Il n'affiche pourtant que deux choses : les devis à établir et les devis
-- tarifés encore valides. Cette fonction renvoie exactement ces devis, au
-- même format que secoto_admin_quotes (qu'elle réutilise : aucune copie de
-- logique, aucune dérive possible).
--
-- Purement additif : nouvelle fonction, rien n'est modifié ni supprimé.
-- L'application retombe sur secoto_admin_quotes si cette fonction n'existe pas.

create or replace function public.secoto_admin_quotes_actifs()
returns jsonb language plpgsql stable security definer set search_path = ''
as $f$
begin
  perform secoto_private.assert_admin();
  return coalesce((
    select jsonb_agg(t.e order by t.n)
      from jsonb_array_elements(public.secoto_admin_quotes(null)) with ordinality as t(e, n)
     where t.e ->> 'status' in ('manual_review', 'manual_priced')
        or (t.e ->> 'status' = 'priced'
            and (t.e ->> 'valid_until' is null or (t.e ->> 'valid_until')::timestamptz > now()))
  ), '[]'::jsonb);
end;
$f$;

revoke all on function public.secoto_admin_quotes_actifs() from public, anon;
grant execute on function public.secoto_admin_quotes_actifs() to authenticated, service_role;
