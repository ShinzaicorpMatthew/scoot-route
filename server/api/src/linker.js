// Liaison automatique app ↔ serveur.
//
// Le tunnel Cloudflare gratuit change d'adresse à chaque démarrage. Ce module :
//  1. lit l'adresse publique du tunnel (service « tunnel » du docker-compose) ;
//  2. la publie, signée, sur un canal ntfy.sh dont le nom dérive d'un code de liaison secret ;
//  3. l'app iPhone, qui connaît le même code, lit ce canal, vérifie la signature et se met à jour.
// Le code de liaison est généré au premier démarrage et affiché sur http://localhost:8080/liaison.

import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';

const ALPHABET = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'; // sans 0/O ni 1/I

export function generateCode() {
  const bytes = crypto.randomBytes(12);
  const chars = [...bytes].map((b) => ALPHABET[b % ALPHABET.length]).join('');
  return `${chars.slice(0, 4)}-${chars.slice(4, 8)}-${chars.slice(8, 12)}`;
}

export function normalizeCode(code) {
  return String(code || '').toUpperCase().replace(/[^A-Z0-9]/g, '');
}

/** Nom du canal ntfy (impossible à deviner sans le code). */
export function topicFor(code) {
  return 'scootroute-' + crypto.createHash('sha256').update(normalizeCode(code)).digest('hex').slice(0, 24);
}

export function sign(code, url, ts) {
  return crypto.createHmac('sha256', normalizeCode(code)).update(`${url}|${ts}`).digest('hex');
}

/** Extrait l'adresse *.trycloudflare.com d'une réponse du serveur de métriques de cloudflared. */
export function extractTunnelUrl(text) {
  const m = String(text || '').match(/([a-z0-9-]+\.trycloudflare\.com)/i);
  return m ? `https://${m[1].toLowerCase()}` : null;
}

export function loadOrCreateCode(dataDir) {
  const file = path.join(dataDir, 'liaison.json');
  try {
    const saved = JSON.parse(fs.readFileSync(file, 'utf8'));
    if (saved.code) return saved.code;
  } catch { /* premier démarrage */ }
  const code = generateCode();
  fs.mkdirSync(dataDir, { recursive: true });
  fs.writeFileSync(file, JSON.stringify({ code, created_at: new Date().toISOString() }));
  return code;
}

export function createLinker({ code, metricsUrl, ntfyBase = 'https://ntfy.sh', fetchImpl = fetch,
  checkEveryMs = 60_000, republishEveryMs = 30 * 60_000, logger = console }) {
  const state = { url: null, publishedAt: 0, lastError: null };
  const topic = topicFor(code);

  async function readTunnelUrl() {
    for (const p of ['/quicktunnel', '/metrics']) {
      try {
        const res = await fetchImpl(`${metricsUrl}${p}`, { signal: AbortSignal.timeout(4000) });
        if (!res.ok) continue;
        const url = extractTunnelUrl(await res.text());
        if (url) return url;
      } catch { /* tunnel pas encore prêt */ }
    }
    return null;
  }

  async function publish(url) {
    const ts = Math.floor(Date.now() / 1000);
    const body = JSON.stringify({ url, ts, sig: sign(code, url, ts) });
    const res = await fetchImpl(`${ntfyBase}/${topic}`, {
      method: 'POST', body, headers: { 'content-type': 'text/plain' }, signal: AbortSignal.timeout(8000),
    });
    if (!res.ok) throw new Error(`ntfy HTTP ${res.status}`);
  }

  async function tick() {
    if (!metricsUrl) return;
    const url = await readTunnelUrl();
    if (!url) return;
    const changed = url !== state.url;
    if (changed || Date.now() - state.publishedAt > republishEveryMs) {
      try {
        await publish(url);
        state.url = url;
        state.publishedAt = Date.now();
        state.lastError = null;
        if (changed) logger.info?.(`[liaison] adresse publique : ${url}`);
      } catch (e) {
        state.lastError = e.message;
        logger.warn?.(`[liaison] publication impossible : ${e.message}`);
      }
    }
  }

  let timer = null;
  return {
    code, topic, tick, state,
    start() { tick(); timer = setInterval(tick, checkEveryMs); timer.unref?.(); },
    stop() { if (timer) clearInterval(timer); },
  };
}

/** Page affichée sur le PC (http://localhost:8080/liaison). */
export function pairingPage(code, url) {
  const esc = (s) => String(s).replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' })[c]);
  return `<!doctype html><html lang="fr"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Scoot Route – liaison</title>
<style>body{font-family:system-ui,sans-serif;max-width:640px;margin:40px auto;padding:0 16px;background:#0f172a;color:#e2e8f0}
.code{font-size:44px;font-weight:800;letter-spacing:4px;background:#1e293b;padding:20px;border-radius:14px;text-align:center;margin:20px 0}
.ok{color:#4ade80}.wait{color:#fbbf24}li{margin:8px 0}</style></head><body>
<h1>Scoot Route</h1>
<p>Code de liaison à saisir une seule fois dans l'app (Réglages › Liaison automatique) :</p>
<div class="code">${esc(code)}</div>
<p>Adresse publique actuelle : ${url ? `<b class="ok">${esc(url)}</b>` : '<b class="wait">tunnel en cours de démarrage… rechargez dans une minute</b>'}</p>
<ol><li>L'app retrouve seule l'adresse à chaque redémarrage du PC.</li>
<li>Ne partagez pas ce code : il permet d'utiliser votre serveur.</li></ol>
</body></html>`;
}
