import {spawnSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';
import path from 'node:path';
import {checkPublicFile} from './repository-checks.mjs';

const root = fileURLToPath(new URL('..', import.meta.url));
function git(...args) {
  const p = spawnSync('git', args, {cwd:root,encoding:'utf8',maxBuffer:32*1024*1024});
  if (p.status !== 0) throw Error(`Cannot audit Git history: ${p.stderr}`);
  return p.stdout;
}
export function auditPublicHistory(base = 'origin/main') {
  git('merge-base','--is-ancestor',base,'HEAD');
  if (git('status','--porcelain').trim()) throw Error('Commit reviewed public changes before history audit');
  const commits = git('rev-list','--reverse',`${base}..HEAD`).trim().split('\n').filter(Boolean);
  if (!commits.length) throw Error('No new public commits');
  let blobs = 0;
  for (const commit of commits) {
    const files = git('diff-tree','--no-commit-id','--name-only','--no-renames','--diff-filter=ACM','-r','-z',commit).split('\0').filter(Boolean);
    for (const file of files) { checkPublicFile(file,git('show',`${commit}:${file}`)); blobs++; }
  }
  return {status:'public_history_mechanical_audit_passed',base,head:git('rev-parse','HEAD').trim(),commits,blobs,
    limitation:'Source-pattern checks do not establish disclosure rights; independent review is still required.'};
}
if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try { console.log(JSON.stringify(auditPublicHistory(process.argv[2]),null,2)); }
  catch (error) { console.error(error.message); process.exitCode = 1; }
}
