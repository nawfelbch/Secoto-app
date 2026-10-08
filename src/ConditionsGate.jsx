import { useState } from "react";
import { humanizeError } from "./lib/humanError";
import { acceptTerms, conditionsLinks, termsStatus } from "./lib/conditions";
import { openExternal } from "./platform/runtime";

// ============================================================================
// SECOTO 075 — Fenêtre d'acceptation des conditions.
// ----------------------------------------------------------------------------
// Un seul écran, une seule case (jamais pré-cochée), un seul bouton. Les liens
// sont visibles au moment de cocher : l'utilisateur est libre de les ouvrir.
// Tant que l'accord n'est pas donné, rien d'autre n'est accessible.
// ============================================================================

export function ConditionsSentence({ links, onOpen }) {
  return (
    <span>
      J’accepte{" "}
      {links.map((l, i) => (
        <span key={l.key}>
          {i > 0 && (i === links.length - 1 ? " et " : ", ")}
          <a
            href={l.url}
            target="_blank"
            rel="noopener noreferrer"
            onClick={(e) => { e.preventDefault(); onOpen(l.url); }}
          >
            {l.label}
          </a>
        </span>
      ))}
      .
    </span>
  );
}

export default function ConditionsGate({ status, onAccepted, onRefresh, onSignOut }) {
  const [coche, setCoche] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const links = conditionsLinks(status?.documents, status?.urls, status?.version);

  async function ouvrir(url) {
    try { await openExternal(url); } catch (e) { setError(humanizeError(e)); }
  }

  async function accepter() {
    setBusy(true);
    setError("");
    try {
      const s = await acceptTerms(status.version);
      onAccepted?.(s);
    } catch (e) {
      setError(humanizeError(e));
      setBusy(false);
      // Conditions mises à jour pendant que l'écran était ouvert : on recharge
      // la version en vigueur, l'utilisateur coche de nouveau.
      const frais = await termsStatus();
      if (frais?.version && frais.version !== status?.version) {
        setCoche(false);
        onRefresh?.(frais);
      }
    }
  }

  return (
    <main className="app-shell">
      <div className="layout">
      <div className="panel panel-full conditions-gate" role="dialog" aria-modal="true" aria-labelledby="conditions-titre">
        <h2 id="conditions-titre">Nos conditions évoluent</h2>
        <p className="muted">
          Pour continuer à utiliser SECOTO, merci de prendre connaissance de nos conditions et de les accepter.
        </p>
        {error && <div className="alert error" role="alert">{error}</div>}
        <label className="payment-waiver-row">
          <input type="checkbox" checked={coche} onChange={(e) => setCoche(e.target.checked)} />
          <ConditionsSentence links={links} onOpen={ouvrir} />
        </label>
        <div className="actions-row">
          <button className="btn primary" type="button" disabled={!coche || busy} onClick={accepter}>
            {busy ? "Enregistrement…" : "Accepter"}
          </button>
          {onSignOut && (
            <button className="btn ghost small" type="button" disabled={busy} onClick={onSignOut}>Se déconnecter</button>
          )}
        </div>
      </div>
    </div>
    </main>
  );
}
