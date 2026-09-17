import { useMemo } from "react";
import { fitZoom, projectTile } from "../lib/liveTracking";

// Carte légère SANS dépendance : tuiles raster positionnées à la main.
// Fournisseur de tuiles configurable (VITE_MAP_TILE_URL / VITE_MAP_ATTRIBUTION).
// Par défaut OpenStreetMap, à réserver aux essais : la politique d'usage des
// tuiles OSM impose un fournisseur dédié pour une application en production.
const TILE_URL = import.meta.env.VITE_MAP_TILE_URL || "https://tile.openstreetmap.org/{z}/{x}/{y}.png";
const ATTRIBUTION = import.meta.env.VITE_MAP_ATTRIBUTION || "© OpenStreetMap";
const TILE = 256;

export default function LiveTrackingMap({ carrier, destination, stale = false, width = 640, height = 480 }) {
  const points = [carrier, destination].filter((p) => p && Number.isFinite(Number(p.lat)) && Number.isFinite(Number(p.lng)));
  const layout = useMemo(() => {
    if (!points.length) return null;
    const zoom = points.length > 1 ? fitZoom(points, width, height) : 13;
    const proj = points.map((p) => projectTile(Number(p.lat), Number(p.lng), zoom));
    const cx = (Math.min(...proj.map((p) => p.x)) + Math.max(...proj.map((p) => p.x))) / 2;
    const cy = (Math.min(...proj.map((p) => p.y)) + Math.max(...proj.map((p) => p.y))) / 2;
    const left = cx - width / 2;
    const top = cy - height / 2;
    const tiles = [];
    const max = 2 ** zoom;
    for (let tx = Math.floor(left / TILE); tx <= Math.floor((left + width) / TILE); tx += 1) {
      for (let ty = Math.floor(top / TILE); ty <= Math.floor((top + height) / TILE); ty += 1) {
        if (ty < 0 || ty >= max) continue;
        const wrapped = ((tx % max) + max) % max;
        tiles.push({ key: `${tx}-${ty}`, src: TILE_URL.replace("{z}", zoom).replace("{x}", wrapped).replace("{y}", ty), left: tx * TILE - left, top: ty * TILE - top });
      }
    }
    const pos = (p) => {
      const q = projectTile(Number(p.lat), Number(p.lng), zoom);
      return { left: `${((q.x - left) / width) * 100}%`, top: `${((q.y - top) / height) * 100}%` };
    };
    const metersPerPixel = (156543.03 * Math.cos((Number(points[0].lat) * Math.PI) / 180)) / 2 ** zoom;
    return { tiles, pos, metersPerPixel };
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [carrier?.lat, carrier?.lng, destination?.lat, destination?.lng, width, height]);

  if (!layout) return <div className="od-map" role="img" aria-label="Carte indisponible"><p className="muted" style={{ padding: 16 }}>Position non disponible pour le moment.</p></div>;
  const accuracyPx = carrier?.accuracy_m ? Math.min(160, carrier.accuracy_m / layout.metersPerPixel) : 0;
  return (
    <div className="od-map" role="img" aria-label={stale ? "Carte : dernière position connue du transporteur (ancienne) et destination" : "Carte : position du transporteur et destination"}>
      <div style={{ position: "absolute", inset: 0, transform: "scale(var(--od-map-scale, 1))" }}>
        <svg viewBox={`0 0 ${width} ${height}`} preserveAspectRatio="xMidYMid slice" style={{ position: "absolute", inset: 0, width: "100%", height: "100%" }} aria-hidden="true">
          {layout.tiles.map((t) => <image key={t.key} href={t.src} x={t.left} y={t.top} width={TILE} height={TILE} />)}
        </svg>
      </div>
      {carrier && accuracyPx > 6 && (
        <div className="od-accuracy" style={{ ...layout.pos(carrier), width: `${(accuracyPx * 2 / width) * 100}%`, aspectRatio: "1" }} />
      )}
      {destination && Number.isFinite(Number(destination.lat)) && (
        <div className="od-marker is-dest" style={layout.pos(destination)}><span>Destination</span><i /></div>
      )}
      {carrier && (
        <div className={`od-marker ${stale ? "is-stale" : "is-carrier"}`} style={layout.pos(carrier)}><span>{stale ? "Dernière position connue" : "Transporteur"}</span><i /></div>
      )}
      <span className="od-attrib">{ATTRIBUTION}</span>
    </div>
  );
}
