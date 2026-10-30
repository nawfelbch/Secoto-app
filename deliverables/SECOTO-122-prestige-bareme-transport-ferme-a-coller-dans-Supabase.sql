-- ============================================================================
-- SECOTO — MIGRATION 122 : PRESTIGE — BARÈME DÉDIÉ, TRANSPORT FERMÉ AU CHOIX
-- ----------------------------------------------------------------------------
-- Décision de Nawfal du 30/10/2026 (Ferrari Dino 308 GT4, Paris → Aulnay-sur-
-- Mauldre, 53 km : 115 € client, envoyée à 5 transporteurs seulement).
--   1. Un véhicule « Prestige / collection » était facturé comme un véhicule
--      standard. Barème prestige (tarif transporteur, client × 1,2 inchangé) :
--        · plateau ouvert   : tarif standard × 1,5, minimum 250 € ;
--        · transport fermé  : tarif standard × 2,1, minimum 350 €.
--   2. « Prestige » imposait un camion fermé (seuls les transporteurs validés
--      « camion fermé » recevaient la course). Désormais le client coche
--      « Transport fermé souhaité » s'il le veut ; sinon la course part à tous
--      les transporteurs plateau.
-- Devis et commandes existants : rien ne change. Réglages dans
-- app_settings['bareme_transporteurs'] -> 'prestige'. ADDITIF, rejouable.
-- ============================================================================

update public.app_settings
   set value = value || jsonb_build_object('prestige', coalesce(value -> 'prestige', jsonb_build_object(
         'ouvert', jsonb_build_object('coef', 1.5, 'minimum_eur', 250),
         'ferme',  jsonb_build_object('coef', 2.1, 'minimum_eur', 350))))
 where key = 'bareme_transporteurs';

-- Transport fermé demandé par le client ?
create or replace function secoto_private.transport_ferme_demande(p_vehicle jsonb)
returns boolean language sql immutable set search_path = ''
as $f$
  select coalesce(p_vehicle -> 'constraints', '[]'::jsonb) ? 'transport_ferme';
$f$;
revoke all on function secoto_private.transport_ferme_demande(jsonb) from public, anon, authenticated;

-- Rémunération transporteur d'un véhicule de prestige (centimes).
create or replace function secoto_private.prix_prestige_cents(p_vehicle jsonb, p_pay integer)
returns integer language plpgsql stable security definer set search_path = ''
as $f$
declare
  v_cfg jsonb;
begin
  if p_pay is null or coalesce(p_vehicle ->> 'category', 'standard') <> 'luxury' then return p_pay; end if;
  v_cfg := secoto_private.bareme_transporteurs() -> 'prestige'
           -> case when secoto_private.transport_ferme_demande(p_vehicle) then 'ferme' else 'ouvert' end;
  if v_cfg is null then return p_pay; end if;
  return greatest(round(p_pay * coalesce((v_cfg ->> 'coef')::numeric, 1)),
                  round(coalesce((v_cfg ->> 'minimum_eur')::numeric, 0) * 100))::integer;
end;
$f$;
revoke all on function secoto_private.prix_prestige_cents(jsonb, integer) from public, anon, authenticated;

-- 1. Prix de marché : le barème prestige s'applique au prix transporteur retenu.
select secoto_private.mig074_patch('secoto_private.market_price(jsonb,jsonb,jsonb,numeric,timestamp with time zone,jsonb)'::regprocedure,
  'if v_pay is null then return p_price; end if;',
  'if v_pay is null then return p_price; end if;
  v_pay := secoto_private.prix_prestige_cents(p_vehicle, v_pay);  -- 122 : prestige');

-- 2. Diffusion : le camion fermé validé n'est exigé que si le client l'a demandé.
select secoto_private.mig074_patch('secoto_private.od_partner_eligible(uuid,uuid)'::regprocedure,
  'or (q.vehicle ->> ''category'' = ''luxury'' and a.luxury_closed_transport_status = ''approved'')))',
  'or (q.vehicle ->> ''category'' = ''luxury'' and (not secoto_private.transport_ferme_demande(q.vehicle) or a.luxury_closed_transport_status = ''approved''))))  -- 122');

-- 2 bis. Missions publiées (vitrine) issues d'une commande : même règle.
-- Les missions créées à la main gardent l'exigence (l'admin choisit la gamme).
select secoto_private.mig074_patch('secoto_private.transporter_matches_mission(uuid,uuid)'::regprocedure,
  'and a.luxury_closed_transport_status = ''approved''',
  'and (a.luxury_closed_transport_status = ''approved''
               or exists (select 1 from public.transport_orders o join public.transport_quotes q on q.id = o.quote_id
                           where (o.mission_id = m.id or o.id = m.od_order_id) and not secoto_private.transport_ferme_demande(q.vehicle)))  -- 122');

-- 3. Nouvelle contrainte acceptée à la création du devis.
select secoto_private.mig074_patch('public.secoto_quote_create(uuid,jsonb,jsonb)'::regprocedure,
  'if v_constraint not in (''sans_cle'', ''garde_au_sol_basse'', ''gabarit_hors_norme'', ''non_immatricule'', ''acces_difficile'', ''batterie_faible'') then',
  'if v_constraint not in (''sans_cle'', ''garde_au_sol_basse'', ''gabarit_hors_norme'', ''non_immatricule'', ''acces_difficile'', ''batterie_faible'', ''transport_ferme'') then  -- 122');

notify pgrst, 'reload schema';
