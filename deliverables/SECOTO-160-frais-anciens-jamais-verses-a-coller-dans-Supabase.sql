-- ============================================================================
-- SECOTO 160 — Les anciens frais (et ceux des missions de test) ne sont jamais
-- versés automatiquement
-- ----------------------------------------------------------------------------
-- Demande de Nawfal du 25/11/2026 : les deux frais de TEST de juillet
-- (MIS-2026-9818 : essence 50 €, péage 10 €, validés le 23/07/2026) ne doivent
-- jamais être versés. La 159 ne les reprenait pas (rattrapage limité aux frais
-- validés depuis le 23/11), mais ils pouvaient encore être rattachés si un
-- versement était un jour créé pour cette mission (trg_payout_frais).
-- Règle : frais_vers_versement ignore désormais tout frais validé avant le
-- 23/11/2026 (avant la règle 158) et tout frais d'une mission is_test.
-- Aucune donnée n'est modifiée. Migration rejouable.
-- ============================================================================

do $$
begin
  if position('avant_158_ou_test' in pg_get_functiondef('secoto_private.frais_vers_versement(uuid)'::regprocedure)) = 0 then
    perform secoto_private.mig074_patch(
      'secoto_private.frais_vers_versement(uuid)'::regprocedure,
      $a$  if not found or m.type <> 'convoyage' then return 'pas_un_convoyage'; end if;$a$,
      $b$  if not found or m.type <> 'convoyage' then return 'pas_un_convoyage'; end if;
  -- 160 : frais d'avant la règle 158, ou mission de test -> jamais versés automatiquement.
  if f.validated_at < '2026-11-23' or coalesce(m.is_test, false) then return 'avant_158_ou_test'; end if;$b$);
  end if;
end $$;

-- Contrôle : les frais de test de juillet restent non versés.
select f.montant, f.statut, f.payout_id, secoto_private.frais_vers_versement(f.id) as resultat
  from public.frais f
 where f.validated_at < '2026-11-23';
