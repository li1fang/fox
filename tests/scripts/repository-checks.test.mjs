import test from 'node:test';
import assert from 'node:assert/strict';
import {checkLinks, checkPublicFile, checkTask} from '../../scripts/repository-checks.mjs';

test('public source boundaries reject private media and signing identity, allow synthetic JSON', () => {
  for (const file of ['.data/raw.json', '.tmp/suite.json', 'video.mov', 'snapshot.sqlite', 'inputs.private.json', 'author.docx']) {
    assert.throws(() => checkPublicFile(file, '{}'), /Private/);
  }
  assert.throws(() => checkPublicFile('project.yml', 'DEVELOPMENT_TEAM: ' + 'ABCDE12345'), /identifier/);
  assert.doesNotThrow(() => checkPublicFile('tests/synthetic.json', '{"source":"synthetic"}'));
});
test('missing and absolute repository links cannot be silently accepted', async () => {
  await assert.rejects(checkLinks('README.md', '[bad](missing.md)', async () => false), /Broken/);
  await assert.rejects(checkLinks('README.md', '[bad](/private/path)', async () => true), /nonportable/);
  await checkLinks('README.md', '[web](https://example.com) [ok](docs/ok.md)', async () => true);
});
test('a task must define acceptance, stop conditions and honest unknowns', () => {
  const task = {schema:'fox.development_task.v1',outcome:'test',nonGoals:['deploy'],invariants:['preserve'],modules:['core'],
    acceptance:['verify:fast'],stopConditions:['data risk'],evidence:['receipt'],humanUnknowns:['camera']};
  checkTask(task, {'verify:fast':'node scripts/verify.mjs fast'});
  assert.throws(() => checkTask({...task, humanUnknowns:[]}, {'verify:fast':'run'}), /humanUnknowns/);
  assert.throws(() => checkTask(task, {}), /Unknown/);
});
