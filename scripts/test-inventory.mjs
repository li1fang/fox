import {readdir, readFile} from 'node:fs/promises';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {auditInventory} from './verification-contracts.mjs';

const root = fileURLToPath(new URL('..', import.meta.url));
export const inventoryPath = path.join(root, 'tests/verification/catalogue.json');
async function filesBelow(directory, relative = '') {
  const result = [];
  for (const entry of await readdir(path.join(directory, relative), {withFileTypes:true})) {
    const name = path.join(relative,entry.name);
    if (entry.isDirectory()) result.push(...await filesBelow(directory,name));
    else if (entry.isFile()) result.push(name);
  }
  return result.sort();
}
export async function discoverTests(directory = root) {
  const found = [];
  for (const [folder, target] of [
    ['apps/ipad/FoxTrainingCore/Tests/FoxTrainingCoreTests', 'FoxTrainingCoreTests'],
    ['apps/ipad/FoxJournalCore/Tests/FoxJournalCoreTests', 'FoxJournalCoreTests'],
    ['apps/ipad/FoxAppTests', 'FoxAppTests'], ['apps/ipad/FoxUITests', 'FoxUITests']]) {
    for (const name of await filesBelow(path.join(directory, folder))) {
      if (!name.endsWith('.swift')) continue;
      const file = `${folder}/${name}`, source = await readFile(path.join(directory, file), 'utf8');
      const classes = [...source.matchAll(/(?:final\s+)?class\s+(\w+)\s*:\s*XCTestCase/g)];
      if (classes.length !== 1 || /@Test\b/.test(source)) throw Error(`Unrecognized test layout (one XCTestCase per file): ${file}`);
      // Attributes/modifiers may precede func. Do not silently filter those methods out of execution.
      for (const method of source.matchAll(/\bfunc\s+([^\s(]+)\s*\(/g)) {
        const name = method[1].replace(/^`|`$/g, '');
        if (name.startsWith('test')) {
          if (!/^test\w+$/.test(name)) throw Error(`Unrecognized test method: ${file}: ${name}`);
          found.push({id: `${target}/${classes[0][1]}/${name}`, file});
        }
      }
    }
  }
  for (const [folder, extensions] of [['tests/scripts', /\.test\.mjs$|^test_.*\.py$/],
    ['tests/e2e', /\.spec\.ts$/], ['packages/core/test', /\.test\.ts$/], ['apps/api/test', /\.test\.ts$/]]) {
    for (const file of await filesBelow(path.join(directory, folder))) {
      if (extensions.test(path.basename(file))) found.push({id: `${folder}/${file}`, file: `${folder}/${file}`});
    }
  }
  return found;
}
export async function checkedCatalogue() {
  const value = JSON.parse(await readFile(inventoryPath, 'utf8'));
  if (value.schema !== 'fox.test_catalogue.v1') throw Error('Invalid test catalogue');
  auditInventory(await discoverTests(), value.tests);
  return value.tests;
}
