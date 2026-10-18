import test from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { createLinker, extractTunnelUrl, generateCode, loadOrCreateCode, sign, topicFor, normalizeCode } from '../src/linker.js';
import { createApp, loadConfig } from '../src/index.js';
import { createReportStore } from '../src/reports.js';
import { createWorksService } from '../src/works.js';
import { silentLogger } from './helpers.js';

test('code de liaison : format, canal stable, signature', () => {
  const code = generateCode();
  assert.match(code, /^[A-Z2-9]{4}-[A-Z2-9]{4}-[A-Z2-9]{4}$/);
  assert.equal(topicFor(code), topicFor(code.toLowerCase().replace(/-/g, ' ')));
  assert.equal(normalizeCode('ab12-cd34'), 'AB12CD34');
  assert.notEqual(sign(code, 'https://a.trycloudflare.com', 1), sign(code, 'https://b.trycloudflare.com', 1));
});

test('extraction de l\'adresse du tunnel (quicktunnel JSON ou métriques Prometheus)', () => {
  assert.equal(extractTunnelUrl('{"hostname":"Morning-Friendly.trycloudflare.com"}'), 'https://morning-friendly.trycloudflare.com');
  assert.equal(extractTunnelUrl('cloudflared_tunnel_user_hostnames_counts{userHostname="https://abc-def.trycloudflare.com"} 1'),
    'https://abc-def.trycloudflare.com');
  assert.equal(extractTunnelUrl('# rien'), null);
});

test('le code est conservé entre deux démarrages', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'liaison-'));
  assert.equal(loadOrCreateCode(dir), loadOrCreateCode(dir));
});

test('publication signée sur ntfy quand l\'adresse change', async () => {
  const posts = [];
  const fakeFetch = async (url, opts = {}) => {
    if (url.endsWith('/quicktunnel')) return new Response('{"hostname":"new-url.trycloudflare.com"}');
    if (url.startsWith('https://ntfy.test/')) { posts.push({ url, body: opts.body }); return new Response('{}'); }
    return new Response('', { status: 404 });
  };
  const linker = createLinker({ code: 'ABCD-EFGH-JKLM', metricsUrl: 'http://tunnel:2000', ntfyBase: 'https://ntfy.test',
    fetchImpl: fakeFetch, logger: silentLogger });
  await linker.tick();
  await linker.tick(); // inchangée : pas de nouvelle publication
  assert.equal(posts.length, 1);
  assert.equal(posts[0].url, `https://ntfy.test/${topicFor('ABCD-EFGH-JKLM')}`);
  const msg = JSON.parse(posts[0].body);
  assert.equal(msg.url, 'https://new-url.trycloudflare.com');
  assert.equal(msg.sig, sign('ABCD-EFGH-JKLM', msg.url, msg.ts));
});

test('la page /liaison n\'est jamais servie à travers le tunnel', async () => {
  const works = createWorksService({ url: '', logger: silentLogger });
  const linker = { code: 'ABCD-EFGH-JKLM', state: { url: null } };
  const app = createApp({ config: loadConfig({}), gh: {}, elevation: {}, works, reports: createReportStore(':memory:'),
    linker, logger: silentLogger });
  const server = http.createServer(app);
  await new Promise((r) => server.listen(0, r));
  const base = `http://127.0.0.1:${server.address().port}`;
  try {
    const local = await fetch(`${base}/liaison`);
    assert.equal(local.status, 200);
    assert.match(await local.text(), /ABCD-EFGH-JKLM/);
    const viaTunnel = await fetch(`${base}/liaison`, { headers: { 'cf-ray': '123-MRS' } });
    assert.equal(viaTunnel.status, 404);
  } finally { server.close(); }
});
