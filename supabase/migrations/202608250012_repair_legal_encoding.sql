-- SECOTO 1.3 — réparation des textes légaux saisis avec un mauvais encodage.
-- Additif et rejouable. Le fichier doit être lu en UTF-8 lors d'un copier-coller.

begin;

insert into public.app_settings (key, value)
values ('legal_texts', jsonb_build_object(
  'version', '2026-08-25',
  'commission_label', 'Réservation de votre créneau',
  'commission_notice',
    'Ce montant règle la mise en relation et bloque votre créneau auprès du '
    'transporteur. Il rémunère SECOTO et n’est pas déduit du prix du transport.',
  'transport_notice',
    'Le prix du transport est réglé directement au transporteur. Ce montant '
    'n’est pas encaissé par SECOTO.',
  'waiver_execution',
    'Je demande expressément que la prestation de mise en relation commence '
    'avant la fin du délai de rétractation.',
  'waiver_withdrawal',
    'Je reconnais qu’une fois la prestation intégralement exécutée, je perdrai '
    'mon droit de rétractation.',
  'refund_policy',
    'Après l’exécution complète de la mise en relation, les frais de réservation '
    'ne sont pas remboursables en cas d’annulation par le client. Ils sont '
    'intégralement remboursés si le transporteur se désiste.',
  'carrier_pricing_notice',
    'Vous fixez librement votre tarif. SECOTO prélève une commission de 20 % '
    'sur le montant de la mission.'
))
on conflict (key) do update set value = excluded.value;

notify pgrst, 'reload schema';

commit;
