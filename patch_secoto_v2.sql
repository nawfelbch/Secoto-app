-- ============================================================================
-- SECOTO - Patch v2 (a coller dans le SQL Editor Supabase, une fois).
-- Idempotent et rejouable. Regroupe tout ce qui est nouveau :
--   1) mode de reglement sur les missions
--   2) coordonnees bancaires reelles (factures par virement)
--   3) coordonnees de contact support (section Contact de l'app)
-- (Le bug "assigned_transporter_id / mission_requests" est corrige cote CODE,
--  aucune action SQL necessaire pour lui.)
-- ============================================================================

-- 1) Mode de reglement choisi a la creation ('virement' | 'especes').
alter table public.missions
  add column if not exists payment_method text not null default 'virement';

-- 2) Coordonnees bancaires (Revolut) pour les factures par virement.
insert into public.app_settings (key, value)
values ('bank_details', jsonb_build_object(
  'titulaire','Nawfal Benchiha',
  'iban','FR76 2823 3000 0143 6341 8597 296',
  'bic','REVOFRP2',
  'banque','Revolut Bank UAB, 10 avenue Kleber, 75116 Paris'))
on conflict (key) do update set value = excluded.value;

-- 3) Coordonnees de contact affichees dans la section "Contact SECOTO".
--    Modifiables ici a tout moment sans redeployer l'app.
insert into public.app_settings (key, value)
values ('support_contact', jsonb_build_object(
  'phone','07 83 27 82 31',
  'phone_e164','+33783278231',
  'email','contact.secoto@gmail.com',
  'whatsapp','33783278231',
  'hours','7j/7'))
on conflict (key) do update set value = excluded.value;

-- 4) SUPPRESSION DE COMPTE EN UN CLIC (exigence Apple, section 10).
--    Fonction appelable par l'utilisateur connecte : supprime ses donnees
--    personnelles puis son compte d'authentification. SECURITY DEFINER pour
--    pouvoir nettoyer toutes les tables et supprimer de auth.users.
--    Chaque nettoyage est tolerant (ignore une table absente).
create or replace function public.secoto_delete_account()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid := auth.uid();
begin
  if uid is null then
    raise exception 'Utilisateur non authentifie.';
  end if;

  -- Detacher les missions (on garde l'historique des courses cote SECOTO).
  begin update public.missions set assigned_transporter_id = null, assigned_transporter_name = null where assigned_transporter_id = uid; exception when others then null; end;
  begin update public.missions set client_account_id = null where client_account_id = uid; exception when others then null; end;

  -- Supprimer les donnees personnelles rattachees au compte.
  begin delete from public.frais where transporter_id = uid; exception when others then null; end;
  begin delete from public.push_subscriptions where account_id = uid; exception when others then null; end;
  begin delete from public.notifications where account_id = uid; exception when others then null; end;
  begin delete from public.documents where account_id = uid; exception when others then null; end;
  begin delete from public.mission_applications where transporter_id = uid; exception when others then null; end;
  begin delete from public.mission_tracking_photos where transporter_id = uid; exception when others then null; end;
  begin delete from public.mission_tracking_events where transporter_id = uid; exception when others then null; end;
  begin delete from public.mission_requests where requester_id = uid; exception when others then null; end;

  -- Supprimer le profil puis le compte d'authentification (suppression reelle).
  begin delete from public.accounts where id = uid; exception when others then null; end;
  delete from auth.users where id = uid;
end;
$$;

grant execute on function public.secoto_delete_account() to authenticated;
