import { humanizeError } from "../lib/humanError";
import { useCallback, useEffect, useRef, useState } from "react";
import { isNativePlatform } from "../platform/runtime";
import { livePush, liveStart, liveStop, liveView } from "../lib/onDemand";
import { MAX_BUFFER, flushDelay, shouldKeepPoint } from "../lib/liveTracking";

const PICKED_UP = new Set(["pickup_completed", "in_transit", "incident_reported", "delivery_started"]);
function storageKey(missionId) { return `secoto-live-buffer-${missionId}`; }
function readBuffer(missionId) {
  try { return JSON.parse(localStorage.getItem(storageKey(missionId)) || "[]"); } catch { return []; }
}
function writeBuffer(missionId, points) {
  try { localStorage.setItem(storageKey(missionId), JSON.stringify(points.slice(-MAX_BUFFER))); } catch { /* stockage indisponible */ }
}

export default function LiveSharingControl({ mission }) {
  const [sharing, setSharing] = useState("unknown"); // unknown | not_started | active | stopped
  const [consent, setConsent] = useState(false); // jamais pré-coché
  const [status, setStatus] = useState("");
  const [error, setError] = useState("");
  const [lastSent, setLastSent] = useState(null);
  const [pending, setPending] = useState(0);
  const watchRef = useRef(null);
  const bufferRef = useRef(readBuffer(mission.id));
  const lastPointRef = useRef(null);
  const flushTimer = useRef(null);

  const eligible = mission.status === "assigned" && PICKED_UP.has(mission.progressStatus);

  const flush = useCallback(async () => {
    clearTimeout(flushTimer.current);
    const batch = bufferRef.current.slice(0, 100);
    if (batch.length && navigator.onLine) {
      try {
        const r = await livePush(mission.id, batch);
        bufferRef.current = bufferRef.current.slice(batch.length);
        writeBuffer(mission.id, bufferRef.current);
        setLastSent(new Date());
        setError("");
        if (r?.sharing === "stopped") {
          stopWatch();
          setSharing("stopped");
          return;
        }
      } catch {
        setError("Réseau indisponible : les positions sont conservées et seront envoyées au retour de la connexion.");
      }
    }
    setPending(bufferRef.current.length);
    flushTimer.current = setTimeout(flush, flushDelay(lastPointRef.current));
  }, [mission.id]);

  function onPosition(coords, timestamp) {
    const point = {
      lat: coords.latitude, lng: coords.longitude,
      accuracy_m: coords.accuracy ?? null, speed_mps: coords.speed ?? null, heading: coords.heading ?? null,
      recorded_at: new Date(timestamp || Date.now()).toISOString(),
    };
    if (!shouldKeepPoint(lastPointRef.current, point)) return;
    lastPointRef.current = point;
    bufferRef.current = [...bufferRef.current, point].slice(-MAX_BUFFER);
    writeBuffer(mission.id, bufferRef.current);
    setPending(bufferRef.current.length);
    if (bufferRef.current.length === 1 && !lastSent) flush();
  }

  function onGeoError(err) {
    const denied = err?.code === 1 || /denied|permission/i.test(err?.message || "");
    setError(denied
      ? "Localisation refusée. Autorisez SECOTO à accéder à votre position (réglages du téléphone) pour partager le suivi."
      : "Position momentanément indisponible (signal GPS). Le partage reprendra automatiquement.");
  }

  async function startWatch() {
    if (watchRef.current) return;
    try {
      if (isNativePlatform()) {
        const { Geolocation } = await import("@capacitor/geolocation");
        let permission = await Geolocation.checkPermissions();
        if (permission.location !== "granted") permission = await Geolocation.requestPermissions({ permissions: ["location"] });
        if (permission.location !== "granted" && permission.coarseLocation !== "granted") { onGeoError({ code: 1 }); return; }
        const id = await Geolocation.watchPosition({ enableHighAccuracy: true, timeout: 20000, maximumAge: 15000, minimumUpdateInterval: 10000 }, (pos, err) => {
          if (err) onGeoError(err); else if (pos) onPosition(pos.coords, pos.timestamp);
        });
        watchRef.current = { native: true, id };
      } else if (navigator.geolocation) {
        const id = navigator.geolocation.watchPosition((pos) => onPosition(pos.coords, pos.timestamp), onGeoError, { enableHighAccuracy: true, maximumAge: 15000, timeout: 20000 });
        watchRef.current = { native: false, id };
      } else {
        setError("Ce navigateur ne permet pas la localisation.");
        return;
      }
      flushTimer.current = setTimeout(flush, 10000);
    } catch (e) {
      onGeoError(e);
    }
  }

  function stopWatch() {
    clearTimeout(flushTimer.current);
    const w = watchRef.current;
    watchRef.current = null;
    if (!w) return;
    if (w.native) import("@capacitor/geolocation").then(({ Geolocation }) => Geolocation.clearWatch({ id: w.id })).catch(() => {});
    else navigator.geolocation?.clearWatch(w.id);
  }

  useEffect(() => {
    let alive = true;
    const started = liveView(mission.id).then((v) => {
      if (!alive) return;
      setSharing(v.sharing);
      // Partage déjà consenti pour CETTE mission : reprise après interruption.
      if (v.sharing === "active" && eligible) startWatch();
    }).catch(() => setSharing("not_started"));
    void started;
    const online = () => flush();
    window.addEventListener("online", online);
    return () => { alive = false; window.removeEventListener("online", online); stopWatch(); };
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [mission.id]);

  useEffect(() => {
    if (!eligible && sharing === "active") { stopWatch(); queueMicrotask(() => setSharing("stopped")); }
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [eligible]);

  if (!eligible && sharing !== "active") return null;

  return (
    <div className="card-section">
      <h4>Suivi en direct pour le client</h4>
      {sharing === "active" ? (
        <>
          <div className="od-sharing-banner" role="status">
            <span><strong>Partage de position actif</strong> — visible uniquement par le client de cette mission et SECOTO.</span>
            <button className="btn ghost small" type="button" onClick={async () => {
              await flush();
              await liveStop(mission.id).catch(() => null);
              stopWatch();
              setSharing("stopped");
            }}>Arrêter le partage</button>
          </div>
          <p className="muted">
            {isNativePlatform()
              ? "Gardez SECOTO ouvert pendant le trajet : si l’application passe en arrière-plan, le téléphone peut suspendre la localisation et le client verra une position ancienne."
              : "Depuis le navigateur, le partage ne fonctionne que tant que cette page reste ouverte et l’écran allumé."}
            {" "}Arrêt automatique à la livraison.
          </p>
          <p className="muted">{lastSent ? `Dernier envoi à ${lastSent.toLocaleTimeString("fr-FR", { hour: "2-digit", minute: "2-digit" })}` : "En attente de la première position…"}{pending ? ` · ${pending} position(s) en attente d’envoi` : ""}</p>
        </>
      ) : sharing === "stopped" ? (
        <p className="muted">Partage de position arrêté pour cette mission.</p>
      ) : (
        <>
          <p>Le client peut suivre la progression de son véhicule jusqu’à la livraison si vous partagez votre position pendant cette mission.</p>
          <label className="payment-waiver-row">
            <input type="checkbox" checked={consent} onChange={(e) => setConsent(e.target.checked)} />
            <span>J’accepte de partager ma position pendant cette mission uniquement. Elle est visible par le client de la mission et par SECOTO, et le partage s’arrête automatiquement à la livraison.</span>
          </label>
          <button className="btn primary small" type="button" disabled={!consent} onClick={async () => {
            setError(""); setStatus("");
            try {
              await liveStart(mission.id);
              setSharing("active");
              startWatch();
            } catch (e) { setError(humanizeError(e)); }
          }}>Activer le partage</button>
        </>
      )}
      {status && <p className="muted">{status}</p>}
      {error && <div className="alert error">{error}</div>}
    </div>
  );
}
