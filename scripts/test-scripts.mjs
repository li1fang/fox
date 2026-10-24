import {spawnSync} from 'node:child_process';
import {checkedCatalogue} from './test-inventory.mjs';
const scope = process.argv[2] ?? 'public';
if (!['public', 'private'].includes(scope)) throw Error('Expected public or private script tests');
const selected = (await checkedCatalogue()).filter(x => x.scope === scope && x.file.startsWith('tests/scripts/') && x.file.endsWith('.mjs'));
if (!selected.length) throw Error('No script tests selected');
const result = spawnSync(process.execPath, ['--test', '--test-reporter=tap', ...selected.map(x => x.file)], {stdio: 'inherit'});
process.exitCode = result.status ?? 1;
