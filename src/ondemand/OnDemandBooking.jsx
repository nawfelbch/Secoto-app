import { useEffect, useMemo, useState } from "react";
import VerifiedAddressField from "./VerifiedAddressField";
import {
  MANUAL_REASONS, SLOTS, VEHICLE_CLASSES, VEHICLE_CONSTRAINTS,
  bookQuote, formatCents, formatDateTime, paymentExplanation, requestQuote, subscriptionOverview,
} from "../lib/onDemand";
import { acceptPaymentWaiver, fetchPayment, payNow, watchPayment } from "../lib/payments";

const STEPS = ["Trajet", "Véhicule", "Mode", "Dates", "Prix", "Paiement"];

const emptyForm = () => ({
  pickup: null,
  delivery: null,
  vehicle: { model: "", class: "voiture", category: "standard", rolling: true, constraints: [], length_m: "", weight_kg: "", notes: "" },
  mode: "convoyage",
  schedule: { pickup_date: "", slot: "matin", flexibility_days: 0 },
});

function todayIso() {
  const d = new Date();
  d.setMinutes(d.getMinutes() - d.getTimezoneOffset());
  return d.toISOString().slice(0, 10);
}

export default function OnDemandBooking({ flags, onBooked, initialQuote = null }) {
  const [step, setStep] = useState(initialQuote ? 4 : 0);
  const [form, setForm] = useState(emptyForm);
  const [quote, setQuote] = useState(initialQuote);
  const [order, setOrder] = useState(null);
  const [payment, setPayment] = useState(null);
  const [waiver, setWaiver] = useState(false); // jamais pré-cochée
  const [useSubscription, setUseSubscription] = useState(false);
  const [overview, setOverview] = useState(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const [online, setOnline] = useState(typeof navigator === "undefined" ? true : navigator.onLine);

  useEffect(() => {
    const on = () => setOnline(true);
    const off = () => setOnline(false);
    window.addEventListener("online", on);
    window.addEventListener("offline", off);
    return () => { window.removeEventListener("online", on); window.removeEventListener("offline", off); };
  }, []);

  useEffect(() => {
    if (!flags?.subscriptions) return;
    subscriptionOverview().then(setOverview).catch(() => setOverview(null));
  }, [flags?.subscriptions]);

  useEffect(() => {
    if (!payment?.id) return undefined;
    const apply = (row) => {
      if (!row) return;
      setPayment(row);
      if (["requires_capture", "paid"].includes(row.status)) setBusy(false);
      if (row.status === "failed") {
        setBusy(false);
        setError("Le paiement n’a pas abouti. Aucune demande n’a été diffusée.");
      }
    };
    const unwatch = watchPayment(payment.id, apply);
    // Filet : le temps réel peut être coupé (réseau, onglet en arrière-plan).
    // L'état du paiement est de toute façon écrit par le webhook signé.
    const poll = setInterval(async () => {
      if (document.visibilityState !== "visible") return;
      const row = await fetchPayment(payment.id).catch(() => null);
      apply(row);
      if (row && ["requires_capture", "paid", "failed", "cancelled"].includes(row.status)) clearInterval(poll);
    }, 5000);
    return () => { unwatch?.(); clearInterval(poll); };
  }, [payment?.id]);

  const subscriptionActive = overview?.subscription?.status === "active";
  const setVehicle = (patch) => setForm((f) => ({ ...f, vehicle: { ...f.vehicle, ...patch } }));
  const setSchedule = (patch) => setForm((f) => ({ ...f, schedule: { ...f.schedule, ...patch } }));

  const stepError = useMemo(() => {
    if (step === 0) {
      if (!form.pickup?.verified || !form.delivery?.verified) return "Sélectionnez les deux adresses dans la liste proposée.";
      if (form.pickup.label === form.delivery.label) return "Le départ et l’arrivée sont identiques.";
    }
    if (step === 1 && form.vehicle.model.trim().length < 2) return "Indiquez le modèle du véhicule.";
    if (step === 2 && form.mode === "convoyage" && !form.vehicle.rolling) return "Un véhicule non roulant se transporte sur plateau.";
    if (step === 3 && (!form.schedule.pickup_date || form.schedule.pickup_date < todayIso())) return "Choisissez une date de prise en charge à venir.";
    return "";
  }, [step, form]);

  async function computePrice() {
    setBusy(true);
    setError("");
    try {
      const payload = {
        mode: form.mode,
        pickup: form.pickup,
        delivery: form.delivery,
        vehicle: {
          ...form.vehicle,
          length_m: form.vehicle.length_m ? Number(form.vehicle.length_m) : null,
          weight_kg: form.vehicle.weight_kg ? Number(form.vehicle.weight_kg) : null,
        },
        schedule: { ...form.schedule, flexibility_days: Number(form.schedule.flexibility_days) || 0 },
        ...(subscriptionActive && overview?.business?.id ? { business_id: overview.business.id } : {}),
      };
      const result = await requestQuote(payload);
      setQuote(result.quote);
      setStep(4);
    } catch (e) {
      setError(e.message);
    } finally {
      setBusy(false);
    }
  }

  async function book() {
    setBusy(true);
    setError("");
    try {
      const result = await bookQuote(quote.id, useSubscription);
      setOrder(result.order);
      if (result.order.payment_id) {
        setPayment(await fetchPayment(result.order.payment_id));
      }
      setStep(5);
    } catch (e) {
      setError(e.message);
    } finally {
      setBusy(false);
    }
  }

  async function pay() {
    setBusy(true);
    setError("");
    try {
      if (payment.waiverRequired && !payment.waiverAccepted) {
        if (!waiver) throw new Error("Cochez la demande d’exécution immédiate pour continuer.");
        await acceptPaymentWaiver(payment.id);
      }
      const outcome = await payNow(payment.id);
      if (outcome.cancelled) setBusy(false);
      // La validation n'est affichée qu'à réception du webhook signé.
    } catch (e) {
      setError(e.message);
      setBusy(false);
    }
  }

  const guaranteed = order && (order.funding === "subscription" || ["requires_capture", "paid"].includes(payment?.status));

  return (
    <div className="panel panel-full">
      <h2>Transport à la demande</h2>
      <p className="muted">Prix calculé sur l’itinéraire réel, paiement validé avant diffusion aux partenaires vérifiés.</p>
      <ol className="od-steps" aria-label="Étapes">
        {STEPS.map((label, i) => (
          <li key={label} className={i === step ? "is-current" : i < step ? "is-done" : ""} aria-current={i === step ? "step" : undefined}>{i + 1}. {label}</li>
        ))}
      </ol>
      {!online && <div className="alert error">Vous êtes hors ligne. Le calcul du prix et le paiement nécessitent une connexion.</div>}
      {error && <div className="alert error" role="alert">{error}</div>}

      {step === 0 && (
        <div className="form-grid">
          <VerifiedAddressField label="Adresse de prise en charge" value={form.pickup} onChange={(v) => setForm((f) => ({ ...f, pickup: v }))} required />
          <VerifiedAddressField label="Adresse de livraison" value={form.delivery} onChange={(v) => setForm((f) => ({ ...f, delivery: v }))} required />
        </div>
      )}

      {step === 1 && (
        <div className="form-grid">
          <label className="field"><span>Modèle *</span>
            <input value={form.vehicle.model} maxLength={120} placeholder="Ex. Peugeot 3008" onChange={(e) => setVehicle({ model: e.target.value })} />
          </label>
          <label className="field"><span>Catégorie</span>
            <select value={form.vehicle.class} onChange={(e) => setVehicle({ class: e.target.value })}>
              {VEHICLE_CLASSES.map((c) => <option key={c.value} value={c.value}>{c.label}</option>)}
            </select>
          </label>
          <label className="field"><span>Gamme</span>
            <select value={form.vehicle.category} onChange={(e) => setVehicle({ category: e.target.value })}>
              <option value="standard">Standard</option>
              <option value="luxury">Prestige / collection</option>
            </select>
          </label>
          <label className="field"><span>État</span>
            <select value={form.vehicle.rolling ? "roulant" : "non_roulant"} onChange={(e) => setVehicle({ rolling: e.target.value === "roulant" })}>
              <option value="roulant">Roulant</option>
              <option value="non_roulant">Non roulant</option>
            </select>
          </label>
          <label className="field"><span>Longueur utile (m)</span>
            <input inputMode="decimal" value={form.vehicle.length_m} onChange={(e) => setVehicle({ length_m: e.target.value.replace(",", ".") })} placeholder="Facultatif" />
          </label>
          <label className="field"><span>Poids (kg)</span>
            <input inputMode="numeric" value={form.vehicle.weight_kg} onChange={(e) => setVehicle({ weight_kg: e.target.value })} placeholder="Facultatif" />
          </label>
          <fieldset className="field field-full">
            <span>Contraintes</span>
            <div className="od-checks">
              {VEHICLE_CONSTRAINTS.map((c) => (
                <label key={c.value}>
                  <input type="checkbox" checked={form.vehicle.constraints.includes(c.value)}
                    onChange={(e) => setVehicle({ constraints: e.target.checked ? [...form.vehicle.constraints, c.value] : form.vehicle.constraints.filter((x) => x !== c.value) })} />
                  {c.label}
                </label>
              ))}
            </div>
          </fieldset>
          <label className="field field-full"><span>Précisions</span>
            <textarea maxLength={500} rows={2} value={form.vehicle.notes} onChange={(e) => setVehicle({ notes: e.target.value })} placeholder="Accès, horaires du site…" />
          </label>
        </div>
      )}

      {step === 2 && (
        <div className="od-choice" role="radiogroup" aria-label="Mode de transport">
          <label className={`${form.mode === "convoyage" ? "is-selected" : ""} ${!form.vehicle.rolling ? "is-disabled" : ""}`}>
            <input type="radio" name="od-mode" checked={form.mode === "convoyage"} disabled={!form.vehicle.rolling} onChange={() => setForm((f) => ({ ...f, mode: "convoyage" }))} />
            <span><strong>Convoyage</strong><small>Un convoyeur vérifié conduit votre véhicule jusqu’à destination. Carburant et péages au réel, sur justificatifs.</small></span>
          </label>
          <label className={form.mode === "plateau" ? "is-selected" : ""}>
            <input type="radio" name="od-mode" checked={form.mode === "plateau"} onChange={() => setForm((f) => ({ ...f, mode: "plateau" }))} />
            <span><strong>Plateau</strong><small>Transport sur camion plateau, sans kilomètre au compteur. Adapté aux véhicules non roulants.</small></span>
          </label>
        </div>
      )}

      {step === 3 && (
        <div className="form-grid">
          <label className="field"><span>Date de prise en charge *</span>
            <input type="date" min={todayIso()} value={form.schedule.pickup_date} onChange={(e) => setSchedule({ pickup_date: e.target.value })} />
          </label>
          <label className="field"><span>Créneau</span>
            <select value={form.schedule.slot} onChange={(e) => setSchedule({ slot: e.target.value })}>
              {SLOTS.map((s) => <option key={s.value} value={s.value}>{s.label}</option>)}
            </select>
          </label>
          <label className="field"><span>Souplesse</span>
            <select value={form.schedule.flexibility_days} onChange={(e) => setSchedule({ flexibility_days: Number(e.target.value) })}>
              <option value={0}>Date impérative</option>
              <option value={1}>± 1 jour</option>
              <option value={2}>± 2 jours</option>
              <option value={5}>Dans la semaine</option>
            </select>
          </label>
        </div>
      )}

      {step === 4 && quote && (
        <div>
          <p><strong>{quote.pickup.city}</strong> → <strong>{quote.delivery.city}</strong> · {quote.vehicle.model} · {quote.mode === "plateau" ? "Plateau" : "Convoyage"}</p>
          {quote.distance_km && <p className="muted">Itinéraire routier : {quote.distance_km} km{quote.duration_min ? ` · environ ${Math.round(quote.duration_min / 60)} h ${String(Math.round(quote.duration_min % 60)).padStart(2, "0")}` : ""}</p>}
          {["priced", "manual_priced"].includes(quote.status) ? (
            <>
              <div className="od-price">
                <span>{quote.mode === "plateau" ? "Prix total du transport" : "Prix de la prestation"}</span>
                <strong>{formatCents(quote.client_price_cents)}</strong>
              </div>
              {quote.mode === "plateau" && (
                <p className="muted">Dont frais de mise en relation SECOTO : {formatCents(quote.collect_cents)} (réglés en ligne). Transport : {formatCents(quote.transport_direct_cents)}, réglé directement au transporteur.</p>
              )}
              {quote.lines?.length > 0 && (
                <ul className="od-lines">{quote.lines.map((l, i) => <li key={i}><span>{l.label}</span><span>{Number(l.eur).toLocaleString("fr-FR", { style: "currency", currency: "EUR" })}</span></li>)}</ul>
              )}
              <div className="od-two">
                <div><strong>Inclus</strong><ul>{(quote.included || []).map((x) => <li key={x}>{x}</li>)}</ul></div>
                <div><strong>Non inclus</strong><ul>{(quote.excluded || []).length ? quote.excluded.map((x) => <li key={x}>{x}</li>) : <li>Aucun frais supplémentaire annoncé</li>}</ul></div>
              </div>
              <p className="muted">Devis valable jusqu’au {formatDateTime(quote.valid_until)} · barème v{quote.grid_version || "—"}.</p>
              {subscriptionActive && (
                <label className="od-checks"><input type="checkbox" checked={useSubscription} onChange={(e) => setUseSubscription(e.target.checked)} /> Utiliser mon forfait (si ce trajet est couvert)</label>
              )}
            </>
          ) : quote.status === "expired" ? (
            <div className="alert error">Ce devis a expiré. Recalculez le prix.</div>
          ) : (
            <div className="alert">
              {MANUAL_REASONS[quote.manual_reason] || "Ce transport fait l’objet d’un devis personnalisé."} Votre demande est transmise à SECOTO :
              vous recevrez le prix dans l’application. Aucun paiement n’est demandé à ce stade.
            </div>
          )}
        </div>
      )}

      {step === 5 && order && (
        <div>
          <p><strong>Commande {order.public_ref}</strong></p>
          <p>{paymentExplanation(order)}</p>
          {order.funding === "card" && payment && !guaranteed && (
            <>
              {payment.waiverRequired && !payment.waiverAccepted && (
                <label className="payment-waiver-row">
                  <input type="checkbox" checked={waiver} onChange={(e) => setWaiver(e.target.checked)} />
                  <span>Je demande l’exécution immédiate de la mise en relation et renonce expressément à mon droit de rétractation de 14 jours.</span>
                </label>
              )}
              <p className="muted">Apple Pay, Google Pay ou carte selon votre appareil et votre navigateur.</p>
              <button className="btn primary" type="button" disabled={busy || !online} onClick={pay}>
                {busy ? "Validation en cours…" : `Valider mon moyen de paiement (${formatCents(order.collect_cents)})`}
              </button>
              {payment.status === "processing" && <p className="muted">En attente de la confirmation de votre banque…</p>}
            </>
          )}
          {guaranteed && (
            <div className="alert success">
              {order.funding === "subscription" ? "Forfait réservé." : payment?.status === "paid" ? "Paiement encaissé." : "Paiement autorisé, rien n’est débité à ce stade."}{" "}
              Votre demande est proposée aux partenaires compatibles. Vous serez notifié dès qu’un partenaire confirme.
              <div className="actions-row"><button className="btn primary small" type="button" onClick={() => onBooked?.(order)}>Suivre ma commande</button></div>
            </div>
          )}
        </div>
      )}

      <div className="actions-row">
        {step > 0 && step < 5 && <button className="btn ghost" type="button" disabled={busy} onClick={() => { setError(""); setStep(step === 4 ? 3 : step - 1); }}>Retour</button>}
        {step < 3 && <button className="btn primary" type="button" disabled={Boolean(stepError)} onClick={() => setStep(step + 1)}>Continuer</button>}
        {step === 3 && <button className="btn primary" type="button" disabled={Boolean(stepError) || busy || !online} onClick={computePrice}>{busy ? "Calcul de l’itinéraire…" : "Calculer le prix"}</button>}
        {step === 4 && quote && ["priced", "manual_priced"].includes(quote.status) && (
          <button className="btn primary" type="button" disabled={busy || !online || (!flags?.od_payments && !useSubscription)} onClick={book}>
            {busy ? "Réservation…" : useSubscription ? "Réserver sur mon forfait" : "Réserver et passer au paiement"}
          </button>
        )}
        {step === 4 && quote && !["priced", "manual_priced"].includes(quote.status) && (
          <button className="btn ghost" type="button" onClick={() => { setQuote(null); setForm(emptyForm()); setStep(0); }}>Nouvelle demande</button>
        )}
        {stepError && step < 4 && <small className="muted" aria-live="polite">{stepError}</small>}
      </div>
      {step === 4 && quote && ["priced", "manual_priced"].includes(quote.status) && !flags?.od_payments && !useSubscription && (
        <p className="muted">Le paiement en ligne n’est pas encore ouvert : contactez SECOTO pour confirmer ce devis.</p>
      )}
    </div>
  );
}
