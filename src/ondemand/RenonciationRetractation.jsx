// ============================================================================
// SECOTO — demande d'exécution avant la fin du délai de rétractation.
// ----------------------------------------------------------------------------
// Case jamais pré-cochée, recueillie AVANT le début du transport (exigence
// légale pour un service commencé dans les 14 jours). Le texte dit pourquoi on
// la demande et ce qui protège le client, au lieu de ne parler que de ce qu'il
// « perd » : les clients s'en inquiétaient au moment de réserver.
// Aucune date précise n'est promise : la date indiquée reste une date souhaitée.
// L'explication est repliée pour ne pas encombrer l'écran (téléphone compris).
// ============================================================================

export default function RenonciationRetractation({ checked, onChange, arrivee = false }) {
  return (
    <div className="payment-waiver">
      <label className="payment-waiver-row">
        <input type="checkbox" checked={checked} onChange={(e) => onChange(e.target.checked)} />
        <span>Je demande que SECOTO organise mon transport dès maintenant, sans attendre la fin du délai légal de rétractation de 14 jours.</span>
      </label>
      <details className="payment-waiver-why">
        <summary>Pourquoi cette case ?</summary>
        <p>
          Sans cet accord, la loi nous obligerait à attendre 14 jours avant d’organiser votre transport.
          La date indiquée est une date souhaitée, confirmée ensuite avec le transporteur.
          {arrivee && " Rien n’est prélevé aujourd’hui : vous ne payez qu’à l’arrivée du véhicule, et vous pouvez annuler sans frais avant sa prise en charge."}
        </p>
      </details>
    </div>
  );
}
