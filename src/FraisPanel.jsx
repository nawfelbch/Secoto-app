/* eslint-disable react-hooks/set-state-in-effect */
import { useEffect, useRef, useState } from "react";
import {
  FRAIS_TYPES,
  listMyFrais,
  listAllFrais,
  createFrais,
  validateFrais,
  refuseFrais,
  justificatifUrl,
  totalRemboursable,
} from "./lib/frais";
import { formatAmount } from "./lib/pricing";
import { labelStatus } from "./lib/mappers";
import { supabase } from "./supabaseClient";
import SecureFilePicker from "./SecureFilePicker";
import { randomIdempotencyKey } from "./lib/fileSafety";
import { shareOrOpen } from "./platform/runtime";

const STATUT_LABEL = { en_attente: "En attente", valide: "Validé", refuse: "Refusé" };

/**
 * Panneau Frais réels.
 * - Transporteur : dépose un frais (montant + justificatif) et suit ses statuts.
 * - Admin : valide / refuse les frais avec aperçu du justificatif.
 */
export default function FraisPanel({ account, isAdmin, missions = [] }) {
  const [items, setItems] = useState([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState("");
  const [notice, setNotice] = useState("");

  // Formulaire transporteur
  const [missionId, setMissionId] = useState("");
  const [type, setType] = useState("essence");
  const [montant, setMontant] = useState("");
  const [files, setFiles] = useState([]);
  const [operationId, setOperationId] = useState(() => randomIdempotencyKey());
  const [uploadProgress, setUploadProgress] = useState(null);
  const [busy, setBusy] = useState(false);
  const busyRef = useRef(false);

  async function reload() {
    setLoading(true);
    setError("");
    try {
      setItems(isAdmin ? await listAllFrais() : await listMyFrais(account.id));
    } catch (e) {
      setError(e.message || "Chargement des frais impossible.");
    }
    setLoading(false);
  }

  useEffect(() => {
    reload();
    // Temps réel : un frais déposé par un transporteur apparaît immédiatement
    // côté admin, et le changement de statut remonte aussitôt au transporteur.
    const channel = supabase
      .channel(`frais-${isAdmin ? "admin" : account.id}`)
      .on("postgres_changes", { event: "*", schema: "public", table: "frais" }, () => { reload(); })
      .subscribe();
    return () => { supabase.removeChannel(channel); };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [isAdmin, account.id]);

  async function onSubmit(e) {
    e.preventDefault();
    if (busyRef.current) return;
    busyRef.current = true;
    setBusy(true);
    setError("");
    setNotice("");
    try {
      await createFrais({
        transporterId: account.id,
        missionId,
        type,
        montant,
        file: files[0],
        operationId,
        onProgress: setUploadProgress,
      });
      setNotice("Frais envoyé. En attente de validation SECOTO.");
      setMissionId(""); setType("essence"); setMontant(""); setFiles([]);
      setOperationId(randomIdempotencyKey());
      setUploadProgress(null);
      e.target.reset?.();
      await reload();
    } catch (err) {
      setError(err.message || "Envoi impossible.");
    }
    setBusy(false);
    busyRef.current = false;
  }

  async function onValidate(id) {
    setError("");
    try { await validateFrais(id); await reload(); }
    catch (e) { setError(e.message); }
  }

  async function onRefuse(id) {
    const motif = window.prompt("Motif du refus ?");
    if (motif === null) return;
    setError("");
    try { await refuseFrais(id, motif); await reload(); }
    catch (e) { setError(e.message); }
  }

  async function openJustificatif(path) {
    try {
      const url = await justificatifUrl(path);
      await shareOrOpen({
        title: "Justificatif SECOTO",
        text: "Justificatif privé — lien temporaire sécurisé",
        url,
      });
    } catch (e) {
      setError(e.message || "Justificatif indisponible.");
    }
  }

  return (
    <div className="panel">
      <h2>Frais réels {isAdmin ? "— validation" : ""}</h2>
      {error && <div className="alert error">{error}</div>}
      {notice && <div className="alert success">{notice}</div>}

      {!isAdmin && (
        <form className="form-grid" onSubmit={onSubmit} style={{ marginBottom: 18 }}>
          <label className="field">
            <span>Mission concernée *</span>
            <select value={missionId} onChange={(e) => setMissionId(e.target.value)} required>
              <option value="">— Choisir —</option>
              {missions.map((m) => (
                <option key={m.id} value={m.id}>
                  {m.publicRef} · {m.fromCity} → {m.toCity}
                </option>
              ))}
            </select>
          </label>
          <label className="field">
            <span>Type de frais *</span>
            <select value={type} onChange={(e) => setType(e.target.value)}>
              {FRAIS_TYPES.map((t) => <option key={t.value} value={t.value}>{t.label}</option>)}
            </select>
          </label>
          <label className="field">
            <span>Montant € *</span>
            <input type="number" step="0.01" min="0" value={montant} onChange={(e) => setMontant(e.target.value)} required />
          </label>
          <SecureFilePicker
            files={files}
            onChange={(selected) => {
              setFiles(selected.slice(0, 1));
              setOperationId(randomIdempotencyKey());
            }}
            label="Justificatif (photo ou PDF) *"
            allowPdf
            maxFiles={1}
            disabled={busy}
            progress={uploadProgress}
          />
          <button className="btn primary field-full" type="submit" disabled={busy || files.length !== 1}>
            {busy ? "Envoi…" : "Envoyer le frais"}
          </button>
        </form>
      )}

      {!isAdmin && (
        <p className="muted" style={{ marginBottom: 10 }}>
          Total remboursable (frais validés) : <strong>{formatAmount(totalRemboursable(items))}</strong>
        </p>
      )}

      {loading ? (
        <p className="muted">Chargement…</p>
      ) : items.length === 0 ? (
        <p className="muted">Aucun frais {isAdmin ? "à traiter" : "déclaré"}.</p>
      ) : (
        <div className="frais-list">
          {items.map((f) => (
            <div className="card-section" key={f.id} style={{ marginBottom: 10 }}>
              <div style={{ display: "flex", justifyContent: "space-between", gap: 10, flexWrap: "wrap" }}>
                <strong>{FRAIS_TYPES.find((t) => t.value === f.type)?.label || f.type} — {formatAmount(f.montant)}</strong>
                <span className={`status status-${f.statut === "valide" ? "validated" : f.statut === "refuse" ? "rejected" : "pending"}`}>
                  {STATUT_LABEL[f.statut] || labelStatus(f.statut)}
                </span>
              </div>
              <p className="muted" style={{ fontSize: "0.8rem" }}>{f.date}</p>
              {f.motifRefus && <p className="muted">Motif du refus : {f.motifRefus}</p>}
              <div className="actions-row" style={{ marginTop: 8, flexWrap: "wrap" }}>
                {f.justificatifUrl && (
                  <button className="btn ghost small" onClick={() => openJustificatif(f.justificatifUrl)}>
                    Voir le justificatif
                  </button>
                )}
                {isAdmin && f.statut === "en_attente" && (
                  <>
                    <button className="btn primary small" onClick={() => onValidate(f.id)}>Valider</button>
                    <button className="btn danger small" onClick={() => onRefuse(f.id)}>Refuser</button>
                  </>
                )}
              </div>
            </div>
          ))}
        </div>
      )}
    </div>
  );
}
