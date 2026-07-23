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
