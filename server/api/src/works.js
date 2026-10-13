// Chantiers perturbants de la Métropole de Lyon (open data, Licence Ouverte 2.0).
// Source : https://www.data.gouv.fr/datasets/chantiers-perturbants-de-la-metropole-de-lyon
// Ces données sont mises à jour périodiquement par la Métropole : ce n'est PAS du temps réel.

import { polygonsOf, bboxOfPolygons, simplifyRing } from './geo.js';

const START_KEYS = /(debut|début|start|date_?deb|datedebut)/i;
const END_KEYS = /(fin|end|date_?fin|datefin)/i;
const LABEL_KEYS = ['libelle', 'nature', 'titre', 'objet', 'nom', 'name', 'description', 'typeperturbation', 'type'];

export function parseDate(v) {
  if (v == null || v === '') return null;
  if (typeof v === 'number') return new Date(v > 1e12 ? v : v * 1000);
  const s = String(v).trim();
  const fr = s.match(/^(\d{2})\/(\d{2})\/(\d{4})/);
  if (fr) return new Date(`${fr[3]}-${fr[2]}-${fr[1]}T00:00:00`);
  const d = new Date(s);
  return Number.isNaN(d.getTime()) ? null : d;
}

function findKey(props, regex) {
  return Object.keys(props).find((k) => regex.test(k) && parseDate(props[k]) != null) ?? null;
}

function labelOf(props) {
  for (const k of Object.keys(props)) {
    if (LABEL_KEYS.includes(k.toLowerCase()) && typeof props[k] === 'string' && props[k].trim()) return props[k].trim();
  }
  return 'Chantier perturbant';
}

/** Transforme un FeatureCollection en liste de chantiers actifs à la date `now`. */
export function parseWorks(geojson, now = new Date()) {
  const features = Array.isArray(geojson?.features) ? geojson.features : [];
  const out = [];
  let detected = null;
  let skippedCrs = 0;
  features.forEach((f, i) => {
    const props = f.properties || {};
    const polys = polygonsOf(f.geometry)
      .map((p) => p.map((ring) => simplifyRing(ring, 0.00003)))
      .filter((p) => p[0]?.length >= 4);
    if (!polys.length) return;
    const [x, y] = polys[0][0][0];
    if (Math.abs(x) > 180 || Math.abs(y) > 90) { skippedCrs++; return; } // pas en WGS84
    const startKey = findKey(props, START_KEYS);
    const endKey = findKey(props, END_KEYS);
    detected ??= { startKey, endKey };
    const start = startKey ? parseDate(props[startKey]) : null;
    const end = endKey ? parseDate(props[endKey]) : null;
    if (start && start > now) return;
    if (end) {
      const endOfDay = new Date(end); endOfDay.setHours(23, 59, 59, 999);
      if (endOfDay < now) return;
    }
    out.push({
      id: `works_${i}`,
      label: labelOf(props),
      info: { start: start?.toISOString().slice(0, 10) ?? null, end: end?.toISOString().slice(0, 10) ?? null },
      polys,
      bbox: bboxOfPolygons(polys),
      geometry: polys.length === 1 ? { type: 'Polygon', coordinates: polys[0] } : { type: 'MultiPolygon', coordinates: polys },
    });
  });
  return { works: out, detected, skippedCrs, total: features.length };
}

export function createWorksService({ url, refreshMs = 6 * 3600 * 1000, fetchImpl = fetch, logger = console }) {
  let state = { works: [], meta: { available: false, source_url: url, fetched_at: null, count: 0, live: false, error: null } };

  async function refresh() {
    if (!url) {
      state.meta = { ...state.meta, available: false, error: 'WORKS_GEOJSON_URL non configurée' };
      return;
    }
    try {
      const res = await fetchImpl(url, { redirect: 'follow' });
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      const json = await res.json();
      const parsed = parseWorks(json);
      state = {
        works: parsed.works,
        meta: {
          available: true, live: false, source_url: url, fetched_at: new Date().toISOString(),
          count: parsed.works.length, total_features: parsed.total, date_fields: parsed.detected,
          skipped_non_wgs84: parsed.skippedCrs, error: null,
        },
      };
      logger.info?.(`[travaux] ${parsed.works.length} chantiers actifs / ${parsed.total} (champs dates : ${JSON.stringify(parsed.detected)})`);
    } catch (e) {
      // On garde la dernière version valide si elle existe
      state.meta = { ...state.meta, available: state.works.length > 0, error: String(e.message || e) };
      logger.warn?.(`[travaux] échec de mise à jour : ${e.message}`);
    }
  }

  let timer = null;
  return {
    refresh,
    start() { refresh(); timer = setInterval(refresh, refreshMs); timer.unref?.(); },
    stop() { if (timer) clearInterval(timer); },
    meta: () => state.meta,
    /** Chantiers dont l'emprise intersecte la bbox [minLon,minLat,maxLon,maxLat]. */
    near(b, limit = 150) {
      return state.works
        .filter((w) => w.bbox[0] <= b[2] && w.bbox[2] >= b[0] && w.bbox[1] <= b[3] && w.bbox[3] >= b[1])
        .slice(0, limit);
    },
    _setForTests(works) { state = { works, meta: { available: true, count: works.length, live: false } }; },
  };
}
