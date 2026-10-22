// SECOTO 101 — Missions : pastille URGENT, modifications SECOTO, propositions.
// ----------------------------------------------------------------------------
// - SECOTO modifie client et trajet à tout moment (même après attribution) :
//   secoto_admin_update_mission, le transporteur attribué est prévenu.
// - Plateau : le transporteur propose UN prix et UNE date, modifiables tant
//   que SECOTO n'a pas tranché (secoto_mission_proposer). SECOTO peut aussi
//   corriger la proposition (secoto_admin_application_update).
// - Convoyage : le transporteur accepte la date renseignée, ou propose une
//   autre date (le prix reste celui du barème).
import { useState } from "react";
import { humanizeError } from "./lib/humanError";
import { toDateTimeLocal } from "./lib/applicationOffer";
import { formatDateTime } from "./lib/mappers";
import { modifierMissionAdmin, modifierPropositionAdmin, proposerMission } from "./lib/missionsPropositions";
import { CHAMPS, patchMission, valeurInitiale } from "./lib/missionPatch";

export function UrgentBadge({ mission }) {
  if (!mission?.urgent) return null;
  return <span className="urgent-badge" role="img" aria-label="Mission urgente">⚡ URGENT</span>;
}

export function MissionEditPanel({ mission, onSaved, onNotice, onError }) {
  const [ouvert, setOuvert] = useState(false);
  const [busy, setBusy] = useState(false);
  const [form, setForm] = useState(null);

  function ouvrir() {
    const f = { notes: mission.notes || "", urgent: Boolean(mission.urgent) };
    for (const [cle, , , type] of CHAMPS) f[cle] = valeurInitiale(mission, cle, type);
    setForm(f);
    setOuvert(true);
  }

  async function enregistrer(e) {
    e.preventDefault();
    const patch = patchMission(mission, form);
    if (!Object.keys(patch).length) { setOuvert(false); return; }
    setBusy(true);
    try {
      const r = await modifierMissionAdmin(mission.id, patch);
      setOuvert(false);
      const prevenu = mission.status === "assigned" && (r?.changements || []).length > 0;
      onNotice?.(prevenu ? "Mission mise à jour. Le transporteur a été prévenu." : "Mission mise à jour.");
      await onSaved?.();
    } catch (err) {
      onError?.(humanizeError(err, "La mission n’a pas pu être modifiée."));
    } finally {
      setBusy(false);
    }
  }

  if (mission.status === "cancelled") return null;
  if (!ouvert) {
    return (
      <div className="actions-row" style={{ marginTop: 8 }}>
        <button className="btn ghost small" type="button" onClick={ouvrir}>Modifier les infos client / trajet</button>
      </div>
    );
  }
  const set = (cle) => (e) => setForm((p) => ({ ...p, [cle]: e.target.type === "checkbox" ? e.target.checked : e.target.value }));
  return (
    <form className="applications-box form-grid mission-edit" onSubmit={enregistrer}>
      <h4 className="field-full">Modifier la mission {mission.publicRef}</h4>
      <label className="field field-full urgent-toggle">
        <input type="checkbox" checked={form.urgent} onChange={set("urgent")} />
        <span>⚡ Mission URGENTE (pastille visible par les transporteurs)</span>
      </label>
      {CHAMPS.map(([cle, , libelle, type]) => (
        <label className="field" key={cle}>
          <span>{libelle}</span>
          <input type={type || "text"} value={form[cle]} onChange={set(cle)} autoComplete="off" />
        </label>
      ))}
      <label className="field field-full">
        <span>Notes internes</span>
        <textarea value={form.notes} onChange={set("notes")} />
      </label>
      {mission.status === "assigned" && (
        <p className="muted field-full">Le transporteur attribué reçoit une notification avec la liste des changements.</p>
      )}
      <p className="muted field-full">Changer la distance recalcule les montants du barème (sauf montants fixés à la main).</p>
      <div className="actions-row field-full">
        <button className="btn primary small" type="submit" disabled={busy}>{busy ? "Enregistrement…" : "Enregistrer"}</button>
        <button className="btn ghost small" type="button" disabled={busy} onClick={() => setOuvert(false)}>Annuler</button>
      </div>
    </form>
  );
}

/** Ligne de candidature : date proposée, et correction par SECOTO tant qu'elle est en attente. */
export function PropositionAdmin({ mission, application, onSaved, onNotice, onError }) {
  const [ouvert, setOuvert] = useState(false);
  const [busy, setBusy] = useState(false);
  const [prix, setPrix] = useState("");
  const [date, setDate] = useState("");
  const plateau = mission.type === "plateau";
  const modifiable = mission.status === "published" && application.status === "pending";

  async function enregistrer() {
    setBusy(true);
    try {
      await modifierPropositionAdmin(application.id, { price: plateau ? prix : null, date });
      setOuvert(false);
      onNotice?.("Proposition modifiée.");
      await onSaved?.();
    } catch (err) {
      onError?.(humanizeError(err, "La proposition n’a pas pu être modifiée."));
    } finally {
      setBusy(false);
    }
  }

  return (
    <>
      {application.proposedDate && (
        <p className="price-line"><strong>Date proposée :</strong> {formatDateTime(application.proposedDate)}</p>
      )}
      {modifiable && !ouvert && (
        <button className="linklike" type="button" onClick={() => {
          setPrix(application.proposedPrice ? String(Number(application.proposedPrice)) : "");
          setDate(application.proposedDate ? toDateTimeLocal(application.proposedDate) : (mission.missionDate ? toDateTimeLocal(mission.missionDate) : ""));
          setOuvert(true);
        }}>
          Modifier {plateau ? "le prix / la date" : "la date"}
        </button>
      )}
      {ouvert && (
        <div className="proposition-edit">
          {plateau && (
            <label className="field"><span>Prix (€)</span>
              <input type="number" min="1" step="1" inputMode="decimal" value={prix} onChange={(e) => setPrix(e.target.value)} />
            </label>
          )}
          <label className="field"><span>Date</span>
            <input type="datetime-local" value={date} onChange={(e) => setDate(e.target.value)} />
          </label>
          <div className="actions-row">
            <button className="btn primary small" type="button" disabled={busy} onClick={enregistrer}>Enregistrer</button>
            <button className="btn ghost small" type="button" disabled={busy} onClick={() => setOuvert(false)}>Annuler</button>
          </div>
        </div>
      )}
    </>
  );
}

/**
 * Côté transporteur, sur une mission publiée.
 * Plateau : un prix + une date (modifiables tant que SECOTO n'a pas tranché).
 * Convoyage : « Accepter » la date renseignée, ou proposer une autre date.
 */
export function PropositionTransporteur(props) {
  // 114 : course issue d'une commande client : prix et date fixés, on accepte.
  return props.mission?.commande ? <CommandeAPrixFixe {...props} /> : <PropositionLibre {...props} />;
}

function CommandeAPrixFixe({ mission, disabled, onAccepter, onRefuser }) {
  return (
    <>
      <p className="od-offer-pay">{Number(mission.carrierPay || 0).toLocaleString("fr-FR", { style: "currency", currency: "EUR" })}</p>
      <p className="muted">
        Course réservée par un client, à prix fixe. Votre rémunération est versée sous 48 h après la livraison.
        Véhicule {mission.vehicleRolling === false ? "NON ROULANT" : "roulant"}.
      </p>
      <div className="actions-row">
        <button className="btn primary small" type="button" disabled={disabled} onClick={onAccepter}>
          {mission.missionDate ? `Accepter (enlèvement le ${formatDateTime(mission.missionDate)})` : "Accepter"}
        </button>
        <button className="btn ghost small" type="button" disabled={disabled} onClick={onRefuser}>Refuser</button>
      </div>
    </>
  );
}

function PropositionLibre({ mission, maProposition, disabled, onAccepter, onRefuser, onEnvoyee, onNotice, onError }) {
  const plateau = mission.type === "plateau";
  const enAttente = maProposition?.status === "pending";
  const [ouvert, setOuvert] = useState(plateau && !maProposition);
  const [busy, setBusy] = useState(false);
  const [prix, setPrix] = useState(maProposition?.proposedPrice && plateau ? String(Number(maProposition.proposedPrice)) : "");
  const [date, setDate] = useState(toDateTimeLocal(maProposition?.proposedDate || mission.missionDate || "") || "");
  const [message, setMessage] = useState(maProposition?.message || "");

  async function envoyer(e) {
    e?.preventDefault();
    setBusy(true);
    try {
      await proposerMission(mission.id, { price: plateau ? prix : null, date, message });
      setOuvert(false);
      onNotice?.(maProposition
        ? "Proposition modifiée. SECOTO est prévenu."
        : plateau
          ? "Proposition envoyée. SECOTO vous confirme l’attribution."
          : "Date proposée. SECOTO vous confirme l’attribution.");
      await onEnvoyee?.();
    } catch (err) {
      onError?.(humanizeError(err, "La proposition n’a pas pu être envoyée."));
    } finally {
      setBusy(false);
    }
  }

  const resume = maProposition && (
    <div className={`alert${enAttente ? "" : " success"}`} role="status">
      <strong>Votre proposition{enAttente ? " (en attente de SECOTO)" : ""} :</strong>{" "}
      {plateau && maProposition.proposedPrice ? `${Number(maProposition.proposedPrice).toLocaleString("fr-FR")} € · ` : ""}
      {maProposition.proposedDate ? formatDateTime(maProposition.proposedDate) : "date à confirmer"}
    </div>
  );

  const formulaire = (
    <form className="proposition-form" onSubmit={envoyer}>
      {plateau && (
        <label className="field">
          <span>Votre prix (€)</span>
          <input type="number" min="1" step="1" inputMode="decimal" required value={prix} onChange={(e) => setPrix(e.target.value)} placeholder="Ex : 650" />
        </label>
      )}
      <label className="field">
        <span>Votre date de disponibilité</span>
        <input type="datetime-local" required value={date} onChange={(e) => setDate(e.target.value)} />
      </label>
      <label className="field field-full">
        <span>Message pour SECOTO (facultatif)</span>
        <input type="text" maxLength={500} value={message} onChange={(e) => setMessage(e.target.value)} placeholder="Ex : course cumulable avec un retour" />
      </label>
      <div className="actions-row field-full">
        <button className="btn primary small" type="submit" disabled={disabled || busy}>
          {busy ? "Envoi…" : maProposition ? "Enregistrer la modification" : plateau ? "Envoyer ma proposition" : "Proposer cette date"}
        </button>
        {(maProposition || !plateau) && (
          <button className="btn ghost small" type="button" disabled={busy} onClick={() => setOuvert(false)}>Annuler</button>
        )}
      </div>
    </form>
  );

  if (plateau) {
    return (
      <>
        <p className="muted">Transport par plateau : indiquez votre prix et votre date de disponibilité. Un seul prix et une seule date par mission, modifiables tant que SECOTO n’a pas attribué.</p>
        {resume}
        {ouvert ? formulaire : (
          <div className="actions-row">
            {enAttente && <button className="btn primary small" type="button" disabled={disabled} onClick={() => setOuvert(true)}>Modifier ma proposition</button>}
            {!maProposition && <button className="btn primary small" type="button" disabled={disabled} onClick={() => setOuvert(true)}>Proposer mon prix</button>}
            {!maProposition && <button className="btn ghost small" type="button" disabled={disabled} onClick={onRefuser}>Refuser</button>}
          </div>
        )}
      </>
    );
  }

  return (
    <>
      <p className="od-offer-pay">{Number(mission.carrierPay || 0).toLocaleString("fr-FR", { style: "currency", currency: "EUR" })}</p>
      <p className="muted">
        Votre rémunération pour cette mission. Paiement déclenché sous 48 h après la livraison.
        Véhicule {mission.vehicleRolling === false ? "NON ROULANT" : "roulant"}.
      </p>
      {resume}
      {ouvert ? formulaire : (
        <div className="actions-row">
          {!enAttente && (
            <button className="btn primary small" type="button" disabled={disabled} onClick={onAccepter}>
              {mission.missionDate ? `Accepter le ${formatDateTime(mission.missionDate)}` : "Accepter"}
            </button>
          )}
          <button className="btn ghost small" type="button" disabled={disabled} onClick={() => setOuvert(true)}>
            {enAttente ? "Modifier ma date" : "Proposer une autre date"}
          </button>
          {!maProposition && <button className="btn ghost small" type="button" disabled={disabled} onClick={onRefuser}>Refuser</button>}
        </div>
      )}
    </>
  );
}
