import { useCallback, useEffect, useState } from "react";
import { supabase } from "./supabaseClient";
import {
  acceptPaymentWaiver,
  fetchPayment,
  payNow,
  prepareCommissionPayment,
  watchPayment,
} from "./lib/payments";
import { formatAmount } from "./lib/pricing";
import { currentLegalCopy, LEGAL_COPY } from "./lib/legalCopy";

// ============================================================================
// SECOTO — Écran de paiement PLATEAU / MOTO (« Réservation de votre créneau »).
// ----------------------------------------------------------------------------
// SECOTO est ici INTERMÉDIAIRE. Deux lignes distinctes, jamais fusionnées :
//   1. les frais de réservation SECOTO (20 %), seul montant encaissé ici ;
//   2. le prix du transport, réglé DIRECTEMENT au transporteur, jamais encaissé
//      par SECOTO et jamais déduit de la commission.
//
// La case de renonciation est TOUJOURS décochée à l'ouverture, et porte DEUX
// mentions distinctes : demande expresse d'exécution immédiate, et renonciation
// au droit de rétractation de 14 jours. Une case pré-cochée annulerait
// juridiquement la renonciation.
//
// Les clients professionnels ne disposent pas du droit de rétractation : la
// case ne leur est pas affichée du tout.
// ============================================================================

export default function PaymentScreen({ mission, account, onDone, onClose }) {
  const [legal, setLegal] = useState(LEGAL_COPY);
  const [payment, setPayment] = useState(null);
  const [waiverChecked, setWaiverChecked] = useState(false); // JAMAIS pré-coché.
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const [notice, setNotice] = useState("");

  const isPro = account?.clientType && account.clientType !== "particulier";
  const waiverRequired = payment ? payment.waiverRequired : !isPro;

  useEffect(() => {
    let alive = true;
    supabase
      .from("app_settings")
      .select("value")
      .eq("key", "legal_texts")
      .maybeSingle()
      .then(({ data }) => {
        if (alive && data?.value) setLegal(currentLegalCopy(data.value));
      });
    return () => { alive = false; };
  }, []);

  useEffect(() => {
    let alive = true;
    prepareCommissionPayment(mission.id)
      .then(async (result) => {
        if (!alive) return;
        const row = await fetchPayment(result.payment_id);
        if (alive) setPayment(row);
      })
      .catch((e) => { if (alive) setError(e.message || "Paiement indisponible."); });
    return () => { alive = false; };
  }, [mission.id]);

  useEffect(() => {
    if (!payment?.id) return undefined;
    return watchPayment(payment.id, (updated) => {
      setPayment(updated);
      if (updated.status === "paid") {
        setNotice("Paiement confirmé. Le bon de mission part au transporteur.");
        setBusy(false);
        onDone?.(updated);
      }
      if (updated.status === "failed") {
        setBusy(false);
        setError("Le paiement n'a pas abouti. Aucun montant n'a été prélevé.");
      }
    });
  }, [payment?.id, onDone]);

  const handlePay = useCallback(async () => {
    if (!payment) return;
    setBusy(true); setError(""); setNotice("");
    try {
      if (waiverRequired) {
        if (!waiverChecked) {
          setError("Cochez la case ci-dessus pour poursuivre.");
          setBusy(false);
          return;
        }
        await acceptPaymentWaiver(payment.id);
      }
      const outcome = await payNow(payment.id);
      if (outcome.cancelled) {
        setBusy(false);
        setNotice("Paiement abandonné. Votre créneau n'est pas réservé.");
        return;
      }
      if (outcome.pending) {
        setNotice("Paiement en cours de confirmation…");
      }
    } catch (e) {
      setBusy(false);
      setError(e.message || "Paiement impossible.");
    }
  }, [payment, waiverChecked, waiverRequired]);

  const commission = payment ? payment.amount : (mission.commissionAmount ?? 0);
  const transport = mission.transportAmount ?? mission.carrierCost ?? 0;
  const total = mission.clientTotalDue ?? (Number(commission) + Number(transport));
  const paid = payment?.status === "paid";

  return (
    <div className="panel panel-full">
      <h2>{legal.commission_label}</h2>
      <p className="muted">
        Mission {mission.publicRef || ""} — {mission.fromCity || "Départ"} vers{" "}
        {mission.toCity || "Arrivée"}
      </p>

      {error && <div className="alert error">{error}</div>}
      {notice && <div className="alert success">{notice}</div>}

      <div className="card-section">
        <div className="payment-line">
          <div>
            <strong>Frais de réservation SECOTO — 20 %</strong>
            <p className="muted">{legal.commission_notice}</p>
          </div>
          <b>{formatAmount(commission)}</b>
        </div>

        <div className="payment-line">
          <div>
            <strong>Prix du transport</strong>
            <p className="muted">{legal.transport_notice}</p>
          </div>
          <b>{formatAmount(transport)}</b>
        </div>

        <div className="payment-line payment-total">
          <div><strong>Total de votre transport</strong></div>
          <b>{formatAmount(total)}</b>
        </div>

        <p className="muted">
          Montant réglé maintenant dans l’application : <strong>{formatAmount(commission)}</strong>.
          Le prix du transport est réglé directement au transporteur.
        </p>
      </div>

      {waiverRequired && !paid && (
        <label className="field field-full payment-waiver">
          <span className="payment-waiver-row">
            <input
              type="checkbox"
              checked={waiverChecked}
              onChange={(e) => setWaiverChecked(e.target.checked)}
              disabled={busy}
            />
            <span>
              <span className="payment-waiver-mention">{legal.waiver_execution}</span>
              <span className="payment-waiver-mention">{legal.waiver_withdrawal}</span>
            </span>
          </span>
        </label>
      )}

      {!waiverRequired && !paid && (
        <p className="muted">
          Le droit de rétractation de 14 jours est réservé aux consommateurs,
          sous réserve des cas d’extension prévus par la loi.
        </p>
      )}

      <p className="muted">{legal.refund_policy}</p>

      <div className="actions-row" style={{ flexWrap: "wrap" }}>
        <button className="btn ghost" type="button" onClick={onClose} disabled={busy}>
          Revenir
        </button>
        <button
          className="btn primary"
          type="button"
          onClick={handlePay}
          disabled={busy || paid || !payment || (waiverRequired && !waiverChecked)}
        >
          {paid
            ? "Créneau réservé ✓"
            : busy
              ? "Paiement en cours…"
              : `Payer ${formatAmount(commission)}`}
        </button>
      </div>

      <p className="muted">
        Apple&nbsp;Pay, Google&nbsp;Pay et cartes enregistrées. Paiement sécurisé
        par Stripe — SECOTO ne stocke aucune donnée bancaire.
      </p>
    </div>
  );
}
