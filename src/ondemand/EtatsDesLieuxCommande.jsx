import { useEffect, useState } from "react";
import { supabase } from "../supabaseClient";
import PhotoPrivee from "../PhotoPrivee";
import { trackingPhotoFromDb } from "../lib/mappers";

// ============================================================================
// SECOTO 084 — États des lieux visibles par le client dans sa commande.
// ----------------------------------------------------------------------------
// Dès que le transporteur a fait l'état des lieux de départ (puis d'arrivée),
// le client voit les photos dans « Mes commandes » : il n'a pas à s'inquiéter
// ni à appeler pour savoir où en est son véhicule. Photos privées, signées à
// l'affichage (le client ne lit que les missions dont il est le client).
// ============================================================================

const ETAPES = [
  { type: "pickup_inspection", titre: "État des lieux au départ" },
  { type: "delivery_inspection", titre: "État des lieux à l’arrivée" },
];

function heure(iso) {
  try {
    return new Date(iso).toLocaleString("fr-FR", { weekday: "short", day: "2-digit", month: "short", hour: "2-digit", minute: "2-digit" });
  } catch { return ""; }
}

export default function EtatsDesLieuxCommande({ missionId, refreshKey = "" }) {
  const [etat, setEtat] = useState({ events: [], photos: [] });

  useEffect(() => {
    if (!missionId) return undefined;
    let vivant = true;
    Promise.all([
      supabase.from("mission_tracking_events").select("id,event_type,comment,created_at")
        .eq("mission_id", missionId).in("event_type", ETAPES.map((e) => e.type)).order("created_at", { ascending: true }),
      supabase.from("mission_tracking_photos").select("id,tracking_event_id,mission_id,transporter_id,photo_type,file_name,file_path,created_at")
        .eq("mission_id", missionId).order("created_at", { ascending: true }),
    ]).then(([ev, ph]) => {
      if (!vivant || ev.error || ph.error) return;
      setEtat({ events: ev.data || [], photos: (ph.data || []).map(trackingPhotoFromDb) });
    }).catch(() => {});
    return () => { vivant = false; };
  }, [missionId, refreshKey]);

  const blocs = ETAPES.map((e) => {
    const events = etat.events.filter((x) => x.event_type === e.type);
    const ids = new Set(events.map((x) => x.id));
    return { ...e, event: events[events.length - 1], photos: etat.photos.filter((p) => ids.has(p.trackingEventId)) };
  }).filter((b) => b.event);

  if (blocs.length === 0) return null;
  return (
    <div className="od-etats-des-lieux">
      {blocs.map((b) => (
        <div key={b.type} className="card-section">
          <strong>{b.titre}</strong> <span className="muted">· {heure(b.event.created_at)}</span>
          {b.event.comment && <p className="muted" style={{ margin: "4px 0 0" }}>{b.event.comment}</p>}
          {b.photos.length > 0 ? (
            <div className="cards" style={{ marginTop: 10, gridTemplateColumns: "repeat(auto-fill,minmax(110px,1fr))" }}>
              {b.photos.map((p) => <PhotoPrivee key={p.id} photo={p} />)}
            </div>
          ) : (
            <p className="muted" style={{ margin: "6px 0 0" }}>Photos en cours d’envoi par le transporteur.</p>
          )}
        </div>
      ))}
    </div>
  );
}
