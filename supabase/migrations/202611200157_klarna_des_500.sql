-- ============================================================================
-- SECOTO 157 — Klarna seulement à partir de 500 € (décision de Nawfal, 20/11/2026)
-- ----------------------------------------------------------------------------
-- Contrôle de rentabilité du 20/11 (298 offres) : les 5 % de frais Klarna font
-- tomber le net SECOTO à 37–47 € sur les petits trajets (prix < 500 €).
-- En dessous de 500 € : carte, virement ou espèces seulement. Aucun prix modifié.
-- Les commandes déjà en Klarna ne changent pas (aucune sous 500 € au 20/11).
-- Seuil : app_settings['klarna'].min_cents. Rejouable.
-- ============================================================================
insert into public.app_settings(key, value)
values ('klarna', jsonb_build_object('min_cents', 50000))
on conflict (key) do nothing;

select secoto_private.mig074_patch(
  'public.secoto_od_choisir_reglement(uuid,text)'::regprocedure,
  $a$  -- 143 : Klarna est réservé aux particuliers (interdit en B2B).$a$,
  $b$  -- 157 : Klarna seulement à partir de 500 € (réglage app_settings['klarna']).
  if p_mode = 'klarna' and exists (select 1 from public.transport_orders o
                                    where o.id = p_order_id
                                      and coalesce(o.client_price_cents, o.collect_cents, 0)
                                          < coalesce((select (value ->> 'min_cents')::int from public.app_settings where key = 'klarna'), 50000)) then
    raise exception 'Klarna est disponible à partir de 500 €. Choisissez la carte, le virement ou les espèces.';
  end if;
  -- 143 : Klarna est réservé aux particuliers (interdit en B2B).$b$);

notify pgrst, 'reload schema';
