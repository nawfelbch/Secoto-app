import { humanizeError } from "../lib/humanError";
import { useCallback, useEffect, useRef, useState } from "react";
import LiveTrackingMap from "./LiveTrackingMap";
import { formatDateTime, freshnessLabel, liveView } from "../lib/onDemand";

// Vue CLIENT (et admin) du suivi. Actualisation adaptée : 20 s quand la
// position est fraîche, 60 s sinon, suspendue quand l'onglet est masqué.
export default function LiveTrackingView({ missionId, onClose }) {
  const [view, setView] = useState(null);
  const [error, setError] = useState("");
  const [lastFetch, setLastFetch] = useState(null);
  const [offline, setOffline] = useState(typeof navigator !== "undefined" && !navigator.onLine);
  const timer = useRef(null);

  const load = useCallback(async () => {
    try {
      const data = await liveView(missionId);
      setView(data);
      setError("");
      setLastFetch(new Date());
    } catch (e) {
      setError(humanizeError(e));
    }
  }, [missionId]);

  useEffect(() => {
    let alive = true;
    const schedule = (delay) => {
      clearTimeout(timer.current);
      timer.current = setTimeout(async () => {
        if (!alive) return;
        if (document.visibilityState === "visible" && navigator.onLine) await load();
        schedule(view?.freshness === "live" ? 20000 : 60000);
      }, delay);
    };
    queueMicrotask(() => { load().then(() => schedule(20000)); });
    const onVisible = () => { if (document.visibilityState === "visible") load(); };
    const on = () => { setOffline(false); load(); };
    const off = () => setOffline(true);
    document.addEventListener("visibilitychange", onVisible);
    window.addEventListener("online", on);
    window.addEventListener("offline", off);
    return () => {
      alive = false;
      clearTimeout(timer.current);
      document.removeEventListener("visibilitychange", onVisible);
      window.removeEventListener("online", on);
      window.removeEventListener("offline", off);
    };
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [load]);

  const stale = view?.freshness === "stale";
  return (
    <div className="panel panel-full">
      <div className="card-top">
        <h2>Suivi en direct</h2>
        {onClose && <button className="btn ghost small" type="button" onClick={onClose}>Fermer</button>}
      </div>
      {offline && <div className="alert error">Vous êtes hors ligne : les informations affichées ne sont plus actualisées.</div>}
      {error && <div className="alert error">{error}</div>}
      {!view && !error && <p className="muted">Chargement du suivi…</p>}
      {view && view.sharing !== "active" && (
        <div className="alert">
          {view.sharing === "stopped"
            ? view.stop_reason === "delivered" ? "Livraison effectuée : le partage de position est terminé." : "Le partage de position est terminé pour cette mission."
            : view.enabled === false ? "Le suivi en direct n’est pas encore disponible." : "Le suivi démarre lorsque le transporteur a récupéré votre véhicule et activé le partage de sa position."}
        </div>
      )}
      {view?.sharing === "active" && (
        <>
          {stale && <div className="alert error">Position ancienne : la connexion du transporteur est interrompue. La carte montre la dernière position connue, pas sa position actuelle.</div>}
          <LiveTrackingMap
            carrier={view.position}
            destination={view.destination?.lat ? view.destination : null}
            stale={stale}
          />
          <div className="od-live-meta">
            <div><span>État</span><strong className={`od-pill ${view.freshness === "live" ? "is-ok" : stale ? "is-bad" : "is-warn"}`}>{freshnessLabel(view)}</strong></div>
            <div><span>Dernière position</span><strong>{view.position ? formatDateTime(view.position.recorded_at) : "—"}</strong></div>
            <div><span>Arrivée estimée</span><strong>{view.eta && !stale ? `vers ${new Date(view.eta.eta_at).toLocaleTimeString("fr-FR", { hour: "2-digit", minute: "2-digit" })}` : "Estimation indisponible"}</strong></div>
            <div><span>Destination</span><strong>{view.destination?.city || view.destination?.label || "—"}</strong></div>
          </div>
          <p className="muted" style={{ marginTop: 10 }}>
            {view.mode === "plateau"
              ? "Position du transporteur qui achemine votre véhicule sur plateau (téléphone du transporteur), et non d’un traceur installé dans le véhicule."
              : "Position du convoyeur (téléphone du convoyeur), et non d’un traceur installé dans le véhicule."}
            {" "}L’heure d’arrivée est une estimation{view.eta?.multi_mission ? " qui ne tient pas compte d’éventuelles étapes intermédiaires" : ""}.
            {lastFetch && ` Actualisé à ${lastFetch.toLocaleTimeString("fr-FR", { hour: "2-digit", minute: "2-digit", second: "2-digit" })}.`}
          </p>
        </>
      )}
    </div>
  );
}
