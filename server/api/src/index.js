// API Scoot Route — point d'entrée HTTP (Node ≥ 22.13, sans dépendance externe)

import http from 'node:http';
import { createGraphHopperClient, RoutingError } from './graphhopper.js';
import { createElevationService } from './elevation.js';
import { createWorksService } from './works.js';
import { createReportStore, REPORT_TYPES } from './reports.js';
import { createPlanner } from './planner.js';
import { PROFILE_PRESETS } from './profiles.js';

export function loadConfig(env = process.env) {
  return {
    port: Number(env.PORT || 8080),
    ghUrl: env.GRAPHHOPPER_URL || 'http://localhost:8989',
    worksUrl: env.WORKS_GEOJSON_URL ?? 'https://www.data.gouv.fr/api/1/datasets/r/942ada51-f753-486d-8502-98c058313147',
    ignElevation: env.IGN_ELEVATION !== 'false',
    dbFile: env.REPORTS_DB || './data/reports.sqlite',
    adminToken: env.ADMIN_TOKEN || '',
    clientToken: env.CLIENT_TOKEN || '',
    coverageBbox: (env.COVERAGE_BBOX || '4.65,45.55,5.10,45.95').split(',').map(Number),
    rateLimitPerMin: Number(env.RATE_LIMIT_PER_MIN || 60),
  };
}

function rateLimiter(perMin) {
  const buckets = new Map();
  return (key) => {
    const now = Date.now();
    const b = buckets.get(key) ?? { tokens: perMin, at: now };
    b.tokens = Math.min(perMin, b.tokens + ((now - b.at) / 60000) * perMin);
    b.at = now;
    if (b.tokens < 1) { buckets.set(key, b); return false; }
    b.tokens -= 1;
    buckets.set(key, b);
    if (buckets.size > 10000) buckets.clear();
    return true;
  };
}

async function readJson(req, limit = 64 * 1024) {
  let size = 0;
  const chunks = [];
  for await (const c of req) {
    size += c.length;
    if (size > limit) throw Object.assign(new Error('Requête trop volumineuse'), { status: 413 });
    chunks.push(c);
  }
  if (!chunks.length) return {};
  try { return JSON.parse(Buffer.concat(chunks).toString('utf8')); }
  catch { throw Object.assign(new Error('JSON invalide'), { status: 400 }); }
}

function send(res, status, body) {
  const data = JSON.stringify(body);
  res.writeHead(status, { 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store' });
  res.end(data);
}

export function createApp({ config, gh, elevation, works, reports, logger = console }) {
  const planner = createPlanner({ gh, elevation, works, reports, coverageBbox: config.coverageBbox, logger });
  const allow = rateLimiter(config.rateLimitPerMin);

  const isAdmin = (req) => config.adminToken && req.headers.authorization === `Bearer ${config.adminToken}`;

  return async function handler(req, res) {
    const url = new URL(req.url, 'http://local');
    const path = url.pathname;
    try {
      if (path === '/health') return send(res, 200, { ok: true });

      if (path.startsWith('/v1/')) {
        if (config.clientToken && req.headers['x-client-token'] !== config.clientToken) {
          return send(res, 401, { error: 'unauthorized', message: 'Jeton client invalide' });
        }
        const ip = req.headers['x-forwarded-for']?.split(',')[0].trim() || req.socket.remoteAddress;
        if (!allow(ip)) return send(res, 429, { error: 'rate_limited', message: 'Trop de requêtes' });
      }

      if (req.method === 'GET' && path === '/v1/meta') {
        return send(res, 200, {
          map: await planner.mapInfo(),
          works: works.meta(),
          coverage_bbox: config.coverageBbox,
          profiles: PROFILE_PRESETS,
          report_types: Object.fromEntries(Object.entries(REPORT_TYPES).map(([k, v]) => [k, v.label])),
          elevation_source: config.ignElevation ? 'IGN RGE ALTI (repli SRTM)' : 'SRTM',
        });
      }

      if (req.method === 'POST' && path === '/v1/routes') {
        const body = await readJson(req);
        return send(res, 200, await planner.plan(body));
      }

      if (req.method === 'POST' && path === '/v1/reports') {
        const b = await readJson(req);
        const created = reports.create({
          type: b.type, lat: Number(b.lat), lon: Number(b.lon), comment: b.comment, deviceId: String(b.device_id || '').slice(0, 64),
        });
        return send(res, 201, created);
      }
      if (req.method === 'GET' && path === '/v1/reports/mine') {
        const id = url.searchParams.get('device_id');
        if (!id) return send(res, 400, { error: 'bad_request', message: 'device_id requis' });
        return send(res, 200, { reports: reports.listForDevice(id) });
      }

      // Modération (ADMIN_TOKEN)
      if (path.startsWith('/admin/')) {
        if (!isAdmin(req)) return send(res, 401, { error: 'unauthorized' });
        if (req.method === 'GET' && path === '/admin/reports') {
          return send(res, 200, { reports: reports.list(url.searchParams.get('status') || 'pending') });
        }
        const m = path.match(/^\/admin\/reports\/(\d+)\/(validate|reject)$/);
        if (req.method === 'POST' && m) {
          const b = await readJson(req);
          reports.review(Number(m[1]), m[2] === 'validate' ? 'validated' : 'rejected', Number(b.ttl_days) || 14);
          return send(res, 200, { ok: true });
        }
        if (req.method === 'POST' && path === '/admin/works/refresh') {
          await works.refresh();
          return send(res, 200, works.meta());
        }
      }

      return send(res, 404, { error: 'not_found' });
    } catch (e) {
      const status = e.status || (e instanceof RoutingError ? 502 : 500);
      if (status >= 500) logger.error?.(e);
      return send(res, status, { error: e.code || 'error', message: e.message });
    }
  };
}

// Démarrage (sauf import par les tests)
if (import.meta.url === `file://${process.argv[1]}`) {
  const config = loadConfig();
  const gh = createGraphHopperClient({ baseUrl: config.ghUrl });
  const elevation = createElevationService({ enabled: config.ignElevation });
  const works = createWorksService({ url: config.worksUrl });
  const reports = createReportStore(config.dbFile);
  works.start();
  if (!config.adminToken) console.warn('⚠️  ADMIN_TOKEN non défini : la modération des signalements est désactivée');
  http.createServer(createApp({ config, gh, elevation, works, reports }))
    .listen(config.port, () => console.log(`Scoot Route API sur :${config.port} → GraphHopper ${config.ghUrl}`));
}
