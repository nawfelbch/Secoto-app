// ============================================================================
// SECOTO — pilotage administrateur d'une mission.
// ----------------------------------------------------------------------------
// Tout ce qui permet de traiter une mission recue PAR TELEPHONE, sans rien
// changer au parcours habituel :
//   · choisir soi-meme le transporteur, sans passer par une candidature ;
//   · imposer la remuneration du transporteur ET la marge SECOTO ;
//   · fixer l'etape de la mission ;
//   · deposer le devis deja signe ;
//   · enregistrer une commission encaissee hors application ;
//   · envoyer au client un SMS deja redige a partir de la fiche.
// ============================================================================

import { useMemo, useState } from "react";
import SecureFilePicker from "./SecureFilePicker";
import { MISSION_STAGES } from "./lib/mappers";
import {
  computeCarrierPay,
  computeClientTotalDue,
  computeMargin,
  formatAmount,
  isManualPricing,
  suggestedMargin,
} from "./lib/pricing";
import {
  buildClientAssignmentMessage,
  buildSmsUrl,
  copyToClipboard,
  displayPhone,
  normalizePhone,
} from "./lib/missionMessage";
import { openExternal } from "./platform/runtime";

function toAmountInput(value) {
  if (value === null || value === undefined || value === "") return "";
  const n = Number(value);
  return Number.isFinite(n) ? String(n) : "";
}

function parseAmount(value) {
  const n = Number(String(value).replace(",", "."));
  return Number.isFinite(n) && n >= 0 ? Math.round(n * 100) / 100 : null;
}

/* ------------------------------------------------------------------ */
/* Saisie des deux montants                                            */
/* ------------------------------------------------------------------ */
export function ManualPricingFields({ draft, onChange, type, disabled = false }) {
  const carrier = parseAmount(draft.carrierPay);
  const margin = parseAmount(draft.margin);
  const total = carrier === null || margin === null ? null : Math.round((carrier + margin) * 100) / 100;

  return (
    <>
      <label className="field">
        <span>Rémunération du {type === "plateau" ? "transporteur" : "convoyeur"} €</span>
        <input
          type="number"
          min="0"
          step="0.01"
          inputMode="decimal"
          value={draft.carrierPay}
          disabled={disabled}
          placeholder="Ce que SECOTO lui verse"
          onChange={(event) => onChange({ carrierPay: event.target.value })}
        />
      </label>
      <label className="field">
        <span>Marge SECOTO €</span>
        <input
          type="number"
          min="0"
          step="0.01"
          inputMode="decimal"
          value={draft.margin}
          disabled={disabled}
          placeholder="Librement fixée, pas forcément 20 %"
          onChange={(event) => onChange({ margin: event.target.value })}
        />
      </label>
      <p className="muted field-full" style={{ margin: "2px 0 6px" }}>
        {total === null
          ? "Renseignez les deux montants."
          : type === "plateau"
            ? `Le client règle ${formatAmount(total)} : ${formatAmount(carrier)} de transport `
              + `+ ${formatAmount(margin)} de frais SECOTO.`
            : `Prix client ${formatAmount(total)}, dont ${formatAmount(margin)} de marge SECOTO.`}
      </p>
    </>
  );
}

/* ------------------------------------------------------------------ */
/* Attribution : depuis une candidature OU en choisissant soi-meme      */
/* ------------------------------------------------------------------ */
export function AssignmentPanel({
  mission,
  transporters,
  application = null,
  busy = false,
  onAssign,
}) {
  // Les valeurs proposées reproduisent EXACTEMENT ce que la mission vaudrait
  // sans intervention : attribuer sans rien changer donne le même résultat
  // qu'avant. L'administrateur n'a qu'à corriger ce qu'il veut corriger.
  //  · depuis une candidature : le tarif proposé, et 20 % de marge ;
  //  · sans candidature       : le barème actuel de la mission.
  // La case n'est cochée d'office que lorsque les deux montants coïncident
  // avec le calcul automatique — jamais pour un convoyage repris d'une
  // candidature, où le barème doit rester maître tant qu'on ne le dit pas.
  const defaultCarrier = application
    ? toAmountInput(application.proposedPrice)
    : toAmountInput(mission.manualCarrierPay ?? computeCarrierPay(mission));
  const defaultMargin = application
    ? toAmountInput(suggestedMargin(application.proposedPrice))
    : toAmountInput(mission.manualMargin ?? computeMargin(mission));

  const [draft, setDraft] = useState(() => ({
    transporterId: application ? application.transporterId : "",
    carrierPay: defaultCarrier,
    margin: defaultMargin,
    manual: application ? mission.type === "plateau" : true,
  }));

  function update(patch) {
    setDraft((previous) => {
      const next = { ...previous, ...patch };
      // La marge suit le tarif tant que l'administrateur ne l'a pas touchée.
      if (patch.carrierPay !== undefined && !previous.marginTouched) {
        next.margin = toAmountInput(suggestedMargin(parseAmount(patch.carrierPay) || 0));
      }
      if (patch.margin !== undefined) next.marginTouched = true;
      return next;
    });
  }

  const eligible = useMemo(
    () => (transporters || []).filter((t) => t.role === "transporter"),
    [transporters],
  );

  const carrier = parseAmount(draft.carrierPay);
  const margin = parseAmount(draft.margin);
  const blocked = busy
    || (!application && !draft.transporterId)
    || (draft.manual && (carrier === null || margin === null));

  return (
    <div className="card-section" style={{ marginTop: 10 }}>
      <div className="form-grid">
        {!application && (
          <label className="field field-full">
            <span>Transporteur choisi par SECOTO</span>
            <select
              value={draft.transporterId}
              disabled={busy}
              onChange={(event) => update({ transporterId: event.target.value })}
            >
              <option value="">— Sélectionner —</option>
              {eligible.map((t) => (
                <option key={t.id} value={t.id}>
                  {(t.fullName || t.companyName || "Transporteur")}
                  {t.companyName && t.fullName ? ` — ${t.companyName}` : ""}
                  {t.isVerified ? "" : " (non vérifié)"}
                </option>
              ))}
            </select>
          </label>
        )}

        <label className="field field-full" style={{ flexDirection: "row", alignItems: "center", gap: 8 }}>
          <input
            type="checkbox"
            checked={draft.manual}
            disabled={busy}
            onChange={(event) => update({ manual: event.target.checked })}
          />
          <span style={{ margin: 0 }}>Fixer moi-même les montants</span>
        </label>

        {draft.manual && (
          <ManualPricingFields
            draft={draft}
            onChange={update}
            type={mission.type}
            disabled={busy}
          />
        )}

        <button
          className="btn primary small field-full"
          type="button"
          disabled={blocked}
          onClick={() => onAssign({
            transporterId: application ? application.transporterId : draft.transporterId,
            application,
            manualPricing: draft.manual,
            carrierPay: carrier,
            margin,
          })}
        >
          {application ? "Attribuer à ce transporteur" : "Attribuer directement"}
        </button>
      </div>
    </div>
  );
}

/* ------------------------------------------------------------------ */
/* Montants d'une mission deja attribuee                                */
/* ------------------------------------------------------------------ */
export function PricingEditor({ mission, busy = false, onSave }) {
  const [draft, setDraft] = useState(() => ({
    carrierPay: toAmountInput(mission.manualCarrierPay ?? computeCarrierPay(mission)),
    margin: toAmountInput(mission.manualMargin ?? computeMargin(mission)),
    manual: isManualPricing(mission),
  }));

  // Quand la mission change (rechargement après enregistrement), le brouillon
  // repart des valeurs de la base. Ajustement pendant le rendu, comme le
  // recommande React, plutôt qu'un effet qui provoquerait un rendu en cascade.
  const pricingSignature = [
    mission.id, mission.manualPricing, mission.manualCarrierPay, mission.manualMargin,
  ].join("|");
  const [pricingSeen, setPricingSeen] = useState(pricingSignature);
  if (pricingSeen !== pricingSignature) {
    setPricingSeen(pricingSignature);
    setDraft({
      carrierPay: toAmountInput(mission.manualCarrierPay ?? computeCarrierPay(mission)),
      margin: toAmountInput(mission.manualMargin ?? computeMargin(mission)),
      manual: isManualPricing(mission),
    });
  }

  const carrier = parseAmount(draft.carrierPay);
  const margin = parseAmount(draft.margin);

  return (
    <div className="card-section" style={{ marginTop: 10 }}>
      <div className="form-grid">
        <label className="field field-full" style={{ flexDirection: "row", alignItems: "center", gap: 8 }}>
          <input
            type="checkbox"
            checked={draft.manual}
            disabled={busy}
            onChange={(event) => setDraft((p) => ({ ...p, manual: event.target.checked }))}
          />
          <span style={{ margin: 0 }}>Montants imposés par SECOTO</span>
        </label>

        {draft.manual && (
          <ManualPricingFields
            draft={draft}
            onChange={(patch) => setDraft((p) => ({ ...p, ...patch }))}
            type={mission.type}
            disabled={busy}
          />
        )}

        {!draft.manual && (
          <p className="muted field-full" style={{ margin: "2px 0 6px" }}>
            Barème automatique : {formatAmount(computeCarrierPay(mission))} pour le transporteur,{" "}
            {formatAmount(computeMargin(mission))} de marge SECOTO.
          </p>
        )}

        <button
          className="btn primary small field-full"
          type="button"
          disabled={busy || (draft.manual && (carrier === null || margin === null))}
          onClick={() => onSave({ manualPricing: draft.manual, carrierPay: carrier, margin })}
        >
          Enregistrer les montants
        </button>
      </div>
    </div>
  );
}

/* ------------------------------------------------------------------ */
/* Etape de la mission                                                  */
/* ------------------------------------------------------------------ */
export function StagePicker({ mission, busy = false, onSetStage }) {
  const current = MISSION_STAGES.findIndex(
    (stage) => stage.status === mission.status
      && stage.progressStatus === (mission.progressStatus || "assigned_pending"),
  );
  const [index, setIndex] = useState(current >= 0 ? String(current) : "");

  const stageSignature = `${mission.id}|${mission.status}|${mission.progressStatus || ""}`;
  const [stageSeen, setStageSeen] = useState(stageSignature);
  if (stageSeen !== stageSignature) {
    setStageSeen(stageSignature);
    setIndex(current >= 0 ? String(current) : "");
  }

  const selected = MISSION_STAGES[Number(index)] || null;
  const nextStage = current >= 0 && current < MISSION_STAGES.length - 2
    ? MISSION_STAGES[current + 1]
    : null;

  return (
    <div className="card-section" style={{ marginTop: 10 }}>
      <div className="form-grid">
        <label className="field field-full">
          <span>Étape de la mission</span>
          <select value={index} disabled={busy} onChange={(event) => setIndex(event.target.value)}>
            <option value="">— Étape actuelle non reconnue —</option>
            {MISSION_STAGES.map((stage, i) => (
              <option key={`${stage.status}-${stage.progressStatus}`} value={String(i)}>
                {stage.label}
              </option>
            ))}
          </select>
        </label>
        <div className="actions-row field-full">
          <button
            className="btn ghost small"
            type="button"
            disabled={busy || !selected}
            onClick={() => onSetStage(selected)}
          >
            Appliquer l’étape
          </button>
          {nextStage && (
            <button
              className="btn primary small"
              type="button"
              disabled={busy}
              onClick={() => onSetStage(nextStage)}
            >
              Passer à : {nextStage.label}
            </button>
          )}
        </div>
      </div>
    </div>
  );
}

/* ------------------------------------------------------------------ */
/* SMS client pre-rempli                                                */
/* ------------------------------------------------------------------ */
export function ClientSmsPanel({ mission, transporter = null, trackingUrl = "", onNotice, onError }) {
  const [message, setMessage] = useState(() =>
    buildClientAssignmentMessage(mission, transporter, { trackingUrl }));
  const [copied, setCopied] = useState(false);

  // Le texte est recalculé dès que la fiche change, sauf si l'administrateur
  // l'a lui-même modifié depuis la dernière mise à jour de la mission.
  const messageSignature = [
    mission.id, mission.assignedTransporterName, mission.manualPricing,
    mission.manualCarrierPay, mission.manualMargin, mission.carrierCost,
    mission.missionDate, trackingUrl,
  ].join("|");
  const [messageSeen, setMessageSeen] = useState(messageSignature);
  if (messageSeen !== messageSignature) {
    setMessageSeen(messageSignature);
    setMessage(buildClientAssignmentMessage(mission, transporter, { trackingUrl }));
    setCopied(false);
  }

  const phone = normalizePhone(mission.clientPhone);

  async function send() {
    try {
      await openExternal(buildSmsUrl(mission.clientPhone, message));
    } catch (error) {
      onError?.(error?.message || "Impossible d’ouvrir l’application Messages.");
    }
  }

  return (
    <div className="card-section" style={{ marginTop: 10 }}>
      <p className="muted" style={{ marginTop: 0 }}>
        Message prêt pour {displayPhone(mission.clientPhone) || "le client"}
        {phone ? "" : " — aucun numéro sur la fiche, le message s’ouvrira sans destinataire."}
      </p>
      <textarea
        value={message}
        rows={8}
        onChange={(event) => { setMessage(event.target.value); setCopied(false); }}
        style={{ width: "100%" }}
      />
      <div className="actions-row" style={{ marginTop: 8, flexWrap: "wrap" }}>
        <button className="btn primary small" type="button" onClick={send}>
          Envoyer par SMS
        </button>
        <button
          className="btn ghost small"
          type="button"
          onClick={async () => {
            const ok = await copyToClipboard(message);
            setCopied(ok);
            if (ok) onNotice?.("Message copié.");
            else onError?.("Copie impossible : sélectionnez le texte à la main.");
          }}
        >
          {copied ? "Message copié" : "Copier le message"}
        </button>
        {phone && (
          <a className="btn ghost small" href={`tel:${phone}`}>Appeler</a>
        )}
      </div>
    </div>
  );
}

/* ------------------------------------------------------------------ */
/* Depot du devis deja signe                                            */
/* ------------------------------------------------------------------ */
export function SignedDevisUploader({ mission, busy = false, progress = null, onUpload }) {
  const [files, setFiles] = useState([]);

  return (
    <div className="card-section" style={{ marginTop: 10 }}>
      <SecureFilePicker
        files={files}
        onChange={setFiles}
        label="Devis signé (PDF ou photo)"
        allowPdf
        maxFiles={1}
        disabled={busy}
        progress={progress}
      />
      <button
        className="btn primary small"
        type="button"
        style={{ marginTop: 8 }}
        disabled={busy || files.length !== 1}
        onClick={async () => {
          const ok = await onUpload(files[0]);
          if (ok) setFiles([]);
        }}
      >
        Enregistrer le devis signé
      </button>
      {mission.offlineSigned && (
        <p className="muted" style={{ marginBottom: 0 }}>
          Devis signé hors application déjà enregistré sur cette mission.
        </p>
      )}
    </div>
  );
}

/* ------------------------------------------------------------------ */
/* Panneau complet                                                      */
/* ------------------------------------------------------------------ */
export default function AdminMissionPilot({
  mission,
  transporters,
  busy = false,
  uploadProgress = null,
  trackingUrl = "",
  onAssignDirect,
  onSavePricing,
  onSetStage,
  onReopenStep,
  onUploadSignedDevis,
  onSettleCommission,
  onNotice,
  onError,
}) {
  const [open, setOpen] = useState(false);
  const transporter = (transporters || []).find((t) => t.id === mission.assignedTransporterId) || null;
  const assigned = Boolean(mission.assignedTransporterId);

  return (
    <div className="applications-box" style={{ marginTop: 12 }}>
      <button
        className="btn ghost small"
        type="button"
        onClick={() => setOpen((v) => !v)}
      >
        {open ? "Fermer le pilotage SECOTO" : "Piloter cette mission (téléphone, tarifs, étape)"}
      </button>

      {open && (
        <>
          {!assigned && (
            <>
              <h4 style={{ marginBottom: 0 }}>Attribuer sans candidature</h4>
              <AssignmentPanel
                mission={mission}
                transporters={transporters}
                busy={busy}
                onAssign={onAssignDirect}
              />
            </>
          )}

          {assigned && (
            <>
              <h4 style={{ marginBottom: 0 }}>Montants de la mission</h4>
              <PricingEditor mission={mission} busy={busy} onSave={onSavePricing} />
            </>
          )}

          <h4 style={{ marginBottom: 0 }}>Étape</h4>
          <StagePicker mission={mission} busy={busy} onSetStage={onSetStage} />

          {assigned && onReopenStep && (
            <>
              <h4 style={{ marginBottom: 0 }}>Rendre la main au transporteur</h4>
              <p className="muted" style={{ marginTop: 4 }}>
                À utiliser quand un état des lieux est raté, incomplet, ou quand
                la mission s’est retrouvée bloquée. Les photos déjà transmises
                sont conservées et restent consultables : elles cessent
                simplement de bloquer l’étape.
              </p>
              <div className="actions-row">
                <button
                  className="btn ghost small"
                  type="button"
                  disabled={busy}
                  onClick={() => onReopenStep("pickup")}
                >
                  Refaire l’état des lieux de départ
                </button>
                <button
                  className="btn ghost small"
                  type="button"
                  disabled={busy}
                  onClick={() => onReopenStep("delivery")}
                >
                  Refaire la livraison
                </button>
                <button
                  className="btn ghost small"
                  type="button"
                  disabled={busy}
                  onClick={() => onReopenStep("all")}
                >
                  Tout rouvrir
                </button>
              </div>
            </>
          )}

          <h4 style={{ marginBottom: 0 }}>Prévenir le client</h4>
          <ClientSmsPanel
            mission={mission}
            transporter={transporter}
            trackingUrl={trackingUrl}
            onNotice={onNotice}
            onError={onError}
          />

          <h4 style={{ marginBottom: 0 }}>Devis déjà signé</h4>
          <SignedDevisUploader
            mission={mission}
            busy={busy}
            progress={uploadProgress}
            onUpload={onUploadSignedDevis}
          />

          <h4 style={{ marginBottom: 0 }}>Règlement hors application</h4>
          <div className="card-section" style={{ marginTop: 10 }}>
            <p className="muted" style={{ marginTop: 0 }}>
              {mission.commissionSettledOffline
                ? "Règlement déjà enregistré hors application."
                : mission.type === "plateau"
                  ? "À utiliser quand la commission a été réglée par virement ou en espèces, "
                    + "hors de l’application : le bon de mission part alors au transporteur."
                  : "À utiliser quand le règlement s’est fait hors application : "
                    + "le bon de mission en attente est transmis au convoyeur."}
            </p>
            <button
              className="btn primary small"
              type="button"
              disabled={busy}
              onClick={() => onSettleCommission(mission)}
            >
              {mission.commissionSettledOffline
                ? "Réenregistrer le règlement"
                : "Règlement encaissé hors application"}
            </button>
          </div>

          <p className="muted" style={{ marginTop: 10, marginBottom: 0 }}>
            Total client actuel : <strong>{formatAmount(computeClientTotalDue(mission))}</strong>
            {" · "}Transporteur : {formatAmount(computeCarrierPay(mission))}
            {" · "}Marge SECOTO : {formatAmount(computeMargin(mission))}
          </p>
        </>
      )}
    </div>
  );
}
