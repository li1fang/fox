import { test } from 'node:test';
import assert from 'node:assert/strict';
import { observe, validateCoverage } from '../../scripts/design-review.mjs';
const observation = frame => ({ schema: 'fox.design_observation.v1', source: 'isolated-design-fixture', scenario: 'sample',
  viewport: { x: 0, y: 0, width: 400, height: 800 }, elements: [{ id: 'primary', frame }] });
test('design geometry records containment without claiming usability', () => {
  const [r] = observe(observation({ x: 20, y: 60, width: 200, height: 44 }));
  assert.equal(r.visibleFractionWithinWindow, 1);
  assert.equal(r.conclusion, 'geometry-only-not-usability-acceptance');
});
test('offscreen and partial content are observations, not an automatic scroll failure', () => {
  assert.equal(observe(observation({ x: 0, y: 790, width: 200, height: 20 }))[0].observation, 'partly-outside-window');
  assert.equal(observe(observation({ x: 0, y: 900, width: 200, height: 20 }))[0].observation, 'outside-window');
});
test('invalid geometry stays unknown rather than passing a layout check', () => {
  assert.equal(observe(observation({ x: 0, y: 0, width: 0, height: 20 }))[0].conclusion, 'unknown');
  assert.throws(() => observe({ ...observation({}), viewport: { x: 0 } }));
});
test('real data and unrelated report formats cannot masquerade as design fixtures', () => {
  assert.throws(() => observe({ ...observation({}), source: 'camera' }));
  assert.throws(() => observe({ ...observation({}), schema: 'other' }));
});
test('combined groups cannot hide a missing test method behind other screenshots', () => {
  const report = { observations: [{ test: 'FoxDesignReviewUITests/testHomeScenarios()' }] };
  assert.doesNotThrow(() => validateCoverage(report, ['testHomeScenarios']));
  assert.throws(() => validateCoverage(report, ['testHomeScenarios', 'testTrainingScenarios']), /testTrainingScenarios/);
});
