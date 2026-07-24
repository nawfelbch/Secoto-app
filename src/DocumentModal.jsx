import { useEffect, useMemo, useState } from "react";
import {
  renderDevisHtml,
  renderBonMissionHtml,
  renderFactureHtml,
  nextDocNumber,
} from "./lib/documents";

// ============================================================================
// SECOTO - Fenetre "Documents" (devis / bon de mission / facture).
// ----------------------------------------------------------------------------
// Remplace l'ancien window.open() qui, dans l'application native, ouvrait le
// document DANS la webview sans aucun moyen de revenir en arriere.
// Ici : apercu dans une iframe, champs remplissables, impression/PDF,
// telechargement du fichier, et bouton de fermeture toujours accessible.
// ============================================================================

const TITLES = {
  devis: "Devis client",
  bon: "Bon de mission transporteur",
  facture: "Facture client",
};

const DOC_PREFIX = { devis: "DEV", bon: "BM", facture: "FAC" };
// Type attendu par la RPC de numerotation atomique cote base.
const RPC_TYPE = { devis: "devis", bon: "bon_de_mission", facture: "facture" };

function todayIso() {
  return new Date().toISOString().slice(0, 10);
}
function frDate(iso) {
  if (!iso) return "";
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return String(iso);
  return d.toLocaleDateString("fr-FR", { day: "2-digit", month: "2-digit", year: "numeric" });
}

function Row({ label, children }) {
  return (
    <label className="field">
      <span>{label}</span>
      {children}
    </label>
  );
}

export default function DocumentModal({ kind, mission, transporter = {}, onClose }) {
  // Copie modifiable de la mission : l'utilisateur peut corriger/completer
  // les informations avant d'editer le document.
  const [draft, setDraft] = useState(() => ({
    ...mission,
    vehicle: mission.vehicle || "",
    pickupAddress: mission.pickupAddress || mission.fromCity || "",
    deliveryAddress: mission.deliveryAddress || mission.toCity || "",
    distanceKm: mission.distanceKm ?? "",
    clientName: mission.clientName || "",
    clientContact: mission.clientContact || mission.clientPhone || "",
  }));

  const [opts, setOpts] = useState(() => ({
    numero: `${DOC_PREFIX[kind]}-${new Date().toISOString().slice(0, 7).replace("-", "")}-000`,
    dateDoc: todayIso(),
    dateLivraison: mission.missionDate ? String(mission.missionDate).slice(0, 10) : todayIso(),
    dateEcheance: todayIso(),
    refDevis: "",
    contactSurPlace: mission.clientContact || "",
    contactDepart: "",
    contactArrivee: "",
    conditionDates: "Dates indicatives, a confirmer selon disponibilite.",
  }));

  const [tr, setTr] = useState(() => ({
    name: transporter.name || mission.assignedTransporterName || "",
    address: transporter.address || "",
    siret: transporter.siret || "",
    phone: transporter.phone || "",
  }));

  const [numbering, setNumbering] = useState(false);
  const [numError, setNumError] = useState("");

  function setOpt(key, value) { setOpts((p) => ({ ...p, [key]: value })); }
  function setField(key, value) { setDraft((p) => ({ ...p, [key]: value })); }
  function setTrField(key, value) { setTr((p) => ({ ...p, [key]: value })); }

  // Fermeture au clavier (Echap) : filet de securite supplementaire.
  useEffect(() => {
    function onKey(e) { if (e.key === "Escape") onClose(); }
    document.addEventListener("keydown", onKey);
    return () => document.removeEventListener("keydown", onKey);
  }, [onClose]);

  const { html, renderError } = useMemo(() => {
    try {
      const common = {
        numero: opts.numero,
        dateDoc: frDate(opts.dateDoc),
        dateLivraison: opts.dateLivraison,
      };
      if (kind === "devis") {
        return {
          html: renderDevisHtml(draft, {
            ...common,
            contactSurPlace: opts.contactSurPlace,
            conditionDates: opts.conditionDates,
          }),
          renderError: "",
        };
      }
      if (kind === "bon") {
        return {
          html: renderBonMissionHtml(draft, tr, {
            ...common,
            contactDepart: opts.contactDepart,
            contactArrivee: opts.contactArrivee,
          }),
          renderError: "",
        };
      }
      return {
        html: renderFactureHtml(draft, {}, {
          ...common,
          dateEcheance: frDate(opts.dateEcheance),
          refDevis: opts.refDevis,
        }),
        renderError: "",
      };
    } catch (e) {
      return { html: "", renderError: e.message || "Generation impossible." };
    }
  }, [kind, draft, opts, tr]);

  const fileName = `${opts.numero || DOC_PREFIX[kind]}.html`;

  function handlePrint() {
    const frame = document.getElementById("secoto-doc-frame");
    if (!frame?.contentWindow) return;
    frame.contentWindow.focus();
    frame.contentWindow.print();
  }

  function handleDownload() {
    if (!html) return;
    const blob = new Blob([html], { type: "text/html;charset=utf-8" });
    const url = URL.createObjectURL(blob);
    const a = document.createElement("a");
    a.href = url;
    a.download = fileName;
    document.body.appendChild(a);
    a.click();
    document.body.removeChild(a);
    setTimeout(() => URL.revokeObjectURL(url), 4000);
  }

  async function handleOfficialNumber() {
    setNumbering(true); setNumError("");
    try {
      const n = await nextDocNumber(RPC_TYPE[kind]);
      if (n) setOpt("numero", n);
    } catch (e) {
      setNumError(e.message || "Numerotation indisponible.");
    } finally {
      setNumbering(false);
    }
  }

  return (
    <div className="doc-modal-backdrop" onMouseDown={(e) => { if (e.target === e.currentTarget) onClose(); }}>
      <div className="doc-modal" role="dialog" aria-modal="true" aria-label={TITLES[kind]}>
        <header className="doc-modal-head">
          <div>
            <strong>{TITLES[kind]}</strong>
            <span className="muted"> · {mission.publicRef || ""}</span>
          </div>
          <button type="button" className="doc-modal-close" onClick={onClose} aria-label="Fermer">×</button>
        </header>

        <div className="doc-modal-body">
          <div className="doc-modal-form">
            <h4>Informations du document</h4>

            <div className="form-grid">
              <Row label="Numéro">
                <input value={opts.numero} onChange={(e) => setOpt("numero", e.target.value)} />
              </Row>
              <Row label="Date du document">
                <input type="date" value={opts.dateDoc} onChange={(e) => setOpt("dateDoc", e.target.value)} />
              </Row>
              <Row label="Date de livraison">
                <input type="date" value={opts.dateLivraison} onChange={(e) => setOpt("dateLivraison", e.target.value)} />
              </Row>

              {kind === "facture" && (
                <>
                  <Row label="Date d’échéance">
                    <input type="date" value={opts.dateEcheance} onChange={(e) => setOpt("dateEcheance", e.target.value)} />
                  </Row>
                  <Row label="Référence devis">
                    <input value={opts.refDevis} onChange={(e) => setOpt("refDevis", e.target.value)} placeholder="DEV-…" />
                  </Row>
                </>
              )}

              {kind === "devis" && (
                <>
                  <Row label="Contact sur place">
                    <input value={opts.contactSurPlace} onChange={(e) => setOpt("contactSurPlace", e.target.value)} />
                  </Row>
                  <Row label="Conditions / dates">
                    <textarea value={opts.conditionDates} onChange={(e) => setOpt("conditionDates", e.target.value)} />
                  </Row>
                </>
              )}

              {kind === "bon" && (
                <>
                  <Row label="Transporteur — nom">
                    <input value={tr.name} onChange={(e) => setTrField("name", e.target.value)} />
                  </Row>
                  <Row label="Transporteur — adresse">
                    <input value={tr.address} onChange={(e) => setTrField("address", e.target.value)} />
                  </Row>
                  <Row label="Transporteur — SIRET">
                    <input value={tr.siret} onChange={(e) => setTrField("siret", e.target.value)} />
                  </Row>
                  <Row label="Transporteur — téléphone">
                    <input value={tr.phone} onChange={(e) => setTrField("phone", e.target.value)} />
                  </Row>
                  <Row label="Contact au départ">
                    <input value={opts.contactDepart} onChange={(e) => setOpt("contactDepart", e.target.value)} />
                  </Row>
                  <Row label="Contact à l’arrivée">
                    <input value={opts.contactArrivee} onChange={(e) => setOpt("contactArrivee", e.target.value)} />
                  </Row>
                </>
              )}
            </div>

            <h4>Informations de la mission</h4>
            <div className="form-grid">
              <Row label="Véhicule">
                <input value={draft.vehicle} onChange={(e) => setField("vehicle", e.target.value)} />
              </Row>
              <Row label="Distance (km)">
                <input type="number" min="0" value={draft.distanceKm} onChange={(e) => setField("distanceKm", e.target.value)} />
              </Row>
              <Row label="Adresse de départ">
                <input value={draft.pickupAddress} onChange={(e) => setField("pickupAddress", e.target.value)} />
              </Row>
              <Row label="Adresse d’arrivée">
                <input value={draft.deliveryAddress} onChange={(e) => setField("deliveryAddress", e.target.value)} />
              </Row>
              {kind !== "bon" && (
                <>
                  <Row label="Client — nom">
                    <input value={draft.clientName} onChange={(e) => setField("clientName", e.target.value)} />
                  </Row>
                  <Row label="Client — contact">
                    <input value={draft.clientContact} onChange={(e) => setField("clientContact", e.target.value)} />
                  </Row>
                </>
              )}
            </div>

            <div className="actions-row" style={{ flexWrap: "wrap", marginTop: 12 }}>
              <button type="button" className="btn ghost small" onClick={handleOfficialNumber} disabled={numbering}>
                {numbering ? "Numérotation…" : "Numéro officiel"}
              </button>
            </div>
            {numError && <div className="alert error" style={{ marginTop: 10 }}>{numError}</div>}
          </div>

          <div className="doc-modal-preview">
            {renderError ? (
              <div className="alert error">{renderError}</div>
            ) : (
              <iframe
                id="secoto-doc-frame"
                title="Aperçu du document"
                srcDoc={html}
              />
            )}
          </div>
        </div>

        <footer className="doc-modal-foot">
          <button type="button" className="btn ghost" onClick={onClose}>Fermer</button>
          <div className="actions-row" style={{ marginTop: 0, flexWrap: "wrap" }}>
            <button type="button" className="btn ghost" onClick={handleDownload} disabled={!html}>Télécharger</button>
            <button type="button" className="btn primary" onClick={handlePrint} disabled={!html}>Imprimer / PDF</button>
          </div>
        </footer>
      </div>
    </div>
  );
}
