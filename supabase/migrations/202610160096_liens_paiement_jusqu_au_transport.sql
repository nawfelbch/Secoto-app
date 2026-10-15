-- SECOTO 096 — Le lien de paiement reste valable jusqu'au jour du transport.
-- ----------------------------------------------------------------------------
-- Constat du 16/10/2026 : un lien envoyé par SMS mourait en même temps que le
-- devis, soit 24 h après la demande (fin de validité du prix automatique).
-- Un prospect qui rouvre son SMS le lendemain tombait sur « Lien invalide »,
-- alors que l'écran admin annonce « valable 30 jours ».
--
-- Désormais : le lien vit jusqu'à la date de prise en charge, 30 jours au
-- plus. À l'ouverture, 093 réactive le devis au prix du lien (prix honoré).
-- Une date de prise en charge passée reste refusée (« date dépassée »).
--
-- Liens déjà envoyés : leur durée est ALLONGÉE de la même façon (jamais
-- raccourcie), sauf liens révoqués, payés ou devis supprimés. Les SMS déjà
-- reçus par les prospects refonctionnent, sans renvoyer de nouveau lien.
--
-- Additif : un repère remplacé dans une fonction, une prolongation de dates.
-- Rien n'est supprimé, aucune policy touchée. Rejouable.

select secoto_private.mig074_patch(
  'public.secoto_admin_devis_link_quote(uuid,integer)'::regprocedure,
  'coalesce(v_quote.valid_until, now() + interval ''30 days'')',
  '/* 096 */ coalesce(greatest(v_quote.pickup_at, v_quote.valid_until), now() + interval ''30 days'')');

update public.devis_payment_links l
   set expires_at = least(l.created_at + interval '30 days', q.pickup_at)
  from public.transport_quotes q
 where q.id = l.quote_id
   and l.revoked_at is null
   and l.paid_at is null
   and q.supprime_le is null
   and q.status in ('priced', 'manual_priced', 'expired')
   and q.pickup_at > now()
   and l.expires_at < least(l.created_at + interval '30 days', q.pickup_at);
