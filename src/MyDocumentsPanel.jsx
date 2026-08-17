/* eslint-disable react-hooks/set-state-in-effect */
import { useCallback, useEffect, useState } from "react";
import { supabase } from "./supabaseClient";
import SignaturePad from "./SignaturePad";
import {
  DOC_LABEL,
  listMyDocuments,
  signDocument,
  withSignature,
  downloadDocument,
} from "./lib/docFlow";
import { formatDateTime } from "./lib/mappers";

// ============================================================================
// SECOTO — « Mes documents » (client et transporteur).
// Le destinataire consulte le document, le signe au doigt et le telecharge,
// sans jamais quitter l'application.
// ============================================================================

const STATUT_LABEL = {
  envoye: "A signer",
  signe: "Signe",
  refuse: "Refuse",
  expire: "Expire",
  brouillon: "En preparation",
};

export default function MyDocumentsPanel({
  account,
  focusMissionId = null,
  // Appelé après signature d'un DEVIS. Sur une mission plateau, l'appelant
  // enchaîne immédiatement sur l'écran de paiement : le bon de mission ne
  // partira au transporteur qu'après encaissement de la commission.
  onDevisSigned = null,
}) {
  const [docs, setDocs] = useState([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState("");
  const [notice, setNotice] = useState("");
  const [openId, setOpenId] = useState(null);
  const [signingId, setSigningId] = useState(null);
  const [busy, setBusy] = useState(false);

  const reload = useCallback(async () => {
    try {
      setDocs(await listMyDocuments());
      setError("");
    } catch (e) {
      setError(e.message || "Chargement des documents impossible.");
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    reload();
    const channel = supabase
      .channel(`docs-${account.id}`)
      .on("postgres_changes", { event: "*", schema: "public", table: "documents" }, () => { reload(); })
      .subscribe();
    return () => { supabase.removeChannel(channel); };
  }, [account.id, reload]);

  // Ouvre directement le document de la mission ciblee par une notification.
  useEffect(() => {
    if (!focusMissionId || !docs.length) return;
    const target = docs.find((d) => d.missionId === focusMissionId);
    if (target) setOpenId(target.id);
  }, [focusMissionId, docs]);

  async function onSign(docId, signature) {
    setBusy(true); setError(""); setNotice("");
    try {
      const signed = await signDocument(docId, signature);
      setSigningId(null);
      setNotice("Document signe. Une copie reste disponible ici a tout moment.");
      await reload();
      if (signed?.docType === "devis" && signed?.missionId) {
        onDevisSigned?.(signed.missionId);
      }
    } catch (e) {
      setError(e.message || "Signature impossible.");
    } finally {
      setBusy(false);
    }
  }

  function onDownload(doc) {
    try { downloadDocument(doc); }
    catch (e) { setError(e.message || "Telechargement impossible."); }
  }

  const toSign = docs.filter((d) => d.needsSignature && d.statut === "envoye");

  return (
    <div className="panel panel-full">
      <h2>
        Mes documents
        {toSign.length > 0 && <span className="badge" style={{ marginLeft: 10 }}>{toSign.length} à signer</span>}
      </h2>

      {error && <div className="alert error">{error}</div>}
      {notice && <div className="alert success">{notice}</div>}

      {loading ? (
        <p className="muted">Chargement…</p>
      ) : docs.length === 0 ? (
        <p className="muted">
          Aucun document pour le moment. Vous recevrez ici votre devis, votre bon de mission
          ou votre facture, avec une notification à chaque étape.
        </p>
      ) : (
        <div className="cards">
          {docs.map((doc) => {
            const isOpen = openId === doc.id;
            const isSigning = signingId === doc.id;
            const label = DOC_LABEL[doc.docType] || "Document";
            const mustSign = doc.needsSignature && doc.statut === "envoye";
            // La facture n'exige pas de signature, mais on laisse la
            // possibilité de la signer pour accord (« bon pour accord »).
            const canSign = doc.statut === "envoye";

            return (
              <article className={`mission-card ${mustSign ? "is-focused" : ""}`} key={doc.id}>
                <div className="card-top">
                  <span className="badge">{doc.numero || label}</span>
                  <span className={`status status-${doc.statut === "signe" ? "validated" : "pending"}`}>
                    {STATUT_LABEL[doc.statut] || doc.statut}
                  </span>
                </div>

                <h3>{label}</h3>
                <div className="card-section">
                  <p><strong>Reçu le :</strong> {formatDateTime(doc.emittedAt || doc.createdAt)}</p>
                  {doc.signedAt && <p><strong>Signé le :</strong> {formatDateTime(doc.signedAt)}</p>}
                  {mustSign && <p className="assigned">Signature requise pour poursuivre la mission.</p>}
                  {canSign && !mustSign && <p className="muted">Signature facultative — vous pouvez signer pour accord.</p>}
                </div>

                <div className="actions-row" style={{ flexWrap: "wrap" }}>
                  <button className="btn ghost small" type="button" onClick={() => setOpenId(isOpen ? null : doc.id)}>
                    {isOpen ? "Masquer" : "Consulter"}
                  </button>
                  <button className="btn ghost small" type="button" onClick={() => onDownload(doc)}>
                    Télécharger
                  </button>
                  {canSign && !isSigning && (
                    <button
                      className={`btn ${mustSign ? "primary" : "ghost"} small`}
                      type="button"
                      onClick={() => { setOpenId(doc.id); setSigningId(doc.id); }}
                    >
                      {mustSign ? "Signer" : "Signer (facultatif)"}
                    </button>
                  )}
                </div>

                {isOpen && (
                  <div className="doc-inline-preview">
                    <iframe
                      title={`Document ${doc.numero}`}
                      srcDoc={withSignature(doc)}
                      sandbox=""
                      referrerPolicy="no-referrer"
                    />
                  </div>
                )}

                {isSigning && (
                  <SignaturePad
                    defaultName={account.fullName || account.companyName || ""}
                    label={`Signer le ${label.toLowerCase()}`}
                    busy={busy}
                    onCancel={() => setSigningId(null)}
                    onSign={(sig) => onSign(doc.id, sig)}
                  />
                )}
              </article>
            );
          })}
        </div>
      )}
    </div>
  );
}
