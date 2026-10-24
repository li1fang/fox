import {readFile, stat} from 'node:fs/promises';
import path from 'node:path';
import {spawnSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';
import {checkedCatalogue} from './test-inventory.mjs';

const root = fileURLToPath(new URL('..', import.meta.url));
export function checkTask(task, commands) {
  if (task.schema !== 'fox.development_task.v1' || typeof task.outcome !== 'string' || !task.outcome.trim()) throw Error('Missing task outcome');
  for (const field of ['nonGoals', 'invariants', 'modules', 'acceptance', 'stopConditions', 'evidence', 'humanUnknowns']) {
    if (!Array.isArray(task[field]) || !task[field].length || task[field].some(x => typeof x !== 'string' || !x.trim())) throw Error(`Missing task ${field}`);
  }
  for (const command of task.acceptance) if (!commands[command]) throw Error(`Unknown task command: ${command}`);
}
export function checkPublicFile(file, text) {
  if (/^(?:\.data|\.tmp|\.venv|node_modules)\//.test(file) || /\.(?:mov|mp4|m4a|wav|sqlite|db|docx|private\.json)$/i.test(file)) throw Error(`Private or unlicensed artifact: ${file}`);
  if (/\/Users\/[a-zA-Z0-9_-]+\//.test(text) || /DEVELOPMENT_TEAM:\s*[A-Z0-9]{10}\b/.test(text)
      || /-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----/.test(text)
      || /\bgh[pousr]_[A-Za-z0-9]{30,}\b/.test(text) || /\b\w+@(?:gmail|icloud)\.com\b/i.test(text)) throw Error(`Potential private identifier/credential: ${file}`);
}
export async function checkLinks(file, text, exists = async name => { try { await stat(name); return true; } catch { return false; } }) {
  for (const match of text.matchAll(/\[[^\]]*\]\(([^\s)]+)(?:\s+"[^"]*")?\)/g)) {
    const link = match[1].split('#')[0];
    if (!link || /^(?:https?:|mailto:|plugin:)/.test(link)) continue;
    if (path.isAbsolute(link) || !(await exists(path.resolve(root, path.dirname(file), decodeURI(link))))) throw Error(`Broken/nonportable link in ${file}: ${link}`);
  }
}
export async function checkRepository() {
  const listing = spawnSync('git', ['ls-files', '-co', '--exclude-standard', '-z'], {cwd: root, encoding: 'utf8'});
  if (listing.status !== 0) throw Error('Cannot enumerate public files');
  const files = [...new Set(listing.stdout.split('\0').filter(Boolean))];
  const commands = JSON.parse(await readFile(path.join(root, 'package.json'))).scripts;
  for (const file of files) {
    const text = await readFile(path.join(root, file), 'utf8');
    checkPublicFile(file, text);
    if (file.endsWith('.md')) await checkLinks(file, text);
    if (file === 'AGENTS.md' || file === 'README.md' || file.startsWith('docs/development/')) {
      for (const match of text.matchAll(/npm run ([\w:-]+)/g)) if (!commands[match[1]]) throw Error(`Unknown documented command in ${file}: ${match[1]}`);
    }
    if (file.startsWith('apps/ipad/FoxTrainingCore/Sources/FoxTrainingCore/') && file.endsWith('.swift')) {
      for (const imported of text.matchAll(/^import (\w+)/gm)) if (imported[1] !== 'Foundation') throw Error(`Motion core platform dependency: ${file}`);
    }
    if (file.startsWith('apps/ipad/FoxJournalCore/Sources/FoxJournalCore/') && file.endsWith('.swift')) {
      for (const imported of text.matchAll(/^import (\w+)/gm)) if (!['Foundation', 'SQLite3', 'CryptoKit'].includes(imported[1])) throw Error(`Journal boundary: ${file}`);
    }
  }
  const training = await readFile(path.join(root, 'apps/ipad/FoxTrainingCore/Package.swift'), 'utf8');
  if (/\.target\(name: "FoxTrainingCore",[^\n]*dependencies:/.test(training)) throw Error('Production core must not depend on test support');
  checkTask(JSON.parse(await readFile(path.join(root, 'docs/development/task-contract.example.json'))), commands);
  const catalogue = await checkedCatalogue();
  return {status: 'repository_contracts_passed', files: files.length, classifiedTests: catalogue.length,
    boundary: 'Mechanical checks supplement, not replace, human/fresh-context disclosure review'};
}
if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  checkRepository().then(value => console.log(JSON.stringify(value))).catch(error => { console.error(error.message); process.exitCode = 1; });
}
