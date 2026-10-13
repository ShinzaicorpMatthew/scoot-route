// Outils géométriques (coordonnées [lon, lat] comme GeoJSON / GraphHopper)

const R = 6371008.8; // rayon terrestre moyen (m)
const toRad = (d) => (d * Math.PI) / 180;

export function haversine(a, b) {
  const dLat = toRad(b[1] - a[1]);
  const dLon = toRad(b[0] - a[0]);
  const s =
    Math.sin(dLat / 2) ** 2 +
    Math.cos(toRad(a[1])) * Math.cos(toRad(b[1])) * Math.sin(dLon / 2) ** 2;
  return 2 * R * Math.asin(Math.min(1, Math.sqrt(s)));
}

/** Distances cumulées le long d'une polyligne. */
export function cumulativeDistances(coords) {
  const out = new Array(coords.length);
  out[0] = 0;
  for (let i = 1; i < coords.length; i++) out[i] = out[i - 1] + haversine(coords[i - 1], coords[i]);
  return out;
}

/** Point interpolé à la distance d (m) le long de la polyligne. */
export function pointAtDistance(coords, cum, d) {
  if (d <= 0) return coords[0];
  const last = coords.length - 1;
  if (d >= cum[last]) return coords[last];
  let lo = 0, hi = last;
  while (hi - lo > 1) {
    const mid = (lo + hi) >> 1;
    if (cum[mid] <= d) lo = mid; else hi = mid;
  }
  const seg = cum[hi] - cum[lo];
  const t = seg > 0 ? (d - cum[lo]) / seg : 0;
  const a = coords[lo], b = coords[hi];
  return [a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t];
}

/** Ray casting : point dans un anneau (sans trous). */
export function pointInRing(pt, ring) {
  let inside = false;
  for (let i = 0, j = ring.length - 1; i < ring.length; j = i++) {
    const [xi, yi] = ring[i];
    const [xj, yj] = ring[j];
    if ((yi > pt[1]) !== (yj > pt[1]) && pt[0] < ((xj - xi) * (pt[1] - yi)) / (yj - yi) + xi) {
      inside = !inside;
    }
  }
  return inside;
}

export function pointInPolygon(pt, polygonCoords) {
  if (!pointInRing(pt, polygonCoords[0])) return false;
  for (let k = 1; k < polygonCoords.length; k++) if (pointInRing(pt, polygonCoords[k])) return false;
  return true;
}

/** Normalise une géométrie GeoJSON en liste de polygones (tableaux d'anneaux). */
export function polygonsOf(geometry) {
  if (!geometry) return [];
  if (geometry.type === 'Polygon') return [geometry.coordinates];
  if (geometry.type === 'MultiPolygon') return geometry.coordinates;
  return [];
}

export function bboxOfPolygons(polys) {
  let minX = Infinity, minY = Infinity, maxX = -Infinity, maxY = -Infinity;
  for (const p of polys) for (const [x, y] of p[0]) {
    if (x < minX) minX = x; if (y < minY) minY = y;
    if (x > maxX) maxX = x; if (y > maxY) maxY = y;
  }
  return [minX, minY, maxX, maxY];
}

export function inBbox(pt, b, marginDeg = 0) {
  return pt[0] >= b[0] - marginDeg && pt[0] <= b[2] + marginDeg &&
         pt[1] >= b[1] - marginDeg && pt[1] <= b[3] + marginDeg;
}

/** Carré (polygone GeoJSON) de demi-côté `halfSizeM` mètres autour d'un point. */
export function squareAround([lon, lat], halfSizeM) {
  const dLat = halfSizeM / 111320;
  const dLon = halfSizeM / (111320 * Math.cos(toRad(lat)));
  const ring = [
    [lon - dLon, lat - dLat], [lon + dLon, lat - dLat],
    [lon + dLon, lat + dLat], [lon - dLon, lat + dLat], [lon - dLon, lat - dLat],
  ];
  return { type: 'Polygon', coordinates: [ring] };
}

/** Simplification Douglas-Peucker approximative (en degrés) pour alléger les polygones. */
export function simplifyRing(ring, tolDeg) {
  if (ring.length <= 5) return ring;
  const keep = new Uint8Array(ring.length);
  keep[0] = keep[ring.length - 1] = 1;
  const stack = [[0, ring.length - 1]];
  while (stack.length) {
    const [s, e] = stack.pop();
    let maxD = 0, idx = -1;
    const [x1, y1] = ring[s], [x2, y2] = ring[e];
    const dx = x2 - x1, dy = y2 - y1;
    const len2 = dx * dx + dy * dy;
    for (let i = s + 1; i < e; i++) {
      const [x, y] = ring[i];
      let t = len2 ? ((x - x1) * dx + (y - y1) * dy) / len2 : 0;
      t = Math.max(0, Math.min(1, t));
      const d = Math.hypot(x - (x1 + t * dx), y - (y1 + t * dy));
      if (d > maxD) { maxD = d; idx = i; }
    }
    if (maxD > tolDeg && idx > 0) { keep[idx] = 1; stack.push([s, idx], [idx, e]); }
  }
  const out = ring.filter((_, i) => keep[i]);
  return out.length >= 4 ? out : ring;
}
