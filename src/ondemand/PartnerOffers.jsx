import { humanizeError } from "../lib/humanError";
import { useCallback, useEffect, useRef, useState } from "react";
import { supabase } from "../supabaseClient";
import {
  VEHICLE_CLASSES, VEHICLE_CONSTRAINTS, SLOTS,
  acceptOffer, carrierDirectStatus, declineOffer, formatCents, formatDateTime,
  getOffer, markOfferSeen, myDispatchPreferences, myOffers, updateDispatchPreferences,
  OFFRE_LIBELLE, setAccepteDelaiLong, mesReglements, declarerEspeces,
} from "../lib/onDemand";
import { payCommission } from "../lib/payments";

// 099 : offre de la mission (Express, Standard, Éco) — jamais le prix client.
function OffreBadge({ offre }) {
  if (!offre) return null;
  return <span className={`od-pill od-offre-pill is-${offre}`}>{offre === "express" ? "Express · prioritaire" : offre === "eco" ? "Éco · délai long" : OFFRE_LIBELLE[offre] || offre}</span>;
}
import { randomIdempotencyKey } from "../lib/fileSafety";

// 100 : règlement en espèces à la livraison — ce que le transporteur encaisse et reverse.
function EspecesInfo({ offer }) {
  if (offer?.mode_reglement !== "especes") return null;
  return (
    <div className="alert" role="note">
      <strong>Règlement en espèces à la livraison.</strong> Vous encaissez {formatCents(offer.especes_a_encaisser_cents)} auprès du client,
      dont {formatCents(offer.commission_a_reverser_cents)} de marge SECOTO à reverser sous 7 jours (carte ou virement, depuis l’application).
      Votre rémunération reste de {formatCents(offer.partner_pay_cents)}.
    </div>
  );
}

// ---------------------------------------------------------------------------
// 100 : règlements en espèces à confirmer et marges SECOTO dues.
// ---------------------------------------------------------------------------
export function ReglementsPanel() {
  const [data, setData] = useState(null);
  const [busy, setBusy] = useState(null);
  const [error, setError] = useState("");
  const [message, setMessage] = useState("");
  const load = useCallback(() => mesReglements().then((d) => { setData(d); }).catch(() => setData(null)), []);
  useEffect(() => { queueMicrotask(load); }, [load]);

  if (!data || (!data.especes_a_declarer?.length && !data.commissions?.length && !data.bloque)) return null;

  async function declarer(item, recu) {
    const question = recu
      ? `Confirmez-vous avoir reçu ${formatCents(item.montant_cents)} en espèces pour la commande ${item.public_ref} ?`
      : `Confirmez-vous ne PAS avoir reçu le paiement de la commande ${item.public_ref} ? La carte du client sera prélevée.`;
    if (!window.confirm(question)) return;
    setBusy(item.order_id); setError(""); setMessage("");
    try {
      const r = await declarerEspeces(item.order_id, recu);
      setMessage(r?.result === "recu"
        ? `Merci. Marge SECOTO à régler : ${formatCents(r.commission_cents)}.`
        : "C’est noté : SECOTO s’occupe du paiement du client. Votre versement suit dès l’encaissement.");
      await load();
    } catch (e) { setError(humanizeError(e)); } finally { setBusy(null); }
  }

  async function payer(c) {
    setBusy(c.id); setError("");
    try { await payCommission(c.id); } catch (e) { setError(humanizeError(e)); setBusy(null); }
  }

  return (
    <div className="panel panel-full od-reglements">
      <h2>Règlements</h2>
      {data.bloque && (
        <div className="alert error" role="alert">
          Une marge SECOTO est en retard : les nouvelles missions sont suspendues jusqu’au paiement. Elle sera aussi retenue sur votre prochain versement.
        </div>
      )}
      {error && <div className="alert error">{error}</div>}
      {message && <div className="alert success">{message}</div>}
      {data.especes_a_declarer?.map((x) => (
        <article className="mission-card" key={x.order_id}>
          <div className="card-top"><span className="badge">{x.public_ref}</span><span className="od-pill is-warn">Espèces à confirmer</span></div>
          <p>Le client devait vous régler <strong>{formatCents(x.montant_cents)}</strong> en espèces à la livraison.</p>
          <div className="actions-row">
            <button className="btn primary small" type="button" disabled={busy === x.order_id} onClick={() => declarer(x, true)}>J’ai reçu {formatCents(x.montant_cents)}</button>
            <button className="btn ghost small" type="button" disabled={busy === x.order_id} onClick={() => declarer(x, false)}>Je n’ai pas été payé</button>
          </div>
        </article>
      ))}
      {data.commissions?.map((c) => (
        <article className="mission-card od-commission-due" key={c.id}>
          <div className="card-top"><span className="badge">{c.public_ref}</span><strong className="od-commission-montant">−{formatCents(c.reste_cents)}</strong></div>
          <p>Dû à SECOTO (marge de la course réglée en espèces){c.due_at ? ` · avant le ${formatDateTime(c.due_at)}` : ""}.</p>
          <div className="actions-row">
            <button className="btn primary small" type="button" disabled={busy === c.id} onClick={() => payer(c)}>{busy === c.id ? "Ouverture…" : `Payer ${formatCents(c.reste_cents)}`}</button>
          </div>
          {data.virement && (
            <p className="muted">Ou par virement : {data.virement.titulaire} · IBAN <code>{data.virement.iban}</code>{data.virement.bic ? ` · BIC ${data.virement.bic}` : ""} · référence <code>{c.reference}</code>.</p>
          )}
        </article>
      ))}
    </div>
  );
}

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
  // 074 : paiement direct (plateau).
  payment_account_required: "Pour accepter les missions plateau, activez d’abord le paiement direct : le client vous paie directement, SECOTO ne garde que ses frais.",
  needs_action: "Mission réservée pour vous : le client valide son paiement. Vous êtes prévenu dès que c’est fait.",
};

// ---------------------------------------------------------------------------
// Préférences : aucune obligation d'horaire, de connexion ou d'acceptation.
// ---------------------------------------------------------------------------
export function DispatchPreferencesPanel({ transporterType }) {
  const [prefs, setPrefs] = useState(null);
  const [busy, setBusy] = useState(false);
  const [message, setMessage] = useState("");
  const [error, setError] = useState("");

  useEffect(() => {
    myDispatchPreferences()
      .then((p) => { setPrefs(p); })
      .catch((e) => setError(humanizeError(e)));
  }, []);

  async function save(patch = {}) {
    setBusy(true); setError(""); setMessage("");
    try {
      // 088 : aucune sectorisation, les missions viennent de toute la France.
      const next = await updateDispatchPreferences({ ...prefs, ...patch, zones: [] });
      setPrefs(next);
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
      {transporterType === "pl" && (
        <div className="od-choice" style={{ marginTop: 12 }}>
          <label className={prefs.accepte_delai_long ? "is-selected" : ""}>
            <input type="checkbox" checked={Boolean(prefs.accepte_delai_long)} disabled={busy} onChange={async (e) => {
              const v = e.target.checked;
              setBusy(true); setError(""); setMessage("");
              try { await setAccepteDelaiLong(v); setPrefs((p) => ({ ...p, accepte_delai_long: v })); setMessage("Préférences enregistrées."); }
              catch (err) { setError(humanizeError(err)); } finally { setBusy(false); }
            }} />
            <span><strong>J’accepte les missions à délai long / groupage</strong><small>Missions « Éco » : voitures à charger sur porte-voitures, prise en charge dans une fenêtre de plusieurs jours, rémunération fixe par véhicule.</small></span>
          </label>
        </div>
      )}
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
        <p className="field-full muted" style={{ margin: 0 }}>Vous recevez les missions de toute la France, selon votre type de véhicule.</p>
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
export function OfferDetail({ offerId, onClose, onConfirmed, onOpenBank }) {
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
      <EspecesInfo offer={offer} />
      {offer.offre && (
        <p><OffreBadge offre={offer.offre} />{offer.fenetre_fin ? ` Fenêtre de prise en charge : du ${formatDateTime(offer.pickup_at)} au ${formatDateTime(offer.fenetre_fin)}.` : ""}</p>
      )}
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
      {result && <div className={`alert ${result === "confirmed" ? "success" : ["pending_capture", "needs_action"].includes(result) ? "" : "error"}`} role="status">{RESULT_TEXT[result] || RESULT_TEXT.unavailable}</div>}
      {result === "payment_account_required" && onOpenBank && (
        <div className="actions-row"><button className="btn primary small" type="button" onClick={onOpenBank}>Activer le paiement direct</button></div>
      )}
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
// 101 : autresMissions = missions publiées affichées juste au-dessus, dans le
// même onglet « Missions disponibles » (pas d'état vide ni de titre en double).
export function OffersPanel({ focusOfferId, onOpenMission, onOpenBank, paiementDirect = false, autresMissions = 0 }) {
  const [offers, setOffers] = useState(null);
  const [open, setOpen] = useState(focusOfferId || null);
  const [error, setError] = useState("");

  const load = useCallback(() => myOffers().then((list) => { setOffers(list); setError(""); }).catch((e) => setError(humanizeError(e))), []);
  // 074 : un transporteur plateau sans paiement direct voit les missions mais
  // ne peut pas les accepter : on le lui dit avant qu'il essaie.
  const [direct, setDirect] = useState(null);
  useEffect(() => {
    if (!paiementDirect) return;
    carrierDirectStatus().then(setDirect).catch(() => setDirect(null));
  }, [paiementDirect]);
  useEffect(() => { queueMicrotask(load); const id = setInterval(() => document.visibilityState === "visible" && load(), 20000); return () => clearInterval(id); }, [load]);
  useEffect(() => { if (focusOfferId) queueMicrotask(() => setOpen(focusOfferId)); }, [focusOfferId]);

  // 099 : les missions Express sont mises en avant (en tête de liste).
  const available = (offers || []).filter((o) => o.state === "available" || o.state === "pending_capture")
    .sort((a, b) => (b.offre === "express") - (a.offre === "express"));
  const past = (offers || []).filter((o) => !available.includes(o));
  return (
    <>
    <ReglementsPanel />
    <div className="panel panel-full">
      <h2>{autresMissions > 0 ? "Autres propositions" : "Missions disponibles"}</h2>
      {error && <div className="alert error">{error}</div>}
      {direct && !direct.ready && available.some((o) => o.mode === "plateau") && (
        <div className="alert" role="status">
          Pour accepter les missions plateau, activez le paiement direct : le client vous paie directement, SECOTO ne garde que ses frais.
          {onOpenBank && <div className="actions-row"><button className="btn primary small" type="button" onClick={onOpenBank}>Activer le paiement direct</button></div>}
        </div>
      )}
      {offers === null && <p className="muted">Chargement…</p>}
      {offers && available.length === 0 && autresMissions === 0 && <div className="empty-state"><strong>Aucune mission disponible pour le moment</strong>Les propositions compatibles avec vos préférences apparaissent ici.</div>}
      {offers && available.length === 0 && autresMissions > 0 && <p className="muted">Aucune autre proposition pour le moment.</p>}
      <div className="cards">
        {available.map((o) => (
          <article className="mission-card" key={o.id}>
            <div className="card-top"><span className="badge">{o.mode === "plateau" ? "Plateau" : "Convoyage"}</span>{o.offre && <OffreBadge offre={o.offre} />}{o.mode_reglement === "especes" && <span className="od-pill is-warn">Espèces</span>}<strong>{formatCents(o.partner_pay_cents)}</strong></div>
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
          <OfferDetail offerId={open} onOpenBank={onOpenBank} onClose={() => { setOpen(null); load(); }} onConfirmed={(o) => { load(); onOpenMission?.(o?.mission_id); }} />
        </div>
      )}
    </div>
    </>
  );
}

// ---------------------------------------------------------------------------
// Popup quand l'application est ouverte : nouvelle proposition en temps réel.
// ---------------------------------------------------------------------------
export function OfferPopupHost({ accountId, suppressed = false, onOpenMission, onOpenBank }) {
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
      <OfferDetail offerId={offerId} onOpenBank={onOpenBank ? () => { setOfferId(null); onOpenBank(); } : undefined} onClose={() => setOfferId(null)} onConfirmed={(o) => { setOfferId(null); onOpenMission?.(o?.mission_id); }} />
    </div>
  );
}
