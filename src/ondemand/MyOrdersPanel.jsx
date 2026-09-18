import { useCallback, useEffect, useState } from "react";
import OnDemandBooking from "./OnDemandBooking";
import LiveTrackingView from "./LiveTrackingView";
import {
  MANUAL_REASONS, MILESTONES, NO_PARTNER_REFUND_HOURS, ORDER_STATUS_LABEL, PAYMENT_STATE_LABEL,
  cancelOrder, cancelPreview, cancellationNotice, cancellationPolicy,
  formatCents, formatDateTime, myOrders, myQuotes, orderHeadline, paymentExplanation,
} from "../lib/onDemand";
import { payNow } from "../lib/payments";

export default function MyOrdersPanel({ flags, focusOrderId = null, focusMissionId = null }) {
  const [orders, setOrders] = useState(null);
  const [quotes, setQuotes] = useState([]);
  const [error, setError] = useState("");
  const [busyId, setBusyId] = useState(null);
  const [tracking, setTracking] = useState(null);
  const [bookingQuote, setBookingQuote] = useState(null);

  const load = useCallback(async () => {
    try {
      const [o, q] = await Promise.all([myOrders(), myQuotes()]);
      setOrders(o);
      setQuotes(q.filter((x) => ["manual_review", "manual_priced", "priced"].includes(x.status)));
      setError("");
    } catch (e) {
      setError(e.message);
      setOrders((prev) => prev || []);
    }
  }, []);

  useEffect(() => {
    queueMicrotask(load);
    const id = setInterval(() => { if (document.visibilityState === "visible") load(); }, 30000);
    return () => clearInterval(id);
  }, [load]);

  useEffect(() => {
    if (focusMissionId && orders?.some((o) => o.mission_id === focusMissionId)) queueMicrotask(() => setTracking(focusMissionId));
  }, [focusMissionId, orders]);

  if (tracking) return <LiveTrackingView missionId={tracking} onClose={() => setTracking(null)} />;
  if (bookingQuote) return <OnDemandBooking flags={flags} initialQuote={bookingQuote} onBooked={() => { setBookingQuote(null); load(); }} />;

  return (
    <div className="panel panel-full">
      <h2>Mes commandes</h2>
      {error && <div className="alert error">{error}</div>}
      {orders === null && <p className="muted">Chargement…</p>}

      {quotes.length > 0 && (
        <div className="applications-box">
          <h4>Devis</h4>
          <div className="cards">
            {quotes.map((q) => (
              <article className="mission-card" key={q.id}>
                <div className="card-top">
                  <span className="badge">{q.mode === "plateau" ? "Plateau" : "Convoyage"}</span>
                  <span className={`od-pill ${q.status === "manual_review" ? "is-warn" : "is-ok"}`}>{q.status === "manual_review" ? "Étude en cours" : "Prix disponible"}</span>
                </div>
                <h3>{q.pickup.city} → {q.delivery.city}</h3>
                <p>{q.vehicle.model} · prise en charge {formatDateTime(q.pickup_at)}</p>
                {q.status === "manual_review"
                  ? <p className="muted">{MANUAL_REASONS[q.manual_reason] || "Devis personnalisé en préparation."}</p>
                  : <p><strong>{formatCents(q.client_price_cents)}</strong> · valable jusqu’au {formatDateTime(q.valid_until)}</p>}
                {q.status !== "manual_review" && (
                  <div className="actions-row"><button className="btn primary small" type="button" onClick={() => setBookingQuote(q)}>Voir et réserver</button></div>
                )}
              </article>
            ))}
          </div>
        </div>
      )}

      {orders?.length === 0 && quotes.length === 0 && <div className="empty-state"><strong>Aucune commande</strong>Demandez un prix pour votre prochain transport.</div>}
      <div className="cards">
        {(orders || []).map((order) => {
          // Annulable jusqu'à la prise en charge du véhicule, y compris après
          // confirmation : la retenue éventuelle est annoncée avant de valider.
          const cancellable = ["awaiting_payment", "searching_partner", "partner_confirmed"].includes(order.status);
          const canTrack = flags?.live_tracking && order.mission_id && ["partner_confirmed", "picked_up", "delivered"].includes(order.status);
          return (
            <article id={`order-${order.id}`} className={`mission-card${focusOrderId === order.id ? " is-focused" : ""}`} key={order.id}>
              <div className="card-top">
                <span className="badge">{order.public_ref}</span>
                <span className={`status ${order.status === "cancelled" || order.status === "no_partner" ? "status-cancelled" : order.status === "delivered" ? "status-completed" : "status-pending"}`}>{ORDER_STATUS_LABEL[order.status]}</span>
              </div>
              <h3>{order.pickup.city} → {order.delivery.city}</h3>
              <p>{order.vehicle.model} · {order.mode === "plateau" ? "plateau" : "convoyage"} · {formatDateTime(order.pickup_at)}</p>
              <p><strong>{orderHeadline(order)}</strong></p>
              {order.funding === "card" && order.payment_status && (
                <p><span className={`od-pill ${["paid", "requires_capture"].includes(order.payment_status) ? "is-ok" : ["failed", "capture_failed"].includes(order.payment_status) ? "is-bad" : "is-warn"}`}>{PAYMENT_STATE_LABEL[order.payment_status] || order.payment_status}</span> {formatCents(order.collect_cents)}</p>
              )}
              {order.funding === "subscription" && <p><span className="od-pill is-ok">Inclus dans votre forfait</span></p>}
              {order.partner_name && <p>Partenaire : <strong>{order.partner_name}</strong></p>}
              <ol className="od-milestones">
                {MILESTONES.filter((m) => order.funding === "card" || !m.key.startsWith("paiement")).map((m) => (
                  <li key={m.key} className={order.milestones?.[m.key] ? "is-done" : ""}>{m.label}{order.milestones?.[m.key] && <time>{formatDateTime(order.milestones[m.key])}</time>}</li>
                ))}
              </ol>
              {order.status === "awaiting_payment" && order.funding === "card" && <p className="muted">{paymentExplanation(order)}</p>}
              {["searching_partner", "partner_confirmed"].includes(order.status) && order.funding === "card" && (
                <p className="muted">{cancellationPolicy()}</p>
              )}
              {order.status === "no_partner" && (
                <p className="muted">
                  Aucun transporteur ne s’est rendu disponible. {order.funding === "card"
                    ? `Vous êtes remboursé intégralement sous ${NO_PARTNER_REFUND_HOURS} h.`
                    : "Votre droit de forfait est restitué."}
                </p>
              )}
              <div className="actions-row">
                {order.funding === "card" && (order.status === "awaiting_payment" || order.payment_status === "capture_failed" || order.payment_status === "failed") && order.status !== "cancelled" && (
                  <button className="btn primary small" type="button" disabled={busyId === order.id} onClick={async () => {
                    setBusyId(order.id);
                    try { await payNow(order.payment_id); } catch (e) { setError(e.message); } finally { setBusyId(null); load(); }
                  }}>{order.payment_status === "capture_failed" ? "Mettre à jour le paiement" : "Valider le paiement"}</button>
                )}
                {canTrack && <button className="btn ghost small" type="button" onClick={() => setTracking(order.mission_id)}>Suivre en direct</button>}
                {cancellable && (
                  <button className="btn danger small" type="button" disabled={busyId === order.id} onClick={async () => {
                    setBusyId(order.id);
                    try {
                      // On annonce le montant exact AVANT de demander confirmation :
                      // c'est le serveur qui calcule la retenue, jamais l'écran.
                      const preview = await cancelPreview(order.id);
                      if (!window.confirm(`${cancellationNotice(preview)}\n\nConfirmer l’annulation ?`)) return;
                      await cancelOrder(order.id);
                    } catch (e) { setError(e.message); } finally { setBusyId(null); load(); }
                  }}>Annuler</button>
                )}
              </div>
            </article>
          );
        })}
      </div>
    </div>
  );
}
