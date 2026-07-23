-- ============================================================================
-- SECOTO - Patch : mode de reglement + coordonnees bancaires reelles.
-- A coller dans le SQL Editor Supabase. Idempotent, rejouable.
-- ============================================================================

-- 1) Colonne mode de reglement sur les missions ('virement' | 'especes').
alter table public.missions
  add column if not exists payment_method text not null default 'virement';

-- 2) Coordonnees bancaires reelles (Revolut) pour les factures par virement.
insert into public.app_settings (key, value)
values ('bank_details', jsonb_build_object(
  'titulaire','Nawfal Benchiha',
  'iban','FR76 2823 3000 0143 6341 8597 296',
  'bic','REVOFRP2',
  'banque','Revolut Bank UAB, 10 avenue Kleber, 75116 Paris'))
on conflict (key) do update set value = excluded.value;
