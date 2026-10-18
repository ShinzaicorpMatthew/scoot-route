import test from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import { createApp, loadConfig } from '../src/index.js';
import { createReportStore } from '../src/reports.js';
import { createWorksService } from '../src/works.js';
import { createGraphHopperClient } from '../src/graphhopper.js';
import { fakePath, silentLogger } from './helpers.js';

// Faux moteur GraphHopper HTTP : renvoie le même trajet pour "fast" et "balanced",
// un trajet différent quand la pente est fortement pénalisée (éco), et des alternatives.
function startFakeGraphHopper() {
  const calls = [];
  const server = http.createServer(async (req, res) => {
    let body = '';
    for await (const c of req) body += c;
    const json = body ? JSON.parse(body) : null;
    calls.push({ url: req.url, body: json });
    res.setHeader('content-type', 'application/json');
    if (req.url === '/info') return res.end(JSON.stringify({ version: '11.0', data_date: '2026-10-12T21:00:00Z' }));
    if (json.points[0][0] > 5.5) { res.statusCode = 400; return res.end(JSON.stringify({ message: 'Point not found' })); }
    const climbFactor = Number(json.custom_model.priority.find((s) => (s.if ?? s.else_if) === 'average_slope > 4')?.multiply_by ?? 1);
    const direct = fakePath({ ele: (i) => 170 + i * 1.2, timeS: 420 });
    const detour = fakePath({ lat: 45.7605, n: 45, timeS: 520 });
    const third = fakePath({ lat: 45.763, n: 50, timeS: 600 });
    if (json.algorithm === 'alternative_route') return res.end(JSON.stringify({ paths: [direct, detour, third] }));
    res.end(JSON.stringify({ paths: [climbFactor < 0.6 ? detour : direct] }));
  });
  return new Promise((r) => server.listen(0, () => r({ server, calls, url: `http://127.0.0.1:${server.address().port}` })));
}

async function startApi(ghUrl, envOverrides = {}) {
  const config = { ...loadConfig({ ADMIN_TOKEN: 'secret', ...envOverrides }), ghUrl };
  const works = createWorksService({ url: '', logger: silentLogger });
  works._setForTests([]);
  const reports = createReportStore(':memory:');
  const app = createApp({
    config, works, reports, logger: silentLogger,
    gh: createGraphHopperClient({ baseUrl: ghUrl }),
    elevation: { profile: async () => null }, // repli SRTM
  });
  const server = http.createServer(app);
  await new Promise((r) => server.listen(0, r));
  return { server, url: `http://127.0.0.1:${server.address().port}`, reports };
}

const post = (url, body, headers = {}) =>
  fetch(url, { method: 'POST', headers: { 'content-type': 'application/json', ...headers }, body: JSON.stringify(body) });

test('POST /v1/routes renvoie 3 itinéraires distincts classés', async () => {
  const gh = await startFakeGraphHopper();
  const api = await startApi(gh.url);
  try {
    const res = await post(`${api.url}/v1/routes`, {
      from: { lat: 45.7578, lon: 4.832 }, to: { lat: 45.7578, lon: 4.85 }, max_speed_kmh: 22,
    });
    assert.equal(res.status, 200);
    const json = await res.json();
    assert.equal(json.routes.length, 3);
    const ids = json.routes.map((r) => r.id);
    assert.ok(ids.includes('fast') && ids.includes('eco'));
    // fast et balanced identiques → fusionnés, complétés par une alternative réelle du moteur
    assert.ok(json.routes.find((r) => r.id === 'fast').also_matches.includes('balanced'));
    assert.ok(ids.some((id) => id.startsWith('alt_')));
    assert.ok(json.routes.find((r) => r.id === 'eco').ascent_m < json.routes.find((r) => r.id === 'fast').ascent_m);
    assert.equal(json.routes.filter((r) => r.badges.includes('recommended')).length, 1);
    assert.equal(json.meta.map.data_date, '2026-10-12T21:00:00Z');
    // le modèle envoyé à GraphHopper contient la limite de vitesse de l'utilisateur
    const routeCall = gh.calls.find((c) => c.url === '/route');
    assert.equal(routeCall.body['ch.disable'], true);
    assert.deepEqual(routeCall.body.custom_model.speed[0], { if: 'true', limit_to: '22' });
  } finally { api.server.close(); gh.server.close(); }
});

test('recalcul (cap fourni) : un seul profil, pas d\'alternatives', async () => {
  const gh = await startFakeGraphHopper();
  const api = await startApi(gh.url);
  try {
    const res = await post(`${api.url}/v1/routes`, {
      from: { lat: 45.7578, lon: 4.832 }, to: { lat: 45.7578, lon: 4.85 }, profiles: ['eco'], heading: 90,
    });
    const json = await res.json();
    assert.equal(json.routes.length, 1);
    assert.equal(gh.calls.filter((c) => c.body?.algorithm).length, 0);
    assert.deepEqual(gh.calls.find((c) => c.url === '/route').body.headings, [90]);
  } finally { api.server.close(); gh.server.close(); }
});

test('hors zone couverte : 422 explicite', async () => {
  const gh = await startFakeGraphHopper();
  const api = await startApi(gh.url);
  try {
    const res = await post(`${api.url}/v1/routes`, { from: { lat: 48.85, lon: 2.35 }, to: { lat: 45.75, lon: 4.85 } });
    assert.equal(res.status, 422);
    assert.equal((await res.json()).error, 'out_of_coverage');
  } finally { api.server.close(); gh.server.close(); }
});

test('moteur injoignable : 503', async () => {
  const api = await startApi('http://127.0.0.1:9');
  try {
    const res = await post(`${api.url}/v1/routes`, { from: { lat: 45.75, lon: 4.83 }, to: { lat: 45.76, lon: 4.85 } });
    assert.equal(res.status, 503);
  } finally { api.server.close(); }
});

test('signalement puis modération via /admin', async () => {
  const gh = await startFakeGraphHopper();
  const api = await startApi(gh.url);
  try {
    const created = await (await post(`${api.url}/v1/reports`, { type: 'closed', lat: 45.76, lon: 4.84, device_id: 'abc' })).json();
    assert.equal(created.status, 'pending');
    assert.equal((await fetch(`${api.url}/admin/reports`)).status, 401);
    const ok = await post(`${api.url}/admin/reports/${created.id}/validate`, {}, { authorization: 'Bearer secret' });
    assert.equal(ok.status, 200);
    const mine = await (await fetch(`${api.url}/v1/reports/mine?device_id=abc`)).json();
    assert.equal(mine.reports[0].status, 'validated');
  } finally { api.server.close(); gh.server.close(); }
});

test('jeton client exigé quand configuré', async () => {
  const gh = await startFakeGraphHopper();
  const api = await startApi(gh.url, { CLIENT_TOKEN: 'tok' });
  try {
    assert.equal((await fetch(`${api.url}/v1/meta`)).status, 401);
    assert.equal((await fetch(`${api.url}/v1/meta`, { headers: { 'x-client-token': 'tok' } })).status, 200);
  } finally { api.server.close(); gh.server.close(); }
});

test('mode quick (analyse d\'offre) : un profil, pas d\'alternatives', async () => {
  const gh = await startFakeGraphHopper();
  const api = await startApi(gh.url);
  try {
    const res = await post(`${api.url}/v1/routes`, {
      from: { lat: 45.7578, lon: 4.832 }, to: { lat: 45.7578, lon: 4.85 }, profiles: ['balanced'], quick: true,
    });
    const json = await res.json();
    assert.equal(json.routes.length, 1);
    assert.equal(gh.calls.filter((c) => c.body?.algorithm).length, 0);
  } finally { api.server.close(); gh.server.close(); }
});
