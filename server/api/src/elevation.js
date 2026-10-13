// Altitude haute précision : API de calcul altimétrique de la Géoplateforme IGN
// (RGE ALTI®, maille 1 à 5 m, licence ouverte, sans clé, 5 requêtes/s par IP).
// En cas d'indisponibilité, on retombe sur l'altitude SRTM fournie par GraphHopper.

import { cumulativeDistances, pointAtDistance } from './geo.js';

const IGN_URL = 'https://data.geopf.fr/altimetrie/1.0/calcul/alti/rest/elevation.json';
const BATCH = 100;
const NO_DATA = -99999;

export function createElevationService({ enabled = true, fetchImpl = fetch, timeoutMs = 6000, cacheSize = 50000 } = {}) {
  const cache = new Map(); // "lon,lat" (5 décimales ≈ 1 m) → z
  const key = ([lon, lat]) => `${lon.toFixed(5)},${lat.toFixed(5)}`;

  function remember(k, z) {
    if (cache.size >= cacheSize) cache.delete(cache.keys().next().value);
    cache.set(k, z);
  }

  async function fetchBatch(points) {
    const lon = points.map((p) => p[0].toFixed(6)).join('|');
    const lat = points.map((p) => p[1].toFixed(6)).join('|');
    const url = `${IGN_URL}?lon=${lon}&lat=${lat}&resource=ign_rge_alti_wld&delimiter=|&indent=false&measures=false&zonly=false`;
    const ctrl = new AbortController();
    const timer = setTimeout(() => ctrl.abort(), timeoutMs);
    try {
      const res = await fetchImpl(url, { signal: ctrl.signal });
      if (!res.ok) throw new Error(`IGN HTTP ${res.status}`);
      const json = await res.json();
      const list = json?.elevations;
      if (!Array.isArray(list) || list.length !== points.length) throw new Error('Réponse IGN inattendue');
      return list.map((e) => {
        const z = typeof e === 'number' ? e : e?.z;
        return Number.isFinite(z) && z > NO_DATA + 1 ? z : null;
      });
    } finally {
      clearTimeout(timer);
    }
  }

  /**
   * Échantillonne la polyligne tous les `step` mètres et renvoie
   * { samples: [{d, lon, lat, z}], source } ou null si l'IGN est indisponible.
   */
  async function profile(coords, { step = 20, maxSamples = 600 } = {}) {
    if (!enabled || coords.length < 2) return null;
    const cum = cumulativeDistances(coords);
    const total = cum[cum.length - 1];
    const effStep = Math.max(step, total / maxSamples);
    const samples = [];
    for (let d = 0; d < total; d += effStep) samples.push({ d, pt: pointAtDistance(coords, cum, d) });
    samples.push({ d: total, pt: coords[coords.length - 1] });

    const missing = samples.filter((s) => !cache.has(key(s.pt)));
    try {
      for (let i = 0; i < missing.length; i += BATCH) {
        const chunk = missing.slice(i, i + BATCH);
        const zs = await fetchBatch(chunk.map((s) => s.pt));
        chunk.forEach((s, j) => remember(key(s.pt), zs[j]));
        if (i + BATCH < missing.length) await new Promise((r) => setTimeout(r, 220)); // ≤ 5 req/s
      }
    } catch {
      return null;
    }
    const out = samples.map((s) => ({ d: s.d, lon: s.pt[0], lat: s.pt[1], z: cache.get(key(s.pt)) }));
    const valid = out.filter((s) => s.z != null).length;
    if (valid < out.length * 0.8) return null;
    return { samples: out, source: 'IGN RGE ALTI' };
  }

  return { profile };
}
