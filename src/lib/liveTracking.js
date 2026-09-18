// SECOTO — calculs purs du suivi de position (testables sans navigateur).
export const MAX_BUFFER = 300;

export function distanceMeters(a, b) {
  const R = 6371000;
  const toRad = (d) => (d * Math.PI) / 180;
  const dLat = toRad(b.lat - a.lat);
  const dLng = toRad(b.lng - a.lng);
  const x = Math.sin(dLat / 2) ** 2 + Math.cos(toRad(a.lat)) * Math.cos(toRad(b.lat)) * Math.sin(dLng / 2) ** 2;
  return 2 * R * Math.asin(Math.sqrt(x));
}

// Échantillonnage économe en batterie : un point conservé si le véhicule a
// bougé d'au moins 40 m ou si 60 s se sont écoulées. Jamais deux points à
// moins de 5 s : le serveur les refuserait.
export function shouldKeepPoint(last, point) {
  if (!last) return true;
  const elapsed = (Date.parse(point.recorded_at) - Date.parse(last.recorded_at)) / 1000;
  if (!Number.isFinite(elapsed) || elapsed < 5) return false;
  return elapsed >= 60 || distanceMeters(last, point) >= 40;
}

// Envoi groupé : 30 s en mouvement, 120 s à l'arrêt.
export function flushDelay(lastPoint) {
  return lastPoint && Number(lastPoint.speed_mps) > 2 ? 30000 : 120000;
}

// Projection Web Mercator utilisée par la carte à tuiles.
export function projectTile(lat, lng, zoom, tileSize = 256) {
  const scale = tileSize * 2 ** zoom;
  const s = Math.min(Math.max(Math.sin((lat * Math.PI) / 180), -0.9999), 0.9999);
  return {
    x: ((lng + 180) / 360) * scale,
    y: (0.5 - Math.log((1 + s) / (1 - s)) / (4 * Math.PI)) * scale,
  };
}

export function fitZoom(points, width, height, tileSize = 256) {
  for (let z = 16; z >= 3; z -= 1) {
    const p = points.map((pt) => projectTile(Number(pt.lat), Number(pt.lng), z, tileSize));
    const w = Math.max(...p.map((a) => a.x)) - Math.min(...p.map((a) => a.x));
    const h = Math.max(...p.map((a) => a.y)) - Math.min(...p.map((a) => a.y));
    if (w <= width * 0.7 && h <= height * 0.7) return z;
  }
  return 3;
}
