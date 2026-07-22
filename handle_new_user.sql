-- ============================================================
-- SECOTO — Trigger de création de profil à l'inscription.
-- Recopie les métadonnées d'auth.users vers public.accounts,
-- en incluant le nouveau sous-type transporteur et le type client.
-- À exécuter APRÈS supabase-migration.sql.
-- ============================================================

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.accounts (
    id, role, full_name, company_name, email, phone, city,
    transporter_type, client_type, status, is_verified, docs_count
  )
  values (
    new.id,
    coalesce(new.raw_user_meta_data->>'role', 'transporter'),
    coalesce(new.raw_user_meta_data->>'full_name', ''),
    coalesce(new.raw_user_meta_data->>'company_name', ''),
    new.email,
    coalesce(new.raw_user_meta_data->>'phone', ''),
    coalesce(new.raw_user_meta_data->>'city', ''),
    nullif(new.raw_user_meta_data->>'transporter_type', ''),
    nullif(new.raw_user_meta_data->>'client_type', ''),
    -- Les clients sont actifs immédiatement ; les transporteurs attendent la validation SECOTO.
    case when coalesce(new.raw_user_meta_data->>'role','transporter') = 'client' then 'active' else 'pending' end,
    case when coalesce(new.raw_user_meta_data->>'role','transporter') = 'client' then true else false end,
    0
  )
  on conflict (id) do update set
    role = excluded.role,
    full_name = coalesce(nullif(excluded.full_name, ''), public.accounts.full_name),
    company_name = coalesce(nullif(excluded.company_name, ''), public.accounts.company_name),
    phone = coalesce(nullif(excluded.phone, ''), public.accounts.phone),
    city = coalesce(nullif(excluded.city, ''), public.accounts.city),
    transporter_type = coalesce(excluded.transporter_type, public.accounts.transporter_type),
    client_type = coalesce(excluded.client_type, public.accounts.client_type);

  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();
