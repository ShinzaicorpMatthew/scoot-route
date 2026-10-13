// Construction des modèles de coût (custom models GraphHopper) pour chaque profil.
//
// GraphHopper calcule pour chaque tronçon un poids de la forme :
//     poids = durée / priorité + distance × distance_influence
// Nos critères y sont traduits ainsi :
//   - temps     → durée du tronçon (vitesse trottinette, ralentie en montée / sur pavés)
//   - distance  → distance_influence (secondes "coûtées" par km supplémentaire)
//   - montée    → réduction de priorité selon la pente moyenne POSITIVE du tronçon
//   - pente     → réduction supplémentaire selon la pente maximale (rampes raides)
//   - surface   → réduction de priorité sur pavés / non revêtu / revêtement dégradé
//   - sécurité  → réduction sur grands axes sans aménagement cyclable
//   - restrictions et chantiers → priorité nulle (exclusion) ou très réduite
// Les poids utilisateur (0..1) sont donc normalisés en facteurs sans unité, ce qui rend
// comparables secondes, kilomètres et mètres de dénivelé.
//
// Une descente n'apporte jamais de bonus : aucune règle n'augmente la priorité ou la
// vitesse quand la pente est négative (le modèle de base limite même la vitesse).

export const PROFILE_IDS = ['fast', 'eco', 'balanced'];

export const PROFILE_PRESETS = {
  fast: { label: 'Rapide', weights: { time: 1.0, distance: 0.3, climb: 0.1, slope: 0.3, surface: 0.4, safety: 0.5 } },
  eco: { label: 'Éco', weights: { time: 0.2, distance: 0.5, climb: 1.0, slope: 1.0, surface: 0.5, safety: 0.5 } },
  balanced: { label: 'Équilibré', weights: { time: 0.5, distance: 0.5, climb: 0.6, slope: 0.6, surface: 0.5, safety: 0.6 } },
};

const CRITERIA = ['time', 'distance', 'climb', 'slope', 'surface', 'safety'];

export function sanitizeWeights(w, fallback) {
  const out = {};
  for (const k of CRITERIA) {
    const v = Number(w?.[k]);
    out[k] = Number.isFinite(v) ? Math.min(1, Math.max(0, v)) : fallback[k];
  }
  return out;
}

const clampFactor = (x) => Math.max(0.03, Math.min(1, Math.round(x * 100) / 100));

/**
 * @param {object} weights critères 0..1
 * @param {object} opts { maxSpeedKmh, areas: {works:[{id,geometry}], closures:[{id,geometry}]} }
 */
export function buildCustomModel(weights, opts = {}) {
  // Plus le temps compte, moins les autres pénalités pèsent (normalisation relative).
  const damp = 1 - 0.6 * weights.time;
  const w = {
    distance: weights.distance,
    climb: weights.climb * damp,
    slope: weights.slope * damp,
    surface: weights.surface * damp,
    safety: weights.safety * damp,
  };

  const priority = [];
  // Montée : pente moyenne positive dans le sens de circulation
  const climbBands = [
    ['average_slope > 9', 0.9],
    ['average_slope > 6', 0.72],
    ['average_slope > 4', 0.5],
    ['average_slope > 2', 0.25],
  ];
  climbBands.forEach(([cond, k], i) => {
    const f = clampFactor(1 - w.climb * k);
    if (f < 1) priority.push({ [i === 0 ? 'if' : 'else_if']: cond, multiply_by: String(f) });
  });
  // Rampes raides ponctuelles (pente maximale du tronçon)
  const f15 = clampFactor(1 - w.slope * 0.95);
  const f10 = clampFactor(1 - w.slope * 0.75);
  if (f15 < 1) priority.push({ if: 'max_slope > 15', multiply_by: String(f15) });
  if (f10 < 1) priority.push({ else_if: 'max_slope > 10', multiply_by: String(f10) });

  // Surface
  const fUnpaved = clampFactor(1 - w.surface * 0.85);
  const fCobble = clampFactor(1 - w.surface * 0.6);
  const fBadSmooth = clampFactor(1 - w.surface * 0.5);
  if (fUnpaved < 1) priority.push({
    if: 'surface == UNPAVED || surface == GRAVEL || surface == FINE_GRAVEL || surface == GROUND || surface == DIRT || surface == GRASS || surface == SAND || surface == COMPACTED',
    multiply_by: String(fUnpaved),
  });
  if (fCobble < 1) priority.push({ else_if: 'surface == COBBLESTONE', multiply_by: String(fCobble) });
  if (fBadSmooth < 1) priority.push({ if: 'smoothness == BAD || smoothness == VERY_BAD || smoothness == HORRIBLE || smoothness == VERY_HORRIBLE || smoothness == IMPASSABLE', multiply_by: String(fBadSmooth) });

  // Sécurité : grands axes sans piste/bande cyclable
  const fBigRoad = clampFactor(1 - w.safety * 0.6);
  const fMidRoad = clampFactor(1 - w.safety * 0.3);
  const noInfra = 'bike_network == MISSING';
  if (fBigRoad < 1) priority.push({ if: `road_class == PRIMARY && ${noInfra}`, multiply_by: String(fBigRoad) });
  if (fMidRoad < 1) priority.push({ else_if: `(road_class == SECONDARY || road_class == TERTIARY) && ${noInfra}`, multiply_by: String(fMidRoad) });

  // Chantiers et fermetures
  const areas = { type: 'FeatureCollection', features: [] };
  const works = opts.areas?.works ?? [];
  const closures = opts.areas?.closures ?? [];
  for (const a of [...works, ...closures]) {
    areas.features.push({ type: 'Feature', id: a.id, properties: {}, geometry: a.geometry });
  }
  if (closures.length) {
    priority.push({ if: closures.map((a) => `in_${a.id}`).join(' || '), multiply_by: '0' });
  }
  if (works.length) {
    // Un chantier "perturbant" n'est pas forcément fermé aux trottinettes : forte pénalité
    // plutôt qu'exclusion, et signalement dans l'analyse du trajet.
    priority.push({ if: works.map((a) => `in_${a.id}`).join(' || '), multiply_by: '0.2' });
  }

  const speed = [];
  const maxSpeed = Number(opts.maxSpeedKmh);
  if (Number.isFinite(maxSpeed) && maxSpeed > 0) {
    speed.push({ if: 'true', limit_to: String(Math.min(25, Math.max(6, Math.round(maxSpeed)))) });
  }

  const model = {
    distance_influence: Math.round(10 + 140 * w.distance),
    priority,
    speed,
  };
  if (areas.features.length) model.areas = areas;
  return model;
}
