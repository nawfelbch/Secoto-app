import { useEffect, useState } from "react";
import { humanizeError } from "./lib/humanError";
import { couvertureEnregistrer, couvertureStatut } from "./lib/couverture";
import { DEPARTEMENTS, RACCOURCIS, appliquerRaccourci, basculer, resumeDepartements } from "./lib/couvertureUtil";

// ============================================================================
// SECOTO 088 — Couverture du transporteur : départements + moto.
// Un seul écran. Fenêtre à la reconnexion tant qu'elle n'a pas été confirmée,
// puis modifiable à tout moment depuis « Disponibilité ». La moto est décochée
// par défaut : le transporteur la coche seulement s'il la transporte vraiment.
// ============================================================================

export default function CouvertureTransporteur({ status: statusInitial = null, gate = false, onSaved, onCancel }) {
  const [status, setStatus] = useState(statusInitial);
  const [zones, setZones] = useState(() => (statusInitial?.zones || []).filter((d) => DEPARTEMENTS.includes(d)));
  const [moto, setMoto] = useState(Boolean(statusInitial?.moto));
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");

  useEffect(() => {
    if (statusInitial) return undefined;
    let vivant = true;
    couvertureStatut().then((s) => {
      if (!vivant) return;
      setStatus(s);
      setZones((s?.zones || []).filter((d) => DEPARTEMENTS.includes(d)));
      setMoto(Boolean(s?.moto));
    });
    return () => { vivant = false; };
  }, [statusInitial]);

  async function valider() {
    if (zones.length === 0) { setError("Choisissez au moins un département."); return; }
    setBusy(true); setError("");
    try { onSaved?.(await couvertureEnregistrer(zones, moto)); }
    catch (e) { setError(humanizeError(e)); }
    finally { setBusy(false); }
  }

  const convoyeur = Boolean(status?.convoyeur);
  return (
    <div className={gate ? "panel panel-full" : "panel"} role={gate ? "dialog" : undefined} aria-modal={gate || undefined} aria-labelledby="couv-titre">
      <h2 id="couv-titre">{gate ? "Où prenez-vous les véhicules en charge ?" : "Départements et moto"}</h2>
      <p className="muted">Vous recevez uniquement les missions qui partent des départements cochés.</p>

      <div className="couv-raccourcis">
        {RACCOURCIS.map((r) => (
          <button key={r.key} type="button" onClick={() => setZones((z) => appliquerRaccourci(z, r.deps))}>{r.label}</button>
        ))}
        {zones.length > 0 && <button type="button" onClick={() => setZones([])}>Tout décocher</button>}
      </div>
      <div className="couv-grille" role="group" aria-label="Départements">
        {DEPARTEMENTS.map((d) => (
          <button key={d} type="button" aria-pressed={zones.includes(d)} onClick={() => setZones((z) => basculer(z, d))}>{d}</button>
        ))}
      </div>
      <p className="muted" style={{ margin: "8px 0 0" }}>{resumeDepartements(zones)}</p>

      <label className="couv-moto">
        <input type="checkbox" checked={moto} onChange={(e) => setMoto(e.target.checked)} />
        <span>
          <strong>{convoyeur ? "Je convoie aussi des motos" : "Je transporte aussi des motos"}</strong>
          <small className="muted" style={{ display: "block" }}>
            {convoyeur ? "Cochez seulement si vous avez le permis moto adapté." : "Cochez seulement si votre véhicule est équipé pour les motos (sangles, cale-roue)."}
          </small>
        </span>
      </label>

      {error && <div className="alert error" role="alert">{error}</div>}
      <div className="actions-row" style={{ marginTop: 12 }}>
        <button type="button" className="btn primary" disabled={busy || zones.length === 0} onClick={valider}>
          {busy ? "Enregistrement…" : "Valider"}
        </button>
        {!gate && onCancel && <button type="button" className="btn ghost" onClick={onCancel}>Annuler</button>}
      </div>
    </div>
  );
}
