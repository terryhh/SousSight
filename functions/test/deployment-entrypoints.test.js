import test from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { cpSync, mkdtempSync, rmSync, symlinkSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';

const require = createRequire(import.meta.url);
const root = fileURLToPath(new URL('..', import.meta.url));
// Exercise the installed SDK discovery loader used by firebase-functions' CLI binary.
const loader = join(dirname(require.resolve('firebase-functions')), '../runtime/loader.js');

function discover(main) {
  const dir = mkdtempSync(join(tmpdir(), 'soussight-functions-'));
  try {
    cpSync(join(root, 'src'), join(dir, 'src'), { recursive: true });
    symlinkSync(join(root, 'node_modules'), join(dir, 'node_modules'), 'dir');
    writeFileSync(join(dir, 'package.json'), JSON.stringify({ type: 'module', main }));
    const script = `const {loadStack} = require(${JSON.stringify(loader)}); loadStack(${JSON.stringify(dir)}).then(stack => console.log(JSON.stringify(stack)));`;
    return JSON.parse(execFileSync(process.execPath, ['-e', script], { encoding: 'utf8' }));
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

test('Live-only packaged entrypoint discovers no dinner exports or secret parameters', () => {
  const stack = discover('src/live-index.js');
  assert.deepEqual(Object.keys(stack.endpoints), ['liveToken']);
  assert.deepEqual(stack.endpoints.liveToken.secretEnvironmentVariables, [{ key: 'GEMINI_API_KEY' }]);
  assert.equal(stack.params.some(p => p.name.startsWith('VONAGE_') || p.name.startsWith('DINNER_') || p.name === 'ENABLE_DINNER_MESSAGES'), false);
  assert.ok(stack.params.some(p => p.name === 'GEMINI_API_KEY'));
});

test('live+dinner entrypoint omits the status webhook and its signature secret', () => {
  const stack = discover('src/live-dinner-index.js');
  assert.deepEqual(Object.keys(stack.endpoints).sort(), ['dinnerReady', 'liveToken']);
  assert.equal(stack.params.some(p => p.name === 'VONAGE_SIGNATURE_SECRET'), false);
  assert.equal(stack.params.find(p => p.name === 'ALLOW_DELIVERY_SIMULATION').default, 'false');
  // A non-empty default keeps non-interactive deploys from prompting (2026-11-08 deploy failure).
  assert.equal(stack.params.find(p => p.name === 'DINNER_STATUS_WEBHOOK_URL').default, 'disabled');
});

test('full packaged entrypoint preserves all functions and secret bindings', () => {
  const stack = discover('src/index.js');
  assert.deepEqual(Object.keys(stack.endpoints).sort(), ['dinnerReady', 'liveToken', 'vonageStatus']);
  assert.deepEqual(stack.endpoints.dinnerReady.secretEnvironmentVariables.map(s => s.key).sort(),
    ['VONAGE_ALLOWED_TO', 'VONAGE_API_KEY', 'VONAGE_API_SECRET', 'VONAGE_FROM']);
  assert.deepEqual(stack.endpoints.vonageStatus.secretEnvironmentVariables.map(s => s.key),
    ['VONAGE_SIGNATURE_SECRET']);
  assert.equal(stack.endpoints.vonageStatus.region[0], 'us-central1');
  assert.equal(stack.params.find(p => p.name === 'ENABLE_DINNER_MESSAGES').default, 'false');
  assert.equal(stack.params.filter(p => p.name === 'LIVE_ALLOWED_ORIGINS').length, 1);
});
