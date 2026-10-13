import test from 'node:test';
import assert from 'node:assert/strict';
import { parseWorks, parseDate } from '../src/works.js';
import { createReportStore } from '../src/reports.js';

const ring = [[4.83, 45.75], [4.831, 45.75], [4.831, 45.751], [4.83, 45.751], [4.83, 45.75]];
const feature = (props) => ({ type: 'Feature', properties: props, geometry: { type: 'Polygon', coordinates: [ring] } });

test('parseDate accepte ISO et JJ/MM/AAAA', () => {
  assert.equal(parseDate('2026-10-01').getUTCFullYear(), 2026);
  assert.equal(parseDate('01/10/2026').getMonth(), 9);
  assert.equal(parseDate(''), null);
});

test('parseWorks ne garde que les chantiers actifs', () => {
  const now = new Date('2026-10-13T12:00:00');
  const fc = { type: 'FeatureCollection', features: [
    feature({ libelle: 'Actif', date_debut: '2026-10-01', date_fin: '2026-11-30' }),
    feature({ libelle: 'Terminé', date_debut: '2026-01-01', date_fin: '2026-02-01' }),
    feature({ libelle: 'Futur', date_debut: '2027-01-01', date_fin: '2027-02-01' }),
    feature({ libelle: 'Finit aujourd\'hui', date_debut: '2026-10-01', date_fin: '2026-10-13' }),
  ] };
  const r = parseWorks(fc, now);
  assert.deepEqual(r.works.map((w) => w.label), ['Actif', 'Finit aujourd\'hui']);
  assert.equal(r.detected.startKey, 'date_debut');
});

test('parseWorks ignore les géométries non WGS84', () => {
  const fc = { features: [{ properties: {}, geometry: { type: 'Polygon', coordinates: [[[842000, 6519000], [842100, 6519000], [842100, 6519100], [842000, 6519000]]] } }] };
  assert.equal(parseWorks(fc).skippedCrs, 1);
});

test('signalements : création, modération, zone d\'exclusion', () => {
  const store = createReportStore(':memory:');
  const { id } = store.create({ type: 'closed', lat: 45.76, lon: 4.84, comment: 'Barrières', deviceId: 'dev1' });
  assert.equal(store.list('pending').length, 1);
  // pas d'effet sur le routage tant que non validé
  assert.equal(store.closuresNear([4.8, 45.7, 4.9, 45.8]).length, 0);
  store.review(id, 'validated');
  const closures = store.closuresNear([4.8, 45.7, 4.9, 45.8]);
  assert.equal(closures.length, 1);
  assert.equal(closures[0].id, `closure_${id}`);
  assert.equal(store.listForDevice('dev1')[0].status, 'validated');
  assert.throws(() => store.create({ type: 'inconnu', lat: 1, lon: 1 }));
  store.close();
});

test('un signalement non bloquant n\'exclut pas de voie', () => {
  const store = createReportStore(':memory:');
  const { id } = store.create({ type: 'steep', lat: 45.76, lon: 4.84 });
  store.review(id, 'validated');
  assert.equal(store.closuresNear([4.8, 45.7, 4.9, 45.8]).length, 0);
  assert.equal(store.validatedNear([4.8, 45.7, 4.9, 45.8]).length, 1);
  store.close();
});
