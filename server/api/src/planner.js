// Orchestration : 3 profils (rapide / éco / équilibré) + alternatives, analyse et classement.

import { PROFILE_IDS, PROFILE_PRESETS, buildCustomModel, sanitizeWeights } from './profiles.js';
import { analyzePath, overlapRatio } from './analysis.js';
import { RoutingError } from './graphhopper.js';

const MARGIN_DEG = 0.015; // ≈ 1,5 km autour du trajet pour sélectionner chantiers et fermetures

function isSameRoute(a, b) {
  const dd = Math.abs(a.distance - b.distance) / Math.max(a.distance, b.distance, 1);
  if (dd > 0.03) return false;
  const ga = a.points.coordinates, gb = b.points.coordinates;
  return overlapRatio(ga, gb) > 0.92 && overlapRatio(gb, ga) > 0.92;
}

export function createPlanner({ gh, elevation, works, reports, coverageBbox, logger = console }) {
  let infoCache = { at: 0, value: null };

  async function mapInfo() {
    if (Date.now() - infoCache.at < 10 * 60_000 && infoCache.value) return infoCache.value;
    try {
      const info = await gh.info();
      infoCache = {
        at: Date.now(),
        value: {
          source: 'OpenStreetMap (© contributeurs OSM, ODbL)',
          data_date: info.data_date ?? info.import_date ?? null,
          import_date: info.import_date ?? null,
          engine: `GraphHopper ${info.version ?? ''}`.trim(),
          live: false,
        },
      };
    } catch (e) {
      logger.warn?.(`[info] ${e.message}`);
    }
    return infoCache.value;
  }

  function checkCoverage(pt, name) {
    const [lon, lat] = pt;
    if (![lon, lat].every(Number.isFinite)) throw new RoutingError(`${name} : coordonnées invalides`, { status: 400, code: 'bad_request' });
    if (coverageBbox && !(lon >= coverageBbox[0] && lon <= coverageBbox[2] && lat >= coverageBbox[1] && lat <= coverageBbox[3])) {
      throw new RoutingError(`${name} hors de la zone couverte (Lyon et sa métropole)`, { status: 422, code: 'out_of_coverage' });
    }
  }

  /**
   * @param req { from:{lat,lon}, to:{lat,lon}, weights?, max_speed_kmh?, profiles?, heading? }
   */
  async function plan(req) {
    const from = [Number(req.from?.lon), Number(req.from?.lat)];
    const to = [Number(req.to?.lon), Number(req.to?.lat)];
    checkCoverage(from, 'Départ');
    checkCoverage(to, 'Destination');

    const userWeights = sanitizeWeights(req.weights, PROFILE_PRESETS.balanced.weights);
    const profiles = Array.isArray(req.profiles) && req.profiles.length
      ? req.profiles.filter((p) => PROFILE_IDS.includes(p))
      : PROFILE_IDS;
    if (!profiles.length) throw new RoutingError('Profil inconnu', { status: 400, code: 'bad_request' });
    const isReroute = Number.isFinite(Number(req.heading));

    const bbox = [
      Math.min(from[0], to[0]) - MARGIN_DEG, Math.min(from[1], to[1]) - MARGIN_DEG,
      Math.max(from[0], to[0]) + MARGIN_DEG, Math.max(from[1], to[1]) + MARGIN_DEG,
    ];
    const worksNear = works.near(bbox);
    const closures = reports.closuresNear(bbox);

    const modelFor = (pid) => buildCustomModel(
      pid === 'balanced' ? userWeights : PROFILE_PRESETS[pid].weights,
      { maxSpeedKmh: req.max_speed_kmh, areas: { works: worksNear, closures } });

    const results = await Promise.allSettled(profiles.map((pid) =>
      gh.route(from, to, modelFor(pid), { heading: isReroute ? Number(req.heading) : undefined })));

    const candidates = [];
    results.forEach((r, i) => {
      if (r.status === 'fulfilled') candidates.push({ pid: profiles[i], path: r.value[0] });
      else logger.warn?.(`[route] profil ${profiles[i]} : ${r.reason?.message}`);
    });
    if (!candidates.length) {
      const first = results.find((r) => r.status === 'rejected');
      throw first?.reason ?? new RoutingError('Aucun itinéraire', { status: 422, code: 'no_route' });
    }

    // Fusion des profils qui produisent exactement le même trajet
    const distinct = [];
    for (const c of candidates) {
      const twin = distinct.find((d) => isSameRoute(d.path, c.path));
      if (twin) twin.alsoMatches.push(c.pid);
      else distinct.push({ ...c, alsoMatches: [] });
    }

    // Moins de 3 trajets distincts : on demande des alternatives réelles au moteur
    if (!isReroute && distinct.length < 3) {
      try {
        const alts = await gh.route(from, to, modelFor('balanced'), { alternatives: 3 });
        for (const p of alts) {
          if (distinct.length >= 3) break;
          if (!distinct.some((d) => isSameRoute(d.path, p))) distinct.push({ pid: 'alternative', path: p, alsoMatches: [] });
        }
      } catch (e) {
        logger.warn?.(`[route] alternatives : ${e.message}`);
      }
    }

    // Altitude IGN (séquentiel pour respecter la limite de 5 req/s)
    const routes = [];
    let altIndex = 0;
    for (const d of distinct) {
      const ign = await elevation.profile(d.path.points.coordinates);
      const label = d.pid === 'alternative' ? `Alternative ${++altIndex}` : PROFILE_PRESETS[d.pid].label;
      const analyzed = analyzePath(d.path, {
        profileId: d.pid, label, ignProfile: ign, works: worksNear, worksMeta: works.meta(), weights: userWeights,
      });
      analyzed.id = d.pid === 'alternative' ? `alt_${altIndex}` : d.pid;
      analyzed.also_matches = d.alsoMatches;
      routes.push(analyzed);
    }

    // Classement : coût multicritère calculé avec les poids de l'utilisateur
    const best = routes.reduce((a, b) => (b.cost < a.cost ? b : a));
    const fastest = routes.reduce((a, b) => (b.duration_s < a.duration_s ? b : a));
    const flattest = routes.reduce((a, b) => (b.ascent_m < a.ascent_m ? b : a));
    for (const r of routes) {
      r.badges = [];
      if (r === best) r.badges.push('recommended');
      if (r === fastest) r.badges.push('fastest');
      if (r === flattest) r.badges.push('least_climb');
    }

    return {
      routes,
      recommended_id: best.id,
      weights_used: userWeights,
      meta: {
        map: await mapInfo(),
        works: works.meta(),
        validated_reports_nearby: reports.validatedNear(bbox).map((r) => ({ id: r.id, type: r.type, lat: r.lat, lon: r.lon })),
        generated_at: new Date().toISOString(),
      },
    };
  }

  return { plan, mapInfo };
}
