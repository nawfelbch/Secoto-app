import { decompositionPrix, formatCents } from "../lib/orderCopy";

// ============================================================================
// SECOTO 081 — Décomposition du prix (plateau en paiement direct).
// ----------------------------------------------------------------------------
// Sous le bouton, en petit et en couleur atténuée : présente avant la
// validation, sans prendre la place du prix ni du bouton. Les montants
// viennent de la base ; rien ne s'affiche s'ils sont absents (convoyage,
// ancien circuit, interrupteur éteint).
// ============================================================================

export default function DecompositionPrix({ totalCents, commissionCents }) {
  const parts = decompositionPrix(totalCents, commissionCents);
  if (!parts) return null;
  return (
    <div className="muted od-decomposition" style={{ fontSize: "0.82rem", lineHeight: 1.45, marginTop: 8, opacity: 0.85 }}>
      <div>Dont prix réservé au transporteur : {formatCents(parts.transport)}</div>
      <div>Commission de mise en relation SECOTO : {formatCents(parts.commission)}</div>
      <div>SECOTO agit en tant qu’intermédiaire ; le transport est assuré par un transporteur indépendant.</div>
    </div>
  );
}
