import test from 'node:test';
import assert from 'node:assert/strict';
import { analyzePath, climbStats, maxSlopes, fixStructures, overlapRatio } from '../src/analysis.js';
import { PROFILE_PRESETS } from '../src/profiles.js';
import { fakePath } from './helpers.js';

const ctx = (extra = {}) => ({
  profileId: 'balanced', label: 'Équilibré', ignProfile: null, works: [],
  worksMeta: { available: true }, weights: PROFILE_PRESETS.balanced.weights, ...extra,
});

test('climbStats ignore le bruit sous le seuil', () => {
  const s = [0, 0.5, -0.4, 0.6, 0.2].map((z, i) => ({ d: i * 20, z: 100 + z }));
  assert.deepEqual(climbStats(s), { ascent: 0, descent: 0 });
});

test('climbStats : montée puis descente ne se compensent pas', () => {
  const s = [0, 10, 20, 10, 0].map((z, i) => ({ d: i * 50, z }));
  const r = climbStats(s);
  assert.equal(r.ascent, 20);
  assert.equal(r.descent, 20);
});

test('maxSlopes mesure la pente sur au moins 40 m', () => {
  // 8 % de pente régulière
  const s = Array.from({ length: 20 }, (_, i) => ({ d: i * 20, z: 100 + i * 1.6 }));
  const { up, down } = maxSlopes(s, 40);
  assert.ok(Math.abs(up - 8) < 0.01);
  assert.equal(down, 0);
});

test('fixStructures : un pont ne plonge pas jusqu\'à la rivière', () => {
  const s = [170, 170, 162, 160, 162, 170, 170].map((z, i) => ({ d: i * 20, z }));
  const fixed = fixStructures(s, [[20, 100]]);
  assert.ok(fixed.every((p) => p.z >= 169.9));
});

test('analyzePath : trajet plat sur piste cyclable', () => {
  const p = fakePath({ details: { road_class: [[0, 40, 'CYCLEWAY']] } });
  const r = analyzePath(p, ctx());
  assert.equal(r.ascent_m, 0);
  assert.equal(r.shares.cycle_infra_pct, 100);
  assert.equal(r.reliability.elevation_source, 'SRTM (via GraphHopper)');
  assert.equal(r.geometry.length, 41);
  assert.equal(r.instructions[0].point_index, 0);
  assert.ok(r.segments.length === 1 && r.segments[0].road_type === 'Piste cyclable');
});

test('analyzePath : montée régulière de 30 m détectée', () => {
  const p = fakePath({ ele: (i) => 170 + i * 0.75 }); // 30 m sur ~1,5 km (~2 %)
  const r = analyzePath(p, ctx());
  assert.ok(r.ascent_m >= 27 && r.ascent_m <= 31, `ascent=${r.ascent_m}`);
  assert.ok(r.descent_m <= 1);
});

test('analyzePath : altitude IGN prioritaire sur SRTM', () => {
  const p = fakePath();
  const samples = Array.from({ length: 76 }, (_, i) => ({ d: i * 20, z: 170 + (i > 40 ? 12 : 0) }));
  const r = analyzePath(p, ctx({ ignProfile: { samples, source: 'IGN RGE ALTI' } }));
  assert.equal(r.reliability.elevation_source, 'IGN RGE ALTI');
  assert.ok(r.ascent_m >= 11);
});

test('analyzePath : accès incertain et chantier signalés', () => {
  const p = fakePath({ details: { get_off_bike: [[0, 10, true], [10, 40, false]] } });
  const ring = [[4.840, 45.757], [4.846, 45.757], [4.846, 45.759], [4.840, 45.759], [4.840, 45.757]];
  const works = [{ id: 'works_3', label: 'Réseau de chaleur', info: null, polys: [[ring]], bbox: [4.840, 45.757, 4.846, 45.759] }];
  const r = analyzePath(p, ctx({ works }));
  assert.ok(r.shares.access_uncertain_m > 300);
  assert.equal(r.works.length, 1);
  assert.equal(r.works[0].label, 'Réseau de chaleur');
  assert.ok(r.warnings.some((w) => w.level === 'restriction'));
  assert.notEqual(r.reliability.level, 'high');
});

test('overlapRatio : identique = 1, parallèle à 300 m = 0', () => {
  const a = fakePath().points.coordinates;
  const b = fakePath({ lat: 45.7605 }).points.coordinates;
  assert.equal(overlapRatio(a, a), 1);
  assert.equal(overlapRatio(a, b), 0);
});

test('analyzePath : valeurs GraphHopper en minuscules et trajet de longueur nulle', () => {
  const p = fakePath({ details: {
    road_class: [[0, 40, 'footway']], surface: [[0, 40, 'fine_gravel']], bike_network: [[0, 40, 'missing']],
  } });
  const r = analyzePath(p, ctx());
  assert.equal(r.shares.cycle_infra_pct, 0);
  assert.equal(r.shares.unpaved_pct, 100);
  assert.equal(r.segments[0].road_type, 'Voie piétonne');
  const zero = fakePath({ n: 2, stepDeg: 0 });
  zero.distance = 0; zero.time = 0;
  const z = analyzePath(zero, ctx());
  assert.ok(Number.isFinite(z.cost) && z.segments.every((s) => Number.isFinite(s.duration_s)));
});
