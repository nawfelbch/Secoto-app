-- ============================================================================
-- SECOTO 080 — Envoi de fichiers : règle « dossiers entreprise » sans blocage
-- ----------------------------------------------------------------------------
-- La règle d'envoi `secoto_business_private_insert` (migration 031) lisait
-- directement la table eligibility_applications, que les utilisateurs connectés
-- n'ont pas le droit de lire (revoke de la 031). Postgres vérifie ce droit pour
-- TOUT envoi dans le stockage, quel que soit le dossier visé : chaque envoi de
-- photo d'état des lieux était refusé (« permission denied for table
-- eligibility_applications », renvoyé en erreur 400 par Supabase).
--
-- Correctif : la même vérification, à l'identique, passe par une fonction
-- SECURITY DEFINER. Aucune règle n'est élargie : seul un membre de
-- l'entreprise peut déposer, et seulement dans un dossier encore modifiable.
-- Migration rejouable.
-- ============================================================================

create or replace function secoto_private.can_upload_business_file(p_business text, p_application text)
returns boolean language sql stable security definer set search_path = ''
as $f$
  -- Chemin non conforme (autre dossier) : refus simple, jamais d'erreur de
  -- conversion qui bloquerait les autres envois.
  select coalesce(
    p_business ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
    and secoto_private.is_business_member(p_business::uuid, auth.uid())
    and exists (select 1 from public.eligibility_applications ea
                 where ea.id::text = p_application
                   and ea.business_id::text = p_business
                   and ea.status in ('draft', 'needs_correction')),
    false);
$f$;
revoke all on function secoto_private.can_upload_business_file(text, text) from public, anon;
grant execute on function secoto_private.can_upload_business_file(text, text) to authenticated;

drop policy if exists secoto_business_private_insert on storage.objects;
create policy secoto_business_private_insert on storage.objects for insert to authenticated
with check (bucket_id = 'business-private'
  and secoto_private.can_upload_business_file((storage.foldername(name))[1], (storage.foldername(name))[2]));

notify pgrst, 'reload schema';
