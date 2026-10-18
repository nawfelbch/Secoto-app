import EtatsDesLieuxCommande from "./EtatsDesLieuxCommande";
import { CarteTransporteur } from "../CarteContact";
import { humanizeError } from "../lib/humanError";
import { useCallback, useEffect, useState } from "react";
import DecompositionPrix from "./DecompositionPrix";
import OnDemandBooking from "./OnDemandBooking";
import LiveTrackingView from "./LiveTrackingView";
import {
  MANUAL_REASONS, MILESTONES, NO_PARTNER_REFUND_HOURS, ORDER_STATUS_LABEL, paymentStateLabel,
  cancelOrder, cancelPreview, cancellationNotice, cancellationPolicy,
  formatCents, formatDateTime, myOrders, myQuotes, orderHeadline, paymentExplanation,
  OFFRE_LIBELLE, isDiffereOrder, isReglementArrivee, MODE_REGLEMENT_LIBELLE, reproposerCommande,
} from "../lib/onDemand";
import { memoriserOffre } from "../lib/offres";
import { ChoixReglement, ReglementLivraison } from "./ReglementArrivee";

// 099 : temps restant dans la fenêtre de prise en charge, en clair.
function resteFenetre(fin) {
  const ms = Date.parse(fin) - Date.now();
  if (!Number.isFinite(ms) || ms <= 0) return "";
  const h = Math.round(ms / 3600000);
  return h < 48 ? `il reste environ ${Math.max(h, 1)} h` : `il reste environ ${Math.round(h / 24)} jours`;
}
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
      setError(humanizeError(e));
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

  // 099 : relance en un clic — nouveau devis du même trajet, offre présélectionnée.
  async function relancer(order, offre) {
    setBusyId(order.id);
    try {
      const q = await reproposerCommande(order.id);
      memoriserOffre(q.id, offre);
      setBookingQuote(q);
    } catch (e) { setError(humanizeError(e)); } finally { setBusyId(null); }
  }

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
          // Le suivi n'a de sens qu'une fois le vehicule a bord : avant, il
          // montrerait le transporteur chez lui ou sur une autre course, et
          // apres la livraison, la session est deja arretee.
          const canTrack = flags?.live_tracking && order.mission_id && order.status === "picked_up";
          return (
            <article id={`order-${order.id}`} className={`mission-card${focusOrderId === order.id ? " is-focused" : ""}`} key={order.id}>
              <div className="card-top">
                <span className="badge">{order.public_ref}</span>
                <span className={`status ${order.status === "cancelled" || order.status === "no_partner" ? "status-cancelled" : order.status === "delivered" ? "status-completed" : "status-pending"}`}>{ORDER_STATUS_LABEL[order.status]}</span>
              </div>
              <h3>{order.pickup.city} → {order.delivery.city}</h3>
              <p>{order.vehicle.model} · {order.mode === "plateau" ? "plateau" : "convoyage"} · {formatDateTime(order.pickup_at)}</p>
              <p><strong>{orderHeadline(order)}</strong></p>
              {order.offre && <p className="muted">Offre {OFFRE_LIBELLE[order.offre] || order.offre}{order.fenetre_fin && ["searching_partner", "partner_locked"].includes(order.status)
                ? ` · fenêtre de prise en charge jusqu’au ${formatDateTime(order.fenetre_fin)}${resteFenetre(order.fenetre_fin) ? ` (${resteFenetre(order.fenetre_fin)})` : ""}`
                : ""}</p>}
              {order.funding === "card" && order.payment_status && (
                <p><span className={`od-pill ${["paid", "requires_capture"].includes(order.payment_status) ? "is-ok" : ["failed", "capture_failed"].includes(order.payment_status) ? "is-bad" : "is-warn"}`}>{paymentStateLabel(order)}</span> {formatCents(order.collect_cents)}</p>
              )}
              {order.funding === "card" && (order.payment_circuit === "direct" || isDiffereOrder(order)) && (
                <DecompositionPrix totalCents={order.client_price_cents ?? order.collect_cents} commissionCents={order.commission_cents} />
              )}
              {order.funding === "subscription" && <p><span className="od-pill is-ok">Inclus dans votre forfait</span></p>}
              {/* 100 : règlement à l'arrivée — mode choisi (modifiable avant confirmation), puis règlement à la livraison. */}
              {isReglementArrivee(order) && order.mode_reglement && !["searching_partner", "awaiting_payment"].includes(order.status) && order.status !== "delivered" && (
                <p className="muted">Règlement à l’arrivée : {MODE_REGLEMENT_LIBELLE[order.mode_reglement] || order.mode_reglement}.</p>
              )}
              {isReglementArrivee(order) && ["searching_partner", "awaiting_payment"].includes(order.status) && (
                <ChoixReglement order={order} onChange={(o) => setOrders((list) => (list || []).map((x) => (x.id === o.id ? o : x)))} />
              )}
              {isReglementArrivee(order) && order.status === "delivered" && (
                <ReglementLivraison order={order} busy={busyId === order.id} onPayer={async () => {
                  setBusyId(order.id);
                  try { await payNow(order.payment_id); } catch (e) { setError(humanizeError(e)); } finally { setBusyId(null); load(); }
                }} />
              )}
              {order.partner_contact
                ? <CarteTransporteur contact={order.partner_contact} reference={order.public_ref} />
                : order.partner_name && <p>Transporteur : <strong>{order.partner_name}</strong></p>}
              {order.mission_id && ["picked_up", "delivered", "partner_confirmed"].includes(order.status) && (
                <EtatsDesLieuxCommande missionId={order.mission_id} refreshKey={`${order.status}:${order.updated_at}`} />
              )}
              <ol className="od-milestones">
                {MILESTONES.filter((m) => order.funding === "card" || !m.key.startsWith("paiement")).map((m) => (
                  <li key={m.key} className={order.milestones?.[m.key] ? "is-done" : ""}>{m.label}{order.milestones?.[m.key] && <time>{formatDateTime(order.milestones[m.key])}</time>}</li>
                ))}
              </ol>
              {order.status === "awaiting_payment" && order.funding === "card" && <p className="muted">{paymentExplanation(order)}</p>}
              {["searching_partner", "partner_confirmed"].includes(order.status) && order.funding === "card" && (
                <p className="muted">{cancellationPolicy(order)}</p>
              )}
              {order.status === "no_partner" && (
                <p className="muted">
                  {isDiffereOrder(order) ? "Aucun transporteur n’a confirmé dans la fenêtre choisie." : "Aucun transporteur ne s’est rendu disponible."} {order.funding !== "card"
                    ? "Votre droit de forfait est restitué."
                    : isDiffereOrder(order)
                      ? "Rien n’a été débité ; la demande est annulée. Relancez-la en un clic ci-dessous."
                      : order.payment_circuit === "direct"
                      ? "Votre carte n’a pas été débitée."
                      : `Vous êtes remboursé intégralement sous ${NO_PARTNER_REFUND_HOURS} h.`}
                </p>
              )}
              {order.payment_action_required && (
                <div className="alert error" role="alert">
                  Un transporteur a accepté votre mission. Validez le paiement pour confirmer le transport (demande de
                  votre banque, ou paiement par Klarna, Satispay…). Sans validation, la mission sera proposée à nouveau.
                </div>
              )}
              <div className="actions-row">
                {order.payment_action_required && (
                  <button className="btn primary small" type="button" disabled={busyId === order.id} onClick={async () => {
                    setBusyId(order.id);
                    try { await payNow(order.payment_id); } catch (e) { setError(humanizeError(e)); } finally { setBusyId(null); load(); }
                  }}>Valider le paiement</button>
                )}
                {order.funding === "card" && (order.status === "awaiting_payment" || order.payment_status === "capture_failed" || order.payment_status === "failed") && order.status !== "cancelled"
                  && !(isReglementArrivee(order) && order.status === "delivered") && (
                  <button className="btn primary small" type="button" disabled={busyId === order.id} onClick={async () => {
                    setBusyId(order.id);
                    try { await payNow(order.payment_id); } catch (e) { setError(humanizeError(e)); } finally { setBusyId(null); load(); }
                  }}>{order.payment_status === "capture_failed"
                    ? (order.payment_circuit === "direct" ? "Mettre à jour ma carte" : "Mettre à jour le paiement")
                    : isReglementArrivee(order) ? "Enregistrer ma carte — 0 € prélevé"
                    : order.payment_circuit === "direct" ? "Valider ma carte" : "Valider le paiement"}</button>
                )}
                {order.status === "no_partner" && order.offre && flags?.trois_offres && (
                  <>
                    {order.offre !== "express" && (
                      <button className="btn primary small" type="button" disabled={busyId === order.id} onClick={() => relancer(order, "express")}>Relancer en Express</button>
                    )}
                    <button className="btn ghost small" type="button" disabled={busyId === order.id} onClick={() => relancer(order, order.offre)}>Relancer avec une nouvelle fenêtre</button>
                  </>
                )}
                {canTrack && <button className="btn ghost small" type="button" onClick={() => setTracking(order.mission_id)}>Suivre en direct</button>}
                {cancellable && (
                  <button className="btn danger small" type="button" disabled={busyId === order.id} onClick={async () => {
                    setBusyId(order.id);
                    try {
                      // On annonce le montant exact AVANT de demander confirmation :
                      // c'est le serveur qui calcule la retenue, jamais l'écran.
                      const preview = await cancelPreview(order.id);
                      if (!window.confirm(`${cancellationNotice(preview, order)}\n\nConfirmer l’annulation ?`)) return;
                      await cancelOrder(order.id);
                    } catch (e) { setError(humanizeError(e)); } finally { setBusyId(null); load(); }
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
