-- 070 — Deux corrections appliquees a chaud en production le 01/10/2026,
-- versionnees ici pour que la base et le depot restent alignes.
--
-- 1. missions.price_mode avait pour valeur par defaut 'manual', qui ne figure
--    pas dans sa propre contrainte (fixed | negotiable | hidden). Toute
--    insertion de mission ne nommant pas la colonne etait rejetee : plus aucune
--    proposition ne pouvait etre acceptee, ni par un transporteur ni par un
--    administrateur, od_confirm echouant sur missions_price_mode_check.
--
-- 2. Le versement partenaire etait programme 48 h apres la livraison validee.
--    Ramene a 4 h : le partenaire est paye le jour meme, et il reste une
--    fenetre pour arbitrer un dommage constate a la livraison.

alter table public.missions alter column price_mode set default 'fixed';

update public.missions
   set price_mode = 'fixed'
 where price_mode is null
    or price_mode not in ('fixed', 'negotiable', 'hidden');

-- policy_num lit UNE seule ligne 'dispatch_policy' et y cherche la cle :
-- la fusion preserve les autres reglages, dont sous_traitance_totale_since.
insert into public.app_settings (key, value)
values ('dispatch_policy', jsonb_build_object('payout_delay_hours', 4))
on conflict (key) do update
   set value = app_settings.value || jsonb_build_object('payout_delay_hours', 4);

delete from public.app_settings where key = 'payout_delay_hours';

do $$
declare v_def text;
begin
  select column_default into v_def from information_schema.columns
   where table_schema = 'public' and table_name = 'missions' and column_name = 'price_mode';
  if coalesce(v_def, '') not like '%fixed%' then
    raise exception 'price_mode : valeur par defaut non posee (%).', v_def;
  end if;
  if exists (select 1 from public.missions m
              where m.price_mode not in ('fixed', 'negotiable', 'hidden')) then
    raise exception 'price_mode : des missions portent encore une valeur invalide.';
  end if;
  if secoto_private.policy_num('payout_delay_hours', 48) <> 4 then
    raise exception 'Delai de versement non applique (% h).',
      secoto_private.policy_num('payout_delay_hours', 48);
  end if;
  if (select value ->> 'sous_traitance_totale_since' from public.app_settings
       where key = 'dispatch_policy') is null then
    raise exception 'La politique de dispatch a perdu sous_traitance_totale_since.';
  end if;
end $$;
