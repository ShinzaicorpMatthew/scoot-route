import test from 'node:test';
import assert from 'node:assert/strict';
import { buildCustomModel, PROFILE_PRESETS, sanitizeWeights } from '../src/profiles.js';
import { squareAround } from '../src/geo.js';

function assertValidChains(statements) {
  // un "else_if" doit suivre un "if" ou un "else_if"
  statements.forEach((s, i) => {
    if ('else_if' in s || 'else' in s) {
      assert.ok(i > 0 && ('if' in statements[i - 1] || 'else_if' in statements[i - 1]), `chaîne invalide à l'index ${i}`);
    }
    if ('multiply_by' in s) {
      const v = Number(s.multiply_by);
      assert.ok(v >= 0 && v <= 1, `facteur hors [0,1] : ${s.multiply_by}`);
    }
  });
}

test('chaque préréglage produit un modèle valide', () => {
  for (const [id, p] of Object.entries(PROFILE_PRESETS)) {
    const m = buildCustomModel(p.weights, { maxSpeedKmh: 20 });
    assertValidChains(m.priority);
    assert.ok(m.distance_influence >= 10 && m.distance_influence <= 150, id);
    assert.deepEqual(m.speed, [{ if: 'true', limit_to: '20' }]);
  }
});

test('le profil Éco pénalise davantage les montées que le profil Rapide', () => {
  const factor = (m) => Number(m.priority.find((s) => (s.if ?? s.else_if) === 'average_slope > 4').multiply_by);
  const eco = buildCustomModel(PROFILE_PRESETS.eco.weights);
  const fast = buildCustomModel(PROFILE_PRESETS.fast.weights);
  assert.ok(factor(eco) < factor(fast));
});

test('aucune règle ne favorise les descentes', () => {
  for (const p of Object.values(PROFILE_PRESETS)) {
    const m = buildCustomModel(p.weights);
    for (const s of m.priority) {
      const cond = s.if ?? s.else_if ?? '';
      assert.ok(!/average_slope\s*<\s*-?/.test(cond), `règle de descente inattendue : ${cond}`);
    }
  }
});

test('poids extrêmes : modèle toujours valide', () => {
  for (const v of [0, 0.001, 0.006, 0.5, 1]) {
    const w = sanitizeWeights({ time: v, distance: v, climb: v, slope: v, surface: v, safety: v }, PROFILE_PRESETS.balanced.weights);
    assertValidChains(buildCustomModel(w).priority);
  }
});

test('fermetures exclues, chantiers pénalisés, zones déclarées', () => {
  const m = buildCustomModel(PROFILE_PRESETS.balanced.weights, {
    areas: {
      works: [{ id: 'works_1', geometry: squareAround([4.83, 45.75], 20) }],
      closures: [{ id: 'closure_7', geometry: squareAround([4.84, 45.76], 15) }],
    },
  });
  assert.deepEqual(m.areas.features.map((f) => f.id), ['works_1', 'closure_7']);
  assert.ok(m.priority.some((s) => s.if === 'in_closure_7' && s.multiply_by === '0'));
  assert.ok(m.priority.some((s) => s.if === 'in_works_1' && s.multiply_by === '0.2'));
});

test('sanitizeWeights borne et complète les valeurs', () => {
  const w = sanitizeWeights({ time: 3, climb: -1, distance: 'x' }, PROFILE_PRESETS.balanced.weights);
  assert.equal(w.time, 1);
  assert.equal(w.climb, 0);
  assert.equal(w.distance, PROFILE_PRESETS.balanced.weights.distance);
});
