import { useCallback, useEffect, useState } from "react";
import { humanizeError } from "../lib/humanError";
import { formatCents, myOrders } from "../lib/onDemand";
import { acceptPaymentWaiver, fetchPayment, payNow, watchPayment } from "../lib/payments";

// ============================================================================
// SECOTO — course reservee mais pas encore reglee.
// ----------------------------------------------------------------------------
// Un client qui vient de creer son compte a deja choisi son trajet et vu son
// prix. S'il doit ensuite retrouver sa course dans « Mes commandes » pour la
// payer, il abandonne : trop d'etapes pour quelqu'un qui pensait avoir fini.
//
// Ce bandeau le suit sur tous ses ecrans tant que le paiement n'est pas fait,
// et n'offre qu'une seule action : payer. Il disparait des l'encaissement.
// ============================================================================

export default function PaiementAFinaliser({ onPaid }) {
  const [commande, setCommande] = useState(null);
  const [paiement, setPaiement] = useState(null);
  const [renonciation, setRenonciation] = useState(false); // jamais pré-cochée
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");

  const charger = useCallback(async () => {
    try {
      const commandes = await myOrders();
      const aRegler = (commandes || []).find(
        (o) => o.funding === "card"
          && o.payment_id
          && ["awaiting_payment"].includes(o.status),
      );
      setCommande(aRegler || null);
      setPaiement(aRegler ? await fetchPayment(aRegler.payment_id) : null);
    } catch {
      // Un bandeau de confort ne doit jamais casser l'écran qui le porte.
      setCommande(null);
    }
  }, []);

  useEffect(() => { charger(); }, [charger]);

  useEffect(() => {
    if (!paiement?.id) return undefined;
    const stop = watchPayment(paiement.id, (row) => {
      if (!row) return;
      setPaiement(row);
      if (["paid", "requires_capture"].includes(row.status)) {
        setCommande(null);
        onPaid?.();
      }
    });
    return () => stop?.();
  }, [paiement?.id, onPaid]);

  if (!commande || !paiement) return null;
  if (["paid", "requires_capture"].includes(paiement.status)) return null;

  const montant = formatCents(commande.client_price_cents ?? commande.collect_cents);
  const renonciationRequise = paiement.waiverRequired && !paiement.waiverAccepted;

  async function payer() {
    setBusy(true);
    setError("");
    try {
      if (renonciationRequise) {
        if (!renonciation) {
          setError("Cochez la case pour lancer le transport avant la fin du délai de rétractation.");
          return;
        }
        await acceptPaymentWaiver(paiement.id);
      }
      await payNow(paiement.id);
      await charger();
    } catch (e) {
      setError(humanizeError(e, "Le paiement n’a pas pu être lancé. Réessayez dans un instant."));
    } finally {
      setBusy(false);
    }
  }

  return (
    <div className="panel panel-full" style={{ borderColor: "var(--accent, #e8622a)", marginBottom: 14 }}>
      <h2 style={{ marginTop: 0 }}>Votre transport est réservé — il ne reste qu’à régler</h2>
      <p className="muted" style={{ marginTop: 0 }}>
        {commande.pickup?.city || "Départ"} → {commande.delivery?.city || "Arrivée"}
        {commande.vehicle?.model ? ` · ${commande.vehicle.model}` : ""}
        {commande.public_ref ? ` · commande ${commande.public_ref}` : ""}
      </p>
      {renonciationRequise && (
        <label className="payment-waiver-row">
          <input type="checkbox" checked={renonciation} onChange={(e) => setRenonciation(e.target.checked)} />
          <span>Je demande l’exécution immédiate du transport et renonce expressément à mon droit de rétractation de 14 jours.</span>
        </label>
      )}
      {error && <div className="alert error">{error}</div>}
      <button
        className="btn primary field-full"
        type="button"
        disabled={busy}
        onClick={payer}
        style={{ minHeight: 56, fontSize: "1.02rem" }}
      >
        {busy ? "Ouverture du paiement…" : `Payer ${montant}`}
      </button>
      <p className="muted" style={{ marginTop: 10 }}>
        Le montant est gardé en réserve 48 h, le temps qu’un transporteur accepte.
        Si aucun ne se rend disponible, vous êtes intégralement remboursé.
      </p>
    </div>
  );
}
