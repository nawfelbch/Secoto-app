-- ============================================================================
-- SECOTO 153 — Remise de Noël (1er → 31 décembre 2026, heure de Paris)
-- ----------------------------------------------------------------------------
-- Décision du 19/11/2026 : une VRAIE remise, jamais de prix gonflé puis barré
-- (art. L112-1-1 et L121-2 du Code de la consommation).
--   · 5 % du prix de l'offre, plafonnés à 40 €, arrondis à l'euro inférieur ;
--   · prise UNIQUEMENT sur la commission SECOTO : la rémunération du
--     transporteur ne change jamais ;
--   · la commission ne descend jamais sous 75 € (sinon remise réduite ou nulle) ;
--   · nouveaux devis seulement : un devis déjà calculé, une offre déjà choisie
--     ou une commande existante ne changent pas de prix.
-- S'applique aux offres plateau de l'app (Express, Standard, Éco, Navette Pro).
-- Réglages app_settings['promo_noel'] ; « actif » à false coupe tout.
-- Migration ADDITIVE et rejouable.
-- ============================================================================

insert into public.app_settings(key, value)
values ('promo_noel', jsonb_build_object(
  'actif', true, 'debut', '2026-12-01', 'fin', '2027-01-01',
  'pct', 5, 'plafond_cents', 4000, 'commission_min_cents', 7500, 'libelle', 'Remise de Noël'))
on conflict (key) do nothing;

-- Réglages de la promo si elle est en cours (heure de Paris), sinon null.
create or replace function secoto_private.promo_noel_en_cours()
returns jsonb language sql stable security definer set search_path = '' as $$
  select s.value from public.app_settings s
   where s.key = 'promo_noel'
     and coalesce((s.value ->> 'actif')::boolean, false)
     and (now() at time zone 'Europe/Paris')::date >= (s.value ->> 'debut')::date
     and (now() at time zone 'Europe/Paris')::date <  (s.value ->> 'fin')::date;
$$;
revoke all on function secoto_private.promo_noel_en_cours() from public, anon, authenticated;

-- Applique la remise à chaque offre. Sans promo en cours : offres inchangées.
create or replace function secoto_private.appliquer_promo_noel(p_offres jsonb)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  s jsonb := secoto_private.promo_noel_en_cours();
  o jsonb;
  v_client integer;
  v_pay integer;
  v_remise integer;
  v_out jsonb := '[]'::jsonb;
begin
  if s is null or p_offres is null or jsonb_typeof(p_offres) <> 'array' then return p_offres; end if;
  for o in select e from jsonb_array_elements(p_offres) e loop
    v_client := (o ->> 'client_cents')::int;
    v_pay := (o ->> 'partenaire_cents')::int;
    if o ? 'remise_cents' or v_client is null or v_pay is null then
      v_out := v_out || jsonb_build_array(o);
      continue;
    end if;
    v_remise := least(floor(v_client * coalesce((s ->> 'pct')::numeric, 5) / 100)::int,
                      coalesce((s ->> 'plafond_cents')::int, 4000),
                      v_client - v_pay - coalesce((s ->> 'commission_min_cents')::int, 7500));
    v_remise := (greatest(v_remise, 0) / 100) * 100;   -- euros entiers
    if v_remise >= 100 then
      o := o || jsonb_build_object(
        'client_avant_remise_cents', v_client,
        'remise_cents', v_remise,
        'remise_libelle', coalesce(s ->> 'libelle', 'Remise de Noël'),
        'client_cents', v_client - v_remise,
        'commission_cents', v_client - v_remise - v_pay);
    end if;
    v_out := v_out || jsonb_build_array(o);
  end loop;
  return v_out;
end;
$$;
revoke all on function secoto_private.appliquer_promo_noel(jsonb) from public, anon, authenticated;

-- Branchement : à chaque calcul des offres d'un devis.
select secoto_private.mig074_patch(
  'secoto_private.trg_quote_offres()'::regprocedure,
  $a$      new.offres := secoto_private.calculer_offres(new);$a$,
  $b$      new.offres := secoto_private.appliquer_promo_noel(secoto_private.calculer_offres(new));  -- 153$b$);

-- Ligne du devis / de la facture : la remise est écrite en clair.
select secoto_private.mig074_patch(
  'public.secoto_od_book_offre(uuid, text, uuid)'::regprocedure,
  $a$             'label', format('Transport sur plateau · offre %s', v_offre ->> 'libelle'),$a$,
  $b$             'label', format('Transport sur plateau · offre %s', v_offre ->> 'libelle')
                       || case when (v_offre ->> 'remise_cents')::int > 0
                               then format(' (%s : -%s € inclus)', v_offre ->> 'remise_libelle', ((v_offre ->> 'remise_cents')::int / 100))
                               else '' end,  -- 153$b$);

-- Bandeau du site et de l'app : conditions publiques de la promo en cours.
create or replace function public.secoto_promo_publique()
returns jsonb language sql stable security definer set search_path = '' as $$
  select case when s is null then jsonb_build_object('actif', false)
    else jsonb_build_object('actif', true, 'libelle', s ->> 'libelle', 'pct', (s ->> 'pct')::numeric,
                            'plafond_eur', (s ->> 'plafond_cents')::int / 100,
                            'fin', ((s ->> 'fin')::date - 1)) end
    from (select secoto_private.promo_noel_en_cours() as s) x;
$$;
revoke all on function public.secoto_promo_publique() from public;
grant execute on function public.secoto_promo_publique() to anon, authenticated;

notify pgrst, 'reload schema';
