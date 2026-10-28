// SECOTO 119 — course réglée en espèces : le transporteur voit d'abord le
// total à encaisser auprès du client, en grand, puis le détail.
import { detailEspeces } from "../lib/especes";
import { formatCents } from "../lib/onDemand";

export default function EspecesAEncaisser({ totalCents, partTransporteurCents }) {
  const d = detailEspeces(totalCents, partTransporteurCents);
  return (
    <div className="od-especes" role="note">
      <p className="od-especes-titre">💶 Course réglée en espèces</p>
      {d.total !== null ? (
        <>
          <p className="od-especes-total">
            <span>À encaisser auprès du client</span>
            <strong>{formatCents(d.total)}</strong>
          </p>
          {d.partSecoto !== null && (
            <ul className="od-especes-detail">
              <li><span>Votre part</span><strong>{formatCents(d.partTransporteur)}</strong></li>
              <li><span>Part SECOTO à reverser sous 7 jours</span><strong>{formatCents(d.partSecoto)}</strong></li>
            </ul>
          )}
          <p className="od-especes-note">Réclamez la totalité au client. Prévoyez la monnaie si besoin.</p>
        </>
      ) : (
        <p className="od-especes-note">Montant à encaisser : contactez SECOTO avant de vous déplacer.</p>
      )}
    </div>
  );
}
