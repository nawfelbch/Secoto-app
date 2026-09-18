import { humanizeError } from "../lib/humanError";
import { useCallback, useEffect, useRef, useState } from "react";
import { supabase } from "../supabaseClient";
import {
  VEHICLE_CLASSES, VEHICLE_CONSTRAINTS, SLOTS,
  acceptOffer, declineOffer, departmentsFromText, formatCents, formatDateTime,
  getOffer, markOfferSeen, myDispatchPreferences, myOffers, updateDispatchPreferences,
} from "../lib/onDemand";
import { randomIdempotencyKey } from "../lib/fileSafety";

const EQUIPMENT = [
  { value: "treuil", label: "Treuil (véhicules non roulants)" },
  { value: "camion_ferme", label: "Camion fermé" },
  { value: "plateau_2_places", label: "Plateau 2 places" },
  { value: "plateau_3_places", label: "Plateau 3 places" },
  { value: "hayon", label: "Hayon" },
];
const DAYS = ["Lun", "Mar", "Mer", "Jeu", "Ven", "Sam", "Dim"];

const RESULT_TEXT = {
  confirmed: "Mission confirmée. Elle est dans « Mes missions ».",
  pending_capture: "Confirmation du paiement du client en cours…",
  already_assigned: "Mission déjà attribuée à un autre partenaire.",
  expired: "Cette proposition n’est plus disponible.",
  unavailable: "Cette mission n’est plus disponible.",
  not_eligible: "Votre profil ne permet pas d’accepter cette mission (documents à jour, disponibilité ou préférences).",
  capture_failed: "Le paiement du client n’a pas pu être finalisé : la mission n’est pas confirmée. Aucune pénalité.",
};

// ---------------------------------------------------------------------------
// Préférences : aucune obligation d'horaire, de connexion ou d'acceptation.
// ---------------------------------------------------------------------------
export function DispatchPreferencesPanel({ transporterType }) {
  const [prefs, setPrefs] = useState(null);
  const [zonesText, setZonesText] = useState("");
  const [busy, setBusy] = useState(false);
  const [message, setMessage] = useState("");
  const [error, setError] = useState("");

  useEffect(() => {
    myDispatchPreferences()
      .then((p) => { setPrefs(p); setZonesText((p.zones || []).join(", ")); })
      .catch((e) => setError(humanizeError(e)));
  }, []);

  async function save(patch = {}) {
    setBusy(true); setError(""); setMessage("");
    try {
      const next = await updateDispatchPreferences({ ...prefs, ...patch, zones: departmentsFromText(zonesText) });
      setPrefs(next);
      setZonesText((next.zones || []).join(", "));
      setMessage("Préférences enregistrées.");
    } catch (e) {
      setError(humanizeError(e));
    } finally {
      setBusy(false);
    }
  }

  if (!prefs) return <div className="panel panel-full"><h2>Disponibilité</h2>{error ? <div className="alert error">{error}</div> : <p className="muted">Chargement…</p>}</div>;
  const toggle = (list, value) => (list.includes(value) ? list.filter((x) => x !== value) : [...list, value]);
  return (
    <div className="panel panel-full">
      <h2>Disponibilité et propositions</h2>
      <p className="muted">Vous êtes libre de vous rendre disponible ou non, de vous déconnecter et de refuser une proposition. Aucun horaire, aucune connexion quotidienne ni taux d’acceptation n’est exigé, et un refus n’a aucune conséquence sur votre compte.</p>
      {error && <div className="alert error">{error}</div>}
      {message && <div className="alert success">{message}</div>}
      <div className="od-choice">
        <label className={prefs.available ? "is-selected" : ""}>
          <input type="checkbox" checked={prefs.available} disabled={busy} onChange={(e) => save({ available: e.target.checked })} />
          <span><strong>Disponible pour des missions</strong><small>{prefs.available ? "Vous recevez les propositions compatibles avec vos préférences." : "Vous ne recevez aucune proposition."}</small></span>
        </label>
        <label className={prefs.notify_offline ? "is-selected" : ""}>
          <input type="checkbox" checked={prefs.notify_offline} disabled={busy} onChange={(e) => save({ notify_offline: e.target.checked })} />
          <span><strong>Notifications application fermée</strong><small>Recevoir une notification quand l’application est fermée ou que vous êtes déconnecté (autorisation du téléphone requise).</small></span>
        </label>
      </div>
      <h3 style={{ marginTop: 18 }}>Écran verrouillé</h3>
      <div className="od-choice">
        <label className={prefs.lockscreen_privacy === "masked" ? "is-selected" : ""}>
          <input type="radio" name="od-privacy" checked={prefs.lockscreen_privacy === "masked"} onChange={() => save({ lockscreen_privacy: "masked" })} />
          <span><strong>Aperçu masqué</strong><small>« Mission disponible » uniquement ; le détail s’affiche après ouverture de SECOTO.</small></span>
        </label>
        <label className={prefs.lockscreen_privacy === "detailed" ? "is-selected" : ""}>
          <input type="radio" name="od-privacy" checked={prefs.lockscreen_privacy === "detailed"} onChange={() => save({ lockscreen_privacy: "detailed" })} />
          <span><strong>Aperçu détaillé</strong><small>Départ et arrivée (commune), modèle, rémunération. Jamais les coordonnées du client.</small></span>
        </label>
      </div>
      <p className="muted">Sur iPhone, pour n’afficher le détail qu’après Face ID : Réglages › Notifications › Aperçus › « Si déverrouillé ».</p>
      <div className="form-grid" style={{ marginTop: 14 }}>
        <label className="field field-full"><span>Départements de prise en charge (vide = toute la France)</span>
          <input value={zonesText} placeholder="75, 92, 93, 94" onChange={(e) => setZonesText(e.target.value)} onBlur={() => save()} />
        </label>
        <fieldset className="field field-full"><span>Catégories de véhicules (aucune cochée = toutes)</span>
          <div className="od-checks">{VEHICLE_CLASSES.map((c) => (
            <label key={c.value}><input type="checkbox" checked={prefs.vehicle_classes.includes(c.value)} onChange={() => save({ vehicle_classes: toggle(prefs.vehicle_classes, c.value) })} />{c.label}</label>
          ))}</div>
        </fieldset>
        {transporterType !== "convoyeur" && (
          <fieldset className="field field-full"><span>Équipement</span>
            <div className="od-checks">{EQUIPMENT.map((c) => (
              <label key={c.value}><input type="checkbox" checked={prefs.equipment.includes(c.value)} onChange={() => save({ equipment: toggle(prefs.equipment, c.value) })} />{c.label}</label>
            ))}</div>
          </fieldset>
        )}
        <fieldset className="field field-full"><span>Jours de prise en charge (aucun coché = tous)</span>
          <div className="od-checks">{DAYS.map((d, i) => (
            <label key={d}><input type="checkbox" checked={prefs.weekdays.includes(i + 1)} onChange={() => save({ weekdays: toggle(prefs.weekdays, i + 1) })} />{d}</label>
          ))}</div>
        </fieldset>
      </div>
    </div>
  );
}

// ---------------------------------------------------------------------------
// Détail d'une proposition + acceptation / refus.
// ---------------------------------------------------------------------------
export function OfferDetail({ offerId, onClose, onConfirmed }) {
  const [offer, setOffer] = useState(null);
  const [result, setResult] = useState(null);
  const [error, setError] = useState("");
  const [busy, setBusy] = useState(false);
  const keyRef = useRef(randomIdempotencyKey()); // même clé pour les nouvelles tentatives

  const refresh = useCallback(async () => {
    try {
      const data = await getOffer(offerId);
      if (!data) { setError("Proposition introuvable."); return null; }
      setOffer(data);
      return data;
    } catch (e) {
      setError(humanizeError(e));
      return null;
    }
  }, [offerId]);

  useEffect(() => { queueMicrotask(() => { refresh(); markOfferSeen(offerId); }); }, [offerId, refresh]);

  // Pendant la capture : on relit l'état réel jusqu'à la décision.
  useEffect(() => {
    if (offer?.state !== "pending_capture") return undefined;
    const id = setInterval(async () => {
      const data = await refresh();
      if (data?.state === "confirmed") { setResult("confirmed"); onConfirmed?.(data); }
      else if (data && data.state !== "pending_capture") setResult(data.state === "available" ? "capture_failed" : data.state);
    }, 3000);
    return () => clearInterval(id);
  }, [offer?.state, refresh, onConfirmed]);

  async function accept() {
    setBusy(true); setError("");
    try {
      const r = await acceptOffer(offerId, keyRef.current);
      setResult(r.result);
      const data = await refresh();
      if (r.result === "confirmed") onConfirmed?.(data);
    } catch (e) {
      setError(humanizeError(e));
    } finally {
      setBusy(false);
    }
  }

  async function decline() {
    setBusy(true);
    try { await declineOffer(offerId); onClose?.(); } catch (e) { setError(humanizeError(e)); } finally { setBusy(false); }
  }

  if (!offer) return <div className="od-offer-sheet">{error ? <div className="alert error">{error}</div> : <p className="muted">Chargement…</p>}</div>;
  const constraints = (offer.vehicle?.constraints || []).map((c) => VEHICLE_CONSTRAINTS.find((x) => x.value === c)?.label || c);
  const available = offer.state === "available";
  return (
    <div className="od-offer-sheet" role="dialog" aria-modal="true" aria-labelledby={`offer-${offer.id}`}>
      <div className="card-top">
        <span className="badge">{offer.order_ref}</span>
        <span className={`od-pill ${available ? "is-ok" : offer.state === "confirmed" ? "is-ok" : "is-warn"}`}>
          {available ? "Disponible" : offer.state === "confirmed" ? "Confirmée" : offer.state === "pending_capture" ? "Confirmation en cours" : offer.state === "already_assigned" ? "Déjà attribuée" : offer.state === "declined" ? "Refusée" : "Indisponible"}
        </span>
      </div>
      <h3 id={`offer-${offer.id}`}>{offer.mode === "plateau" ? "Transport plateau" : "Convoyage"} · {offer.vehicle?.model}</h3>
      <p className="od-offer-pay">{formatCents(offer.partner_pay_cents)}</p>
      <p className="muted">Votre rémunération pour cette mission.</p>
      <div className="od-route">
        <div><strong>Prise en charge</strong><br />{offer.pickup.label}<br /><small className="muted">{formatDateTime(offer.pickup_at)} · {SLOTS.find((s) => s.value === offer.schedule?.slot)?.label}{offer.schedule?.flexibility_days ? ` · souplesse ± ${offer.schedule.flexibility_days} j` : ""}</small></div>
        <div><strong>Livraison</strong><br />{offer.delivery.label}</div>
      </div>
      <p>{offer.distance_km ? `${offer.distance_km} km` : ""}{offer.duration_min ? ` · environ ${Math.floor(offer.duration_min / 60)} h ${String(offer.duration_min % 60).padStart(2, "0")} de route` : ""}</p>
      <p>Véhicule : {VEHICLE_CLASSES.find((c) => c.value === offer.vehicle?.class)?.label} · {offer.vehicle?.rolling ? "roulant" : "non roulant"}{offer.vehicle?.category === "luxury" ? " · prestige" : ""}</p>
      {constraints.length > 0 && <p>Contraintes : {constraints.join(", ")}</p>}
      {offer.vehicle?.notes && <p className="muted">« {offer.vehicle.notes} »</p>}
      <div className="od-two">
        <div><strong>Inclus</strong><ul>{offer.partner_included.map((x) => <li key={x}>{x}</li>)}</ul></div>
        <div><strong>À savoir</strong><ul>{offer.partner_excluded.map((x) => <li key={x}>{x}</li>)}</ul></div>
      </div>
      {available && (
        <p className="muted">
          Proposition envoyée à tous les transporteurs compatibles : elle disparaît dès qu’elle est attribuée.
          À accepter avant le {formatDateTime(offer.expires_at)}.
        </p>
      )}
      {result && <div className={`alert ${result === "confirmed" ? "success" : result === "pending_capture" ? "" : "error"}`} role="status">{RESULT_TEXT[result] || RESULT_TEXT.unavailable}</div>}
      {error && <div className="alert error">{error}</div>}
      <div className="actions-row">
        {available && !result && <button className="btn primary" type="button" disabled={busy} onClick={accept}>{busy ? "Envoi…" : "Accepter"}</button>}
        {available && !result && <button className="btn ghost" type="button" disabled={busy} onClick={decline}>Refuser</button>}
        <button className="btn ghost" type="button" onClick={onClose}>{available && !result ? "Plus tard" : "Fermer"}</button>
      </div>
    </div>
  );
}

// ---------------------------------------------------------------------------
// Liste des propositions reçues.
// ---------------------------------------------------------------------------
export function OffersPanel({ focusOfferId, onOpenMission }) {
  const [offers, setOffers] = useState(null);
  const [open, setOpen] = useState(focusOfferId || null);
  const [error, setError] = useState("");

  const load = useCallback(() => myOffers().then((list) => { setOffers(list); setError(""); }).catch((e) => setError(humanizeError(e))), []);
  useEffect(() => { queueMicrotask(load); const id = setInterval(() => document.visibilityState === "visible" && load(), 20000); return () => clearInterval(id); }, [load]);
  useEffect(() => { if (focusOfferId) queueMicrotask(() => setOpen(focusOfferId)); }, [focusOfferId]);

  const available = (offers || []).filter((o) => o.state === "available" || o.state === "pending_capture");
  const past = (offers || []).filter((o) => !available.includes(o));
  return (
    <div className="panel panel-full">
      <h2>Missions proposées</h2>
      {error && <div className="alert error">{error}</div>}
      {offers === null && <p className="muted">Chargement…</p>}
      {offers && available.length === 0 && <div className="empty-state"><strong>Aucune mission disponible pour le moment</strong>Les propositions compatibles avec vos préférences apparaissent ici.</div>}
      <div className="cards">
        {available.map((o) => (
          <article className="mission-card" key={o.id}>
            <div className="card-top"><span className="badge">{o.mode === "plateau" ? "Plateau" : "Convoyage"}</span><strong>{formatCents(o.partner_pay_cents)}</strong></div>
            <h3>{o.pickup.city} → {o.delivery.city}</h3>
            <p>{o.vehicle?.model} · {formatDateTime(o.pickup_at)}{o.distance_km ? ` · ${o.distance_km} km` : ""}</p>
            <div className="actions-row"><button className="btn primary small" type="button" onClick={() => setOpen(o.id)}>Voir la mission</button></div>
          </article>
        ))}
      </div>
      {past.length > 0 && (
        <div className="applications-box">
          <h4>Propositions récentes</h4>
          <ul className="od-lines">{past.slice(0, 15).map((o) => (
            <li key={o.id}><span>{o.pickup.city} → {o.delivery.city} · {formatCents(o.partner_pay_cents)}</span><span>{o.state === "confirmed" ? "Confirmée pour vous" : o.state === "already_assigned" ? "Attribuée" : o.state === "declined" ? "Refusée" : "Expirée"}</span></li>
          ))}</ul>
        </div>
      )}
      {open && (
        <div className="od-offer-backdrop" onClick={(e) => { if (e.target === e.currentTarget) { setOpen(null); load(); } }}>
          <OfferDetail offerId={open} onClose={() => { setOpen(null); load(); }} onConfirmed={(o) => { load(); onOpenMission?.(o?.mission_id); }} />
        </div>
      )}
    </div>
  );
}

// ---------------------------------------------------------------------------
// Popup quand l'application est ouverte : nouvelle proposition en temps réel.
// ---------------------------------------------------------------------------
export function OfferPopupHost({ accountId, suppressed = false, onOpenMission }) {
  const [offerId, setOfferId] = useState(null);
  const shownRef = useRef(new Set());

  useEffect(() => {
    if (!accountId) return undefined;
    const channel = supabase
      .channel(`secoto-offers-${accountId}`)
      .on("postgres_changes", { event: "INSERT", schema: "public", table: "notifications", filter: `account_id=eq.${accountId}` }, async (message) => {
        const row = message.new;
        if (row?.type !== "mission_offer" || !row.ref_id || shownRef.current.has(row.ref_id)) return;
        const offer = await getOffer(row.ref_id).catch(() => null);
        if (offer?.state === "available") { shownRef.current.add(row.ref_id); setOfferId(row.ref_id); }
      })
      .subscribe();
    return () => { supabase.removeChannel(channel); };
  }, [accountId]);

  if (!offerId || suppressed) return null;
  return (
    <div className="od-offer-backdrop" onClick={(e) => { if (e.target === e.currentTarget) setOfferId(null); }}>
      <OfferDetail offerId={offerId} onClose={() => setOfferId(null)} onConfirmed={(o) => { setOfferId(null); onOpenMission?.(o?.mission_id); }} />
    </div>
  );
}
