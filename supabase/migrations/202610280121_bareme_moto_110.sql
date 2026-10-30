-- ============================================================================
-- SECOTO — MIGRATION 121 : BARÈME MOTO — 1,10 €/KM, MINIMUM 150 € (TRANSPORTEUR)
-- ----------------------------------------------------------------------------
-- Décision de Nawfal du 28/10/2026 : à 0,85 €/km (minimum 95,83 €), les motos ne
-- trouvent pas de transporteur (Lauris → Saint-Tropez, 163 km, 138,64 € :
-- 40 offres, 3 vues, aucun preneur). Nouveau tarif transporteur par défaut :
-- 1,10 €/km, minimum 150 €. Prix client = transporteur × 1,2 (inchangé).
-- Inchangés : supplément non roulant, dégressif au-delà de 400 km (117),
-- plafond 382 € Île-de-France ↔ 06 / 83 / 13 (117).
--
-- Le prix d'un trajet suit les tarifs enregistrés par les transporteurs
-- (085) : 12 avaient validé l'ancien tarif par défaut et 4 avaient fixé un
-- tarif plus bas (0,95 à 1,00 €/km, minimum ~95 €), qui aurait tiré le prix
-- à 1,00 €/km. Le nouveau tarif devient un plancher : aucun tarif moto
-- enregistré sous 1,10 €/km ou sous 150 € de minimum (les tarifs plus hauts
-- ne bougent pas). Devis et commandes existants : rien ne change.
-- ADDITIF, rejouable.
-- ============================================================================

update public.app_settings
   set value = jsonb_set(jsonb_set(value, '{defaults,moto,eur_per_km}', '1.10'::jsonb), '{defaults,moto,minimum_eur}', '150'::jsonb)
 where key = 'bareme_transporteurs';

update public.carrier_rates
   set eur_per_km = greatest(eur_per_km, 1.10), minimum_eur = greatest(minimum_eur, 150), updated_at = now()
 where vehicle_class = 'moto' and (eur_per_km < 1.10 or minimum_eur < 150);

notify pgrst, 'reload schema';
