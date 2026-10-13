// Analyse d'un itinéraire GraphHopper : altitude, pentes, segments, coûts, fiabilité.

import { cumulativeDistances, pointAtDistance, pointInPolygon, inBbox } from './geo.js';

const ROAD_CLASS_FR = {
  CYCLEWAY: 'Piste cyclable', RESIDENTIAL: 'Rue résidentielle', LIVING_STREET: 'Zone de rencontre',
  SERVICE: 'Voie de desserte', TERTIARY: 'Route tertiaire', SECONDARY: 'Route secondaire',
  PRIMARY: 'Grand axe', TRACK: 'Chemin', PATH: 'Sentier', FOOTWAY: 'Voie piétonne',
  PEDESTRIAN: 'Zone piétonne', STEPS: 'Escaliers', UNCLASSIFIED: 'Route non classée',
  BRIDLEWAY: 'Chemin équestre', OTHER: 'Autre',
};
const UNPAVED = new Set(['UNPAVED', 'GRAVEL', 'FINE_GRAVEL', 'GROUND', 'DIRT', 'GRASS', 'SAND', 'COMPACTED']);
const BAD_SMOOTH = new Set(['BAD', 'VERY_BAD', 'HORRIBLE', 'VERY_HORRIBLE', 'IMPASSABLE']);

// Constantes de normalisation du coût multicritère (configurables) :
// 1 minute ≡ 250 m de distance ≡ 8 m de dénivelé positif ≡ 1 unité de coût.
export const NORMALIZATION = { minutesPerUnit: 1, metersPerUnit: 250, climbMetersPerUnit: 8 };

/** Construit une fonction index-de-point → valeur pour un détail GraphHopper. */
function detailLookup(intervals = []) {
  return (idx) => {
    for (const [from, to, value] of intervals) if (idx >= from && idx < to) return value;
    return null;
  };
}

function movingAverage(samples, windowM) {
  const out = new Array(samples.length);
  let lo = 0, hi = 0, sum = 0, n = 0;
  for (let i = 0; i < samples.length; i++) {
    while (hi < samples.length && samples[hi].d <= samples[i].d + windowM / 2) { sum += samples[hi].z; n++; hi++; }
    while (samples[lo].d < samples[i].d - windowM / 2) { sum -= samples[lo].z; n--; lo++; }
    out[i] = { d: samples[i].d, z: sum / n };
  }
  return out;
}

/** Dénivelés cumulés avec hystérésis (évite de compter le bruit du modèle de terrain). */
export function climbStats(series, threshold = 1.5) {
  let ascent = 0, descent = 0;
  if (series.length < 2) return { ascent, descent };
  let ref = series[0].z;
  for (const s of series) {
    const diff = s.z - ref;
    if (diff >= threshold) { ascent += diff; ref = s.z; }
    else if (diff <= -threshold) { descent += -diff; ref = s.z; }
  }
  return { ascent, descent };
}

/** Pente maximale (montée et descente) mesurée sur des fenêtres d'au moins `minRun` mètres. */
export function maxSlopes(series, minRun = 40) {
  let up = 0, down = 0, j = 0;
  for (let i = 0; i < series.length; i++) {
    if (j < i) j = i;
    while (j < series.length - 1 && series[j].d - series[i].d < minRun) j++;
    const run = series[j].d - series[i].d;
    if (run < minRun * 0.75) break;
    const slope = ((series[j].z - series[i].z) / run) * 100;
    if (slope > up) up = slope;
    if (-slope > down) down = -slope;
  }
  return { up, down };
}

/** Altitude interpolée à la distance d dans une série triée. */
function zAt(series, d) {
  if (d <= series[0].d) return series[0].z;
  const last = series[series.length - 1];
  if (d >= last.d) return last.z;
  let lo = 0, hi = series.length - 1;
  while (hi - lo > 1) { const m = (lo + hi) >> 1; if (series[m].d <= d) lo = m; else hi = m; }
  const a = series[lo], b = series[hi];
  return a.z + ((b.z - a.z) * (d - a.d)) / (b.d - a.d || 1);
}

/**
 * Corrige les ponts et tunnels : le modèle de terrain donne l'altitude du sol
 * (la Saône ou le Rhône sous un pont), on interpole donc entre les deux extrémités.
 */
export function fixStructures(samples, ranges) {
  if (!ranges.length) return samples;
  const out = samples.map((s) => ({ ...s }));
  for (const [d0, d1] of ranges) {
    const before = [...out].reverse().find((s) => s.d <= d0) ?? out[0];
    const after = out.find((s) => s.d >= d1) ?? out[out.length - 1];
    for (const s of out) {
      if (s.d > d0 && s.d < d1 && after.d > before.d) {
        s.z = before.z + ((after.z - before.z) * (s.d - before.d)) / (after.d - before.d);
      }
    }
  }
  return out;
}

/**
 * @param path        chemin GraphHopper (points_encoded=false, elevation=true)
 * @param ctx         { profileId, label, ignProfile, works:[{id,label,polys,bbox,info}], worksMeta, weights }
 */
export function analyzePath(path, ctx) {
  const coords = path.points.coordinates; // [lon, lat, ele]
  const cum = cumulativeDistances(coords);
  const total = cum[cum.length - 1] || path.distance;
  const det = path.details || {};
  const get = Object.fromEntries(Object.keys(det).map((k) => [k, detailLookup(det[k])]));
  const val = (name, idx) => (get[name] ? get[name](idx) : null);

  // --- Altitude --------------------------------------------------------------
  const structureRanges = (det.road_environment || [])
    .filter(([, , v]) => v === 'BRIDGE' || v === 'TUNNEL')
    .map(([from, to]) => [cum[from], cum[to]]);

  let rawSeries, elevationSource;
  if (ctx.ignProfile) {
    rawSeries = fixStructures(ctx.ignProfile.samples.map((s) => ({ d: s.d, z: s.z ?? NaN })), structureRanges);
    // trous éventuels → interpolation entre voisins valides
    const valid = rawSeries.filter((s) => Number.isFinite(s.z));
    rawSeries = rawSeries.map((s) => (Number.isFinite(s.z) ? s : { d: s.d, z: zAt(valid, s.d) }));
    elevationSource = ctx.ignProfile.source;
  } else {
    rawSeries = coords.map((c, i) => ({ d: cum[i], z: Number.isFinite(c[2]) ? c[2] : 0 }));
    elevationSource = 'SRTM (via GraphHopper)';
  }
  const series = movingAverage(rawSeries, ctx.ignProfile ? 40 : 90);
  const { ascent, descent } = climbStats(series);
  const slopes = maxSlopes(series, 40);

  // --- Segments ----------------------------------------------------------------
  const worksList = ctx.works || [];
  const worksAt = (pt) => {
    for (const w of worksList) {
      if (!inBbox(pt, w.bbox, 0.0003)) continue;
      if (w.polys.some((p) => pointInPolygon(pt, p))) return w;
    }
    return null;
  };

  const attrsAt = (i) => {
    const roadClass = val('road_class', i) || 'OTHER';
    const cycleway = val('cycleway', i);
    const network = val('bike_network', i);
    const surface = val('surface', i) || 'MISSING';
    const smooth = val('smoothness', i);
    const maxSpeed = val('max_speed', i);
    const cycleInfra = roadClass === 'CYCLEWAY' || cycleway === 'TRACK' || cycleway === 'LANE' ||
      (network != null && network !== 'MISSING');
    const getOff = val('get_off_bike', i) === true;
    const fastRoad = Number.isFinite(maxSpeed) && maxSpeed > 50 && !cycleInfra;
    const mid = [(coords[i][0] + coords[i + 1][0]) / 2, (coords[i][1] + coords[i + 1][1]) / 2];
    const works = worksAt(mid);
    return {
      road_class: roadClass,
      surface,
      cycle_infra: cycleInfra,
      unpaved: UNPAVED.has(surface),
      cobbles: surface === 'COBBLESTONE',
      rough: smooth != null && BAD_SMOOTH.has(smooth),
      access_uncertain: getOff || fastRoad,
      access_reason: getOff ? 'pedestrian' : fastRoad ? 'fast_road' : null,
      works_id: works?.id ?? null,
      street: val('street_name', i) || '',
    };
  };
  const sameAttrs = (a, b) =>
    a.road_class === b.road_class && a.surface === b.surface && a.cycle_infra === b.cycle_infra &&
    a.access_uncertain === b.access_uncertain && a.works_id === b.works_id && a.street === b.street;

  const segments = [];
  for (let i = 0; i < coords.length - 1; i++) {
    const a = attrsAt(i);
    const last = segments[segments.length - 1];
    if (last && sameAttrs(last.attrs, a)) last.to = i + 1;
    else segments.push({ from: i, to: i + 1, attrs: a });
  }

  const w = ctx.weights;
  const avgSpeedMs = path.distance / Math.max(1, path.time / 1000);
  const shares = { cycle: 0, unpaved: 0, cobbles: 0, unknownSurface: 0, uncertain: 0, works: 0 };
  const byRoadClass = {};
  const worksHits = new Map();
  let totalCost = 0;

  const outSegments = segments.map((s) => {
    const d0 = cum[s.from], d1 = cum[s.to];
    const len = d1 - d0;
    const sub = series.filter((p) => p.d >= d0 && p.d <= d1);
    const z0 = zAt(series, d0), z1 = zAt(series, d1);
    const segClimb = climbStats([{ d: d0, z: z0 }, ...sub, { d: d1, z: z1 }], 1.0);
    const avgSlope = len > 0 ? ((z1 - z0) / len) * 100 : 0;
    const t = len / avgSpeedMs; // s (approximation proportionnelle)
    const A = s.attrs;

    // Coût multicritère normalisé du segment
    const units = len / NORMALIZATION.metersPerUnit;
    const slopePenalty = Math.max(0, avgSlope - 4) ** 1.5 * units * 0.15;
    const surfacePenalty = (A.unpaved ? 1 : A.cobbles ? 0.6 : A.rough ? 0.5 : 0) * units;
    const safetyPenalty = (A.cycle_infra ? 0 : ['PRIMARY', 'SECONDARY'].includes(A.road_class) ? 0.6 : 0.1) * units;
    const restrictionPenalty = (A.access_uncertain ? 3 : 0) * units + (A.works_id ? 2 : 0) * units;
    const cost =
      w.time * (t / 60 / NORMALIZATION.minutesPerUnit) +
      w.distance * units +
      w.climb * (segClimb.ascent / NORMALIZATION.climbMetersPerUnit) +
      w.slope * slopePenalty +
      w.surface * surfacePenalty +
      w.safety * safetyPenalty +
      restrictionPenalty;
    totalCost += cost;

    if (A.cycle_infra) shares.cycle += len;
    if (A.unpaved) shares.unpaved += len;
    if (A.cobbles) shares.cobbles += len;
    if (A.surface === 'MISSING') shares.unknownSurface += len;
    if (A.access_uncertain) shares.uncertain += len;
    if (A.works_id) {
      shares.works += len;
      const wk = worksList.find((x) => x.id === A.works_id);
      const prev = worksHits.get(A.works_id);
      worksHits.set(A.works_id, { id: A.works_id, label: wk?.label ?? 'Chantier', info: wk?.info ?? null,
        from_m: Math.round(prev?.from_m ?? d0), to_m: Math.round(d1) });
    }
    byRoadClass[A.road_class] = (byRoadClass[A.road_class] || 0) + len;

    return {
      from_index: s.from, to_index: s.to,
      start_m: Math.round(d0), length_m: Math.round(len), duration_s: Math.round(t),
      street: A.street, road_class: A.road_class, road_type: ROAD_CLASS_FR[A.road_class] ?? A.road_class,
      surface: A.surface, cycle_infra: A.cycle_infra, unpaved: A.unpaved, cobbles: A.cobbles, rough: A.rough,
      access_uncertain: A.access_uncertain, access_reason: A.access_reason, works_id: A.works_id,
      ascent_m: Math.round(segClimb.ascent * 10) / 10, descent_m: Math.round(segClimb.descent * 10) / 10,
      avg_slope_pct: Math.round(avgSlope * 10) / 10, cost: Math.round(cost * 100) / 100,
    };
  });

  const pct = (x) => Math.round((x / (total || 1)) * 1000) / 10;

  // --- Avertissements et fiabilité -------------------------------------------
  const warnings = [];
  if (shares.uncertain > 0) warnings.push({ level: 'restriction', text: `${Math.round(shares.uncertain)} m dont l'accès en trottinette est incertain (zone piétonne ou route > 50 km/h sans aménagement)` });
  if (shares.works > 0) warnings.push({ level: 'difficulty', text: `Traverse ${worksHits.size} chantier(s) perturbant(s) signalé(s) par la Métropole` });
  if (shares.unpaved > 0) warnings.push({ level: 'difficulty', text: `${Math.round(shares.unpaved)} m non revêtus` });
  if (shares.cobbles > 50) warnings.push({ level: 'difficulty', text: `${Math.round(shares.cobbles)} m de pavés` });
  if (slopes.up >= 8) warnings.push({ level: 'difficulty', text: `Montée raide jusqu'à ${Math.round(slopes.up)} %` });
  if (slopes.down >= 10) warnings.push({ level: 'difficulty', text: `Descente raide jusqu'à ${Math.round(slopes.down)} % : prudence au freinage` });

  let score = 100;
  const reasons = [];
  if (!ctx.ignProfile) { score -= 20; reasons.push('Altitude SRTM (précision ~10 m) : IGN indisponible'); }
  const unk = pct(shares.unknownSurface);
  if (unk > 20) { score -= Math.min(25, unk * 0.3); reasons.push(`Revêtement inconnu sur ${unk} % du trajet`); }
  if (shares.uncertain > 0) { score -= 25; reasons.push('Accès trottinette incertain sur une partie du trajet'); }
  if (!ctx.worksMeta?.available) { score -= 10; reasons.push('Données travaux indisponibles'); }
  const level = score >= 75 ? 'high' : score >= 50 ? 'medium' : 'low';

  const step = Math.max(1, Math.ceil(series.length / 300));
  const elevationProfile = series.filter((_, i) => i % step === 0 || i === series.length - 1)
    .map((s) => [Math.round(s.d), Math.round(s.z * 10) / 10]);

  const instructions = (path.instructions || []).map((ins) => ({
    text: ins.text,
    street: ins.street_name || '',
    sign: ins.sign,
    distance_m: Math.round(ins.distance),
    duration_s: Math.round(ins.time / 1000),
    point_index: ins.interval?.[0] ?? 0,
    end_index: ins.interval?.[1] ?? 0,
    exit_number: ins.exit_number ?? null,
  }));

  return {
    profile: ctx.profileId,
    label: ctx.label,
    distance_m: Math.round(path.distance),
    duration_s: Math.round(path.time / 1000),
    ascent_m: Math.round(ascent),
    descent_m: Math.round(descent),
    max_slope_up_pct: Math.round(slopes.up * 10) / 10,
    max_slope_down_pct: Math.round(slopes.down * 10) / 10,
    engine_ascent_m: Math.round(path.ascend ?? 0),
    cost: Math.round(totalCost * 10) / 10,
    shares: {
      cycle_infra_pct: pct(shares.cycle), unpaved_pct: pct(shares.unpaved), cobbles_pct: pct(shares.cobbles),
      unknown_surface_pct: unk, access_uncertain_m: Math.round(shares.uncertain), works_m: Math.round(shares.works),
    },
    road_types: Object.entries(byRoadClass)
      .sort((a, b) => b[1] - a[1])
      .map(([k, v]) => ({ road_class: k, label: ROAD_CLASS_FR[k] ?? k, pct: pct(v) })),
    works: [...worksHits.values()],
    warnings,
    reliability: { level, score: Math.max(0, Math.round(score)), reasons, elevation_source: elevationSource },
    geometry: coords.map((c) => [Math.round(c[0] * 1e6) / 1e6, Math.round(c[1] * 1e6) / 1e6]),
    elevation_profile: elevationProfile,
    instructions,
    segments: outSegments,
  };
}

/** Taux de recouvrement entre deux géométries (échantillonnées) pour détecter les doublons. */
export function overlapRatio(geomA, geomB, tolM = 15) {
  const cumA = cumulativeDistances(geomA);
  const lenA = cumA[cumA.length - 1];
  if (!lenA) return 1;
  const n = Math.min(80, Math.max(10, Math.round(lenA / 50)));
  let hit = 0;
  for (let k = 0; k <= n; k++) {
    const p = pointAtDistance(geomA, cumA, (lenA * k) / n);
    if (distanceToPolyline(p, geomB) <= tolM) hit++;
  }
  return hit / (n + 1);
}

/** Distance (m) d'un point à une polyligne, projection équirectangulaire locale. */
export function distanceToPolyline(p, line) {
  const kx = 111320 * Math.cos((p[1] * Math.PI) / 180), ky = 110540;
  let best = Infinity;
  for (let i = 0; i < line.length - 1; i++) {
    const ax = (line[i][0] - p[0]) * kx, ay = (line[i][1] - p[1]) * ky;
    const bx = (line[i + 1][0] - p[0]) * kx, by = (line[i + 1][1] - p[1]) * ky;
    const dx = bx - ax, dy = by - ay;
    const len2 = dx * dx + dy * dy;
    let t = len2 ? -(ax * dx + ay * dy) / len2 : 0;
    t = Math.max(0, Math.min(1, t));
    const d = Math.hypot(ax + t * dx, ay + t * dy);
    if (d < best) best = d;
  }
  if (line.length === 1) best = Math.hypot((line[0][0] - p[0]) * kx, (line[0][1] - p[1]) * ky);
  return best;
}
