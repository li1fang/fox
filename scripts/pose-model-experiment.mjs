import { spawn } from 'node:child_process';
import { access, rename } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const [manifest, python, model, output] = process.argv.slice(2);
if (!manifest || !python || !model || !output || process.argv.length !== 6) {
  throw new Error('Usage: node scripts/pose-model-experiment.mjs <manifest> <venv-python> <model> <new-cache>');
}
try { await access(output); throw new Error('Output already exists'); }
catch (error) { if (error.code !== 'ENOENT') throw error; }
const binary = path.join(root, '.tmp/native-core-build/debug/fox-pose-experiment');
await access(binary);
const producer = spawn(binary, ['stream', path.resolve(manifest)], { cwd: root, stdio: ['ignore', 'pipe', 'inherit'] });
const consumer = spawn(path.resolve(python), ['scripts/pose_experiment_mediapipe.py', '--model', path.resolve(model), '--output', path.resolve(output)],
  { cwd: root, stdio: ['pipe', 'inherit', 'inherit'] });
producer.stdout.pipe(consumer.stdin);
consumer.stdin.on('error', error => { if (error.code !== 'EPIPE') process.stderr.write(`${error.message}\n`); });
let producerCode, consumerCode;
const wait = (child, name) => new Promise(resolve => {
  child.on('error', error => { process.stderr.write(`${name}: ${error.message}\n`); resolve(1); });
  child.on('exit', code => {
    if (name === 'producer') producerCode = code ?? 1; else consumerCode = code ?? 1;
    if (code !== 0) (name === 'producer' ? consumer : producer).kill('SIGTERM');
    resolve(code ?? 1);
  });
});
const producerDone = wait(producer, 'producer');
const consumerDone = wait(consumer, 'consumer');
const timeout = setTimeout(() => { producer.kill('SIGTERM'); consumer.kill('SIGTERM'); }, 20 * 60 * 1000);
await producerDone;
await consumerDone;
clearTimeout(timeout);
if (producerCode !== 0 || consumerCode !== 0) {
  try { await rename(output, output + '.rejected'); } catch { /* An incomplete stream normally has no final cache. */ }
  throw new Error(`Frame comparison failed: producer=${producerCode}, consumer=${consumerCode}`);
}
