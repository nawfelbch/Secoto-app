import { useState } from "react";
import { humanizeError } from "../lib/humanError";
import {
  choisirReglement, formatCents, isReglementArrivee, modesReglementPossibles, PLAFOND_ESPECES_EUR, reglementLivraisonTexte,
} from "../lib/onDemand";

// ============================================================================
// SECOTO 100 — Règlement à l'arrivée du véhicule.
// ----------------------------------------------------------------------------
// À la réservation : « 0 € prélevé aujourd'hui » en gros, carte enregistrée en
// garantie, choix du mode (carte, Klarna, virement, espèces). À la livraison :
// ce que le client doit faire, et le bouton « Payer maintenant ».
// ============================================================================

export function ZeroPreleve({ montantCents }) {
  return (
    <div className="od-zero" role="note">
      <strong className="od-zero-montant">0 € prélevé aujourd’hui</strong>
      <span>Vous réglez {formatCents(montantCents)} à l’arrivée du véhicule. Votre carte est seulement enregistrée, en garantie.</span>
    </div>
  );
}

export function ChoixReglement({ order, onChange, disabled = false }) {
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  if (!isReglementArrivee(order)) return null;
  const modes = modesReglementPossibles(order);
  const choix = order.mode_reglement || "carte";
  const modifiable = ["awaiting_payment", "searching_partner"].includes(order.status);

  async function choisir(cle) {
    if (cle === choix || !modifiable) return;
    setBusy(true);
    setError("");
    try {
      const r = await choisirReglement(order.id, cle);
      onChange?.(r?.order || { ...order, mode_reglement: cle });
    } catch (e) {
      setError(humanizeError(e));
    } finally {
      setBusy(false);
    }
  }

  return (
    <fieldset className="od-reglement" disabled={disabled || busy || !modifiable}>
      <legend className="od-reglement-titre">Comment souhaitez-vous régler à l’arrivée ?</legend>
      <div className="od-reglement-grille" role="radiogroup" aria-label="Mode de règlement">
        {modes.map((m) => (
          <label key={m.cle} className={`od-reglement-choix${choix === m.cle ? " is-actif" : ""}${m.cle === "klarna" ? " is-klarna" : ""}`}>
            <input type="radio" name="od-reglement" value={m.cle} checked={choix === m.cle} onChange={() => choisir(m.cle)} />
            <span className="od-reglement-nom">{m.libelle}</span>
            <span className="od-reglement-detail">{m.detail}</span>
          </label>
        ))}
      </div>
      {order.especes_possible === false && (
        <p className="muted">Espèces indisponibles : au-delà de {PLAFOND_ESPECES_EUR.toLocaleString("fr-FR")} €, la loi interdit le paiement en espèces.</p>
      )}
      {!modifiable && <p className="muted">Un transporteur a confirmé : le mode de règlement ne change plus. Besoin d’un changement ? Contactez SECOTO.</p>}
      {error && <div className="alert error" role="alert">{error}</div>}
    </fieldset>
  );
}

// Mes commandes : ce qu'il reste à faire une fois le véhicule livré.
export function ReglementLivraison({ order, busy = false, onPayer }) {
  const texte = reglementLivraisonTexte(order);
  if (!texte) return null;
  const virement = order.virement;
  return (
    <div className={`alert${order.reglement_a_payer ? "" : " success"} od-reglement-livraison`} role="status">
      <p>{texte}</p>
      {virement && (
        <dl className="od-virement">
          <div><dt>Titulaire</dt><dd>{virement.titulaire}</dd></div>
          <div><dt>IBAN</dt><dd><code>{virement.iban}</code></dd></div>
          {virement.bic && <div><dt>BIC</dt><dd><code>{virement.bic}</code></dd></div>}
          <div><dt>Référence</dt><dd><code>{virement.reference}</code></dd></div>
        </dl>
      )}
      {order.reglement_a_payer && (
        <div className="actions-row">
          <button className="btn primary small" type="button" disabled={busy} onClick={onPayer}>
            {order.mode_reglement === "klarna" ? "Payer en plusieurs fois (Klarna)" : "Payer maintenant"}
          </button>
          {virement && <small className="muted">Ou réglez par carte ou Klarna, sans attendre le virement.</small>}
        </div>
      )}
    </div>
  );
}
