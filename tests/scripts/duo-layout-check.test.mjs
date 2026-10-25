import test from 'node:test';
import assert from 'node:assert/strict';
import {duoSelection, duoRuntime, duoModel} from '../../scripts/duo-layout-check.mjs';

test('Duo selection is explicit, public and excludes unrelated phone-only assumptions', () => {
  const catalogue = [
    {id: 'FoxAppTests/AdaptiveLayoutTests/testSpace', scope: 'public'},
    {id: 'FoxUITests/FoxAdaptiveUITests/testFlow', scope: 'public'},
    {id: 'FoxUITests/FoxHomeUITests/testSave', scope: 'public'},
    {id: 'FoxUITests/FoxPhoneLayoutUITests/testPhoneOnly', scope: 'public'}
  ];
  assert.equal(duoRuntime, 'com.apple.CoreSimulator.SimRuntime.iOS-27-1');
  assert.equal(duoModel, 'com.apple.CoreSimulator.SimDeviceType.iPhone-Duo');
  assert.equal(duoSelection(catalogue).length, 3);
  assert.throws(() => duoSelection(catalogue.map(x => ({...x, scope: 'private'}))), /public/);
  assert.throws(() => duoSelection([]), /Missing/);
});
