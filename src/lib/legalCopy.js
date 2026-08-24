export const LEGAL_COPY_VERSION = "2026-08-24";

export const LEGAL_COPY = Object.freeze({
  version: LEGAL_COPY_VERSION,
  commission_label: "Réservation de votre créneau",
  commission_notice:
    "Ce montant règle la mise en relation et bloque votre créneau auprès du "
    + "transporteur. Il rémunère SECOTO et n’est pas déduit du prix du transport.",
  transport_notice:
    "Le prix du transport est réglé directement au transporteur. Ce montant "
    + "n’est pas encaissé par SECOTO.",
  waiver_execution:
    "Je demande expressément que la prestation de mise en relation commence "
    + "avant la fin du délai de rétractation.",
  waiver_withdrawal:
    "Je reconnais qu’une fois la prestation intégralement exécutée, je perdrai "
    + "mon droit de rétractation.",
  refund_policy:
    "Après l’exécution complète de la mise en relation, les frais de réservation "
    + "ne sont pas remboursables en cas d’annulation par le client. Ils sont "
    + "intégralement remboursés si le transporteur se désiste.",
});

export function currentLegalCopy(remoteValue) {
  if (String(remoteValue?.version || "") < LEGAL_COPY_VERSION) return LEGAL_COPY;
  return { ...LEGAL_COPY, ...remoteValue };
}
