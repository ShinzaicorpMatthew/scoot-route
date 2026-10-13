// Signalements des livreurs, avec modération avant d'influencer le routage commun.
// Stockage SQLite (module natif node:sqlite, Node ≥ 22.13).

import { DatabaseSync } from 'node:sqlite';
import { squareAround } from './geo.js';

export const REPORT_TYPES = {
  closed: { label: 'Chemin fermé', blocks: true },
  works: { label: 'Travaux', blocks: false },
  no_access: { label: 'Accès impossible', blocks: true },
  steep: { label: 'Pente excessive', blocks: false },
  missing_cycleway: { label: 'Piste cyclable manquante', blocks: false },
  impassable_cycleway: { label: 'Piste impraticable', blocks: false },
  map_error: { label: 'Erreur cartographique', blocks: false },
};

export function createReportStore(file = ':memory:') {
  const db = new DatabaseSync(file);
  db.exec(`
    CREATE TABLE IF NOT EXISTS reports (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      type TEXT NOT NULL,
      lat REAL NOT NULL,
      lon REAL NOT NULL,
      comment TEXT,
      device_id TEXT,
      status TEXT NOT NULL DEFAULT 'pending',
      created_at TEXT NOT NULL,
      reviewed_at TEXT,
      expires_at TEXT
    );
    CREATE INDEX IF NOT EXISTS idx_reports_status ON reports(status);
  `);

  const insert = db.prepare(
    'INSERT INTO reports (type, lat, lon, comment, device_id, created_at) VALUES (?, ?, ?, ?, ?, ?)');
  const byStatus = db.prepare('SELECT * FROM reports WHERE status = ? ORDER BY created_at DESC LIMIT 500');
  const byDevice = db.prepare('SELECT * FROM reports WHERE device_id = ? ORDER BY created_at DESC LIMIT 100');
  const setStatus = db.prepare('UPDATE reports SET status = ?, reviewed_at = ?, expires_at = ? WHERE id = ?');
  const activeBlocking = db.prepare(
    `SELECT * FROM reports WHERE status = 'validated' AND (expires_at IS NULL OR expires_at > ?)`);
  const recentByDevice = db.prepare('SELECT COUNT(*) AS n FROM reports WHERE device_id = ? AND created_at > ?');

  return {
    create({ type, lat, lon, comment, deviceId }) {
      if (!REPORT_TYPES[type]) throw Object.assign(new Error('Type de signalement inconnu'), { status: 400 });
      if (![lat, lon].every(Number.isFinite)) throw Object.assign(new Error('Position invalide'), { status: 400 });
      const since = new Date(Date.now() - 3600_000).toISOString();
      if (deviceId && recentByDevice.get(deviceId, since).n >= 20) {
        throw Object.assign(new Error('Trop de signalements, réessayez plus tard'), { status: 429 });
      }
      const now = new Date().toISOString();
      const r = insert.run(type, lat, lon, (comment || '').slice(0, 500), deviceId || null, now);
      return { id: Number(r.lastInsertRowid), status: 'pending', created_at: now };
    },
    list(status = 'pending') { return byStatus.all(status); },
    listForDevice(deviceId) { return byDevice.all(deviceId); },
    review(id, status, ttlDays = 14) {
      if (!['validated', 'rejected'].includes(status)) throw Object.assign(new Error('Statut invalide'), { status: 400 });
      const now = new Date();
      const expires = status === 'validated' ? new Date(now.getTime() + ttlDays * 86400_000).toISOString() : null;
      const r = setStatus.run(status, now.toISOString(), expires, id);
      if (r.changes === 0) throw Object.assign(new Error('Signalement introuvable'), { status: 404 });
    },
    /** Fermetures validées et encore actives, sous forme de zones d'exclusion (~30 m). */
    closuresNear(b) {
      return activeBlocking.all(new Date().toISOString())
        .filter((r) => REPORT_TYPES[r.type]?.blocks)
        .filter((r) => r.lon >= b[0] && r.lon <= b[2] && r.lat >= b[1] && r.lat <= b[3])
        .map((r) => ({ id: `closure_${r.id}`, geometry: squareAround([r.lon, r.lat], 15), report: r }));
    },
    validatedNear(b) {
      return activeBlocking.all(new Date().toISOString())
        .filter((r) => r.lon >= b[0] && r.lon <= b[2] && r.lat >= b[1] && r.lat <= b[3]);
    },
    close() { db.close(); },
  };
}
