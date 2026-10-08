import { humanizeError } from "../lib/humanError";
import { useEffect, useMemo, useRef, useState } from "react";
import DecompositionPrix from "./DecompositionPrix";
import ReassuranceReservation from "./ReassuranceReservation";
import VerifiedAddressField from "./VerifiedAddressField";
import {
  MANUAL_REASONS, SLOTS, VEHICLE_CLASSES, VEHICLE_CONSTRAINTS,
  OFFER_WINDOW_HOURS, TVA_MENTION,
  bookQuote, cancellationPolicy, formatCents, formatDateTime, paymentExplanation, publicQuote,
  rememberAnonQuote, requestQuote, subscriptionOverview,
} from "../lib/onDemand";
import { acceptPaymentWaiver, fetchPayment, payNow, watchPayment } from "../lib/payments";

const STEPS = ["Trajet", "Véhicule", "Mode", "Dates", "Prix", "Paiement"];

const emptyForm = () => ({
  pickup: null,
  delivery: null,
  vehicle: { model: "", class: "voiture", category: "standard", rolling: true, constraints: [], length_m: "", weight_kg: "", notes: "" },
  // Groupage : jusqu'a deux vehicules de plus sur le meme trajet.
  extras: [],
  mode: "convoyage",
  schedule: { pickup_date: "", slot: "matin", flexibility_days: 0 },
});

function todayIso() {
  const d = new Date();
  d.setMinutes(d.getMinutes() - d.getTimezoneOffset());
  return d.toISOString().slice(0, 10);
}

// `anonyme` : le visiteur n'a pas encore de compte. Il obtient son prix, puis
// crée son compte pour réserver — jamais l'inverse.
export default function OnDemandBooking({ flags, onBooked, initialQuote = null, anonyme = false, onNeedAccount = null, reserverAussitot = false }) {
  const [step, setStep] = useState(initialQuote ? 4 : 0);
  // Repris du site vitrine (?vehicle=…&service=…) : le modele et le mode sont
  // pre-remplis. Les adresses, elles, sont toujours resaisies et verifiees.
  const [form, setForm] = useState(() => {
    const base = emptyForm();
    try {
      const brut = sessionStorage.getItem("secoto:od-prefill");
      if (!brut) return base;
      sessionStorage.removeItem("secoto:od-prefill");
      const p = JSON.parse(brut);
      if (p?.model) base.vehicle.model = String(p.model).slice(0, 120);
      if (p?.mode === "plateau" || p?.mode === "convoyage") base.mode = p.mode;
    } catch { /* stockage indisponible : on part du formulaire vide */ }
    return base;
  });
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
    // Sans compte, il n'y a pas de forfait a interroger : l'appel echouerait.
    if (anonyme || !flags?.subscriptions) return;
    subscriptionOverview().then(setOverview).catch(() => setOverview(null));
  }, [anonyme, flags?.subscriptions]);

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
  const extras = form.extras || [];
  const setExtra = (i, patch) => setForm((f) => ({
    ...f,
    extras: (f.extras || []).map((v, j) => (j === i ? { ...v, ...patch } : v)),
  }));
  const addExtra = () => setForm((f) => ({
    ...f,
    extras: [...(f.extras || []), { model: "", class: "voiture", category: "standard", rolling: true, constraints: [], notes: "" }],
  }));
  const removeExtra = (i) => setForm((f) => ({ ...f, extras: (f.extras || []).filter((_, j) => j !== i) }));
  // Un seul vehicule non roulant suffit a exclure le convoyage.
  const toutRoule = form.vehicle.rolling && extras.every((v) => v.rolling);
  const setSchedule = (patch) => setForm((f) => ({ ...f, schedule: { ...f.schedule, ...patch } }));

  const stepError = useMemo(() => {
    if (step === 0) {
      if (!form.pickup?.verified || !form.delivery?.verified) return "Sélectionnez les deux adresses dans la liste proposée.";
      if (form.pickup.label === form.delivery.label) return "Le départ et l’arrivée sont identiques.";
    }
    if (step === 1 && form.vehicle.model.trim().length < 2) return "Indiquez le modèle du véhicule.";
    if (step === 1 && (form.extras || []).some((v) => v.model.trim().length < 2)) return "Indiquez le modèle de chaque véhicule.";
    if (step === 2 && form.mode === "convoyage" && !form.vehicle.rolling) return "Un véhicule non roulant se transporte sur plateau.";
    if (step === 2 && form.mode === "convoyage" && (form.extras || []).some((v) => !v.rolling)) return "Un véhicule non roulant se transporte sur plateau.";
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
        ...((form.extras || []).length
          ? {
              vehicles: [
                {
                  ...form.vehicle,
                  length_m: form.vehicle.length_m ? Number(form.vehicle.length_m) : null,
                  weight_kg: form.vehicle.weight_kg ? Number(form.vehicle.weight_kg) : null,
                },
                ...form.extras,
              ],
            }
          : {}),
        schedule: { ...form.schedule, flexibility_days: Number(form.schedule.flexibility_days) || 0 },
        ...(subscriptionActive && overview?.business?.id ? { business_id: overview.business.id } : {}),
      };
      const result = anonyme ? await publicQuote(payload) : await requestQuote(payload);
      if (anonyme) rememberAnonQuote(result.token);
      setQuote(result.quote);
      setStep(4);
    } catch (e) {
      setError(humanizeError(e));
    } finally {
      setBusy(false);
    }
  }

  // Le client a deja clique « Reserver » avant de creer son compte : on ne le
  // renvoie pas sur un bouton, on l'emmene directement au paiement.
  const reservationLancee = useRef(false);
  useEffect(() => {
    if (!reserverAussitot || reservationLancee.current) return;
    if (!quote?.id || !["priced", "manual_priced"].includes(quote.status)) return;
    reservationLancee.current = true;
    book();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [reserverAussitot, quote?.id, quote?.status]);

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
      setError(humanizeError(e));
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
      setError(humanizeError(e));
      setBusy(false);
    }
  }

  const guaranteed = order && (order.funding === "subscription" || ["requires_capture", "paid"].includes(payment?.status));
  // 074 : plateau et moto en paiement direct — carte validée, débit à l'acceptation.
  const direct = order?.payment_circuit === "direct";
  // 081 : le devis plateau annonce déjà le circuit direct (interrupteur allumé).
  const devisDirect = quote?.payment_circuit === "direct";

  return (
    <div className="panel panel-full">
      <h2>Transport à la demande</h2>
      <p className="muted">
        {direct || devisDirect
          ? "Prix calculé sur l’itinéraire réel. Vous n’êtes débité que lorsqu’un transporteur indépendant accepte votre transport."
          : "Prix calculé sur l’itinéraire réel. Paiement encaissé et gardé en réserve 48 h, le temps qu’un transporteur accepte."}
      </p>
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

          {extras.map((v, i) => (
            <fieldset className="field field-full" key={i}>
              <span>Véhicule {i + 2}</span>
              <div className="form-grid">
                <label className="field"><span>Modèle *</span>
                  <input value={v.model} maxLength={120} placeholder="Ex. Yamaha MT-07" onChange={(e) => setExtra(i, { model: e.target.value })} />
                </label>
                <label className="field"><span>Catégorie</span>
                  <select value={v.class} onChange={(e) => setExtra(i, { class: e.target.value })}>
                    {VEHICLE_CLASSES.map((c) => <option key={c.value} value={c.value}>{c.label}</option>)}
                  </select>
                </label>
                <label className="field"><span>Gamme</span>
                  <select value={v.category} onChange={(e) => setExtra(i, { category: e.target.value })}>
                    <option value="standard">Standard</option>
                    <option value="luxury">Prestige / collection</option>
                  </select>
                </label>
                <label className="field"><span>État</span>
                  <select value={v.rolling ? "roulant" : "non_roulant"} onChange={(e) => setExtra(i, { rolling: e.target.value === "roulant" })}>
                    <option value="roulant">Roulant</option>
                    <option value="non_roulant">Non roulant</option>
                  </select>
                </label>
                <label className="field field-full"><span>Précisions</span>
                  <textarea maxLength={500} rows={2} value={v.notes} onChange={(e) => setExtra(i, { notes: e.target.value })} placeholder="Facultatif" />
                </label>
              </div>
              <button className="btn" type="button" onClick={() => removeExtra(i)}>Retirer ce véhicule</button>
            </fieldset>
          ))}

          {extras.length < 2 && (
            <div className="field field-full">
              <button className="btn" type="button" onClick={addExtra}>
                Ajouter un véhicule sur le même trajet
              </button>
              <small className="muted">
                {form.mode === "plateau" || !toutRoule
                  ? "Plusieurs véhicules sur le même camion : le prix baisse pour chacun d’eux."
                  : "Jusqu’à 3 véhicules. Sur plateau, le prix baisse pour chacun d’eux."}
              </small>
            </div>
          )}
        </div>
      )}

      {step === 2 && (
        <div className="od-choice" role="radiogroup" aria-label="Mode de transport">
          <label className={`${form.mode === "convoyage" ? "is-selected" : ""} ${!toutRoule ? "is-disabled" : ""}`}>
            <input type="radio" name="od-mode" checked={form.mode === "convoyage"} disabled={!toutRoule} onChange={() => setForm((f) => ({ ...f, mode: "convoyage" }))} />
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
                <span>Prix total du transport</span>
                <strong>{formatCents(quote.client_price_cents)}</strong>
              </div>
              <p className="muted">
                {(quote.vehicles?.length || 1) > 1 ? `${quote.vehicles.length} véhicules sur le même trajet. ` : ""}
                {devisDirect
                  ? "Tout compris, réglé en une seule fois, directement au transporteur qui accepte votre transport. "
                  : "Tout compris, réglé en une seule fois à SECOTO. "}
                {TVA_MENTION}
              </p>
              {devisDirect && <DecompositionPrix totalCents={quote.client_price_cents} commissionCents={quote.commission_cents} />}
              {quote.group_discount_cents > 0 && quote.vehicles?.length > 1 && (
                <p className="od-remise">
                  <strong>Groupage : vous économisez {formatCents(quote.group_discount_cents)}</strong>
                  {" "}par rapport à {quote.vehicles.length} transports commandés séparément.
                </p>
              )}
              {quote.lines?.length > 0 && (
                <ul className="od-lines">{quote.lines.map((l, i) => <li key={i}><span>{l.label}</span><span>{Number(l.eur).toLocaleString("fr-FR", { style: "currency", currency: "EUR" })}</span></li>)}</ul>
              )}
              <div className="od-two">
                <div><strong>Inclus</strong><ul>{(quote.included || []).map((x) => <li key={x}>{x}</li>)}</ul></div>
                <div><strong>Non inclus</strong><ul>{(quote.excluded || []).length ? quote.excluded.map((x) => <li key={x}>{x}</li>) : <li>Aucun frais supplémentaire annoncé</li>}</ul></div>
              </div>
              <ReassuranceReservation mode={quote.mode} circuit={quote.payment_circuit} relation={Boolean(flags?.mise_en_relation_v2)} />
              <p className="muted">Devis valable jusqu’au {formatDateTime(quote.valid_until)} · barème v{quote.grid_version || "—"}.</p>
              <p className="muted">{cancellationPolicy(order)}</p>
              {subscriptionActive && (
                <label className="od-checks"><input type="checkbox" checked={useSubscription} onChange={(e) => setUseSubscription(e.target.checked)} /> Utiliser mon forfait (si ce trajet est couvert)</label>
              )}
            </>
          ) : quote.status === "expired" ? (
            <div className="alert error">Ce devis a expiré. Recalculez le prix.</div>
          ) : (
            <div className="alert">
              {MANUAL_REASONS[quote.manual_reason] || "Ce transport fait l’objet d’un devis personnalisé."}{" "}
              {anonyme
                ? "Créez votre compte pour que SECOTO puisse vous transmettre le prix : c’est le seul moyen de vous recontacter."
                : "Votre demande est transmise à SECOTO : vous recevrez le prix dans l’application."}{" "}
              Aucun paiement n’est demandé à ce stade.
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
                  <span>Je demande l’exécution immédiate du transport et renonce expressément à mon droit de rétractation de 14 jours.</span>
                </label>
              )}
              <p className="muted">Apple Pay, Google Pay ou carte selon votre appareil et votre navigateur.</p>
              <button className="btn primary" type="button" disabled={busy || !online} onClick={pay}>
                {busy ? "Validation en cours…" : direct
                  ? "Valider ma carte — aucun débit maintenant"
                  : `Payer ${formatCents(order.client_price_cents ?? order.collect_cents)}`}
              </button>
              {direct && <DecompositionPrix totalCents={order.client_price_cents ?? order.collect_cents} commissionCents={order.commission_cents} />}
              <ReassuranceReservation mode={order.mode} circuit={order.payment_circuit} relation={Boolean(flags?.mise_en_relation_v2)} compact />
              {payment.status === "processing" && <p className="muted">En attente de la confirmation de votre banque…</p>}
            </>
          )}
          {guaranteed && (
            <div className="alert success">
              {order.funding === "subscription" ? "Forfait réservé." : direct
                ? `Carte validée, rien n’a été débité. Vous serez débité de ${formatCents(order.client_price_cents ?? order.collect_cents)} au nom du transporteur qui accepte la mission.`
                : "Paiement encaissé et gardé en réserve 48 heures."}{" "}
              {direct
                ? `Votre demande est proposée aux transporteurs indépendants vérifiés : ils ont ${OFFER_WINDOW_HOURS} h pour l’accepter. Sans acceptation, elle est annulée, sans aucun débit.`
                : `Votre demande part à tous nos transporteurs compatibles : ils ont ${OFFER_WINDOW_HOURS} h pour l’accepter.`}
              Vous êtes notifié dès qu’un transporteur confirme{direct && flags?.mise_en_relation_v2 ? " : ses coordonnées s’affichent alors dans votre commande et vous échangez directement avec lui jusqu’à la livraison." : "."}
              <div className="actions-row"><button className="btn primary small" type="button" onClick={() => onBooked?.(order)}>Suivre ma commande</button></div>
            </div>
          )}
        </div>
      )}

      <div className="actions-row">
        {step > 0 && step < 5 && <button className="btn ghost" type="button" disabled={busy} onClick={() => { setError(""); setStep(step === 4 ? 3 : step - 1); }}>Retour</button>}
        {step < 3 && <button className="btn primary" type="button" disabled={Boolean(stepError)} onClick={() => setStep(step + 1)}>Continuer</button>}
        {step === 3 && <button className="btn primary" type="button" disabled={Boolean(stepError) || busy || !online} onClick={computePrice}>{busy ? "Calcul de l’itinéraire…" : "Calculer le prix"}</button>}
        {step === 4 && quote && ["priced", "manual_priced"].includes(quote.status) && anonyme && (
          <button className="btn primary" type="button" disabled={busy || !online} onClick={() => onNeedAccount?.(quote)}>
            Réserver ce transport
          </button>
        )}
        {step === 4 && quote && ["priced", "manual_priced"].includes(quote.status) && !anonyme && (
          <button className="btn primary" type="button" disabled={busy || !online || (!flags?.od_payments && !useSubscription)} onClick={book}>
            {busy ? "Réservation…" : useSubscription ? "Réserver sur mon forfait" : "Réserver et passer au paiement"}
          </button>
        )}
        {step === 4 && quote && !["priced", "manual_priced"].includes(quote.status) && anonyme && quote.status !== "expired" && (
          <button className="btn primary" type="button" onClick={() => onNeedAccount?.(quote)}>Créer mon compte et recevoir le prix</button>
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
