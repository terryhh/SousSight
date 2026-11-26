// Tests for the CI guard scripts (SS-079): tool/check_build_config.sh and
// tool/check_web_bundle.sh. Run with `node --test test/tool/*.cjs`.
// The scripts run as executables, so on macOS this also exercises bash 3.2.
'use strict';

const assert = require('node:assert/strict');
const { spawnSync } = require('node:child_process');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const test = require('node:test');

const root = path.resolve(__dirname, '..', '..');
const configScript = path.join(root, 'tool', 'check_build_config.sh');
const bundleScript = path.join(root, 'tool', 'check_web_bundle.sh');
const SHA = '0123456789abcdef0123456789abcdef01234567';
// Synthetic, never-registered UUID, assembled at runtime so secret scanners
// do not see a token-shaped literal in source.
const TOKEN = ['0f8e2c1a', '3b4d', '4e5f', '8a6b', '7c8d9e0f1a2b'].join('-');

const created = [];
function tempDir() {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'soussight-ci-'));
  created.push(dir);
  return dir;
}
test.after(() => {
  for (const dir of created) fs.rmSync(dir, { recursive: true, force: true });
});

function run(script, args, extraEnv = {}) {
  const env = { ...process.env, ...extraEnv };
  if (!('APPCHECK_DEBUG_TOKEN' in extraEnv)) delete env.APPCHECK_DEBUG_TOKEN;
  const result = spawnSync(script, args, { encoding: 'utf8', env });
  return { code: result.status, out: `${result.stdout}${result.stderr}` };
}

function checkConfig(defines, { judged = true, raw, env } = {}) {
  const dir = tempDir();
  const file = path.join(dir, 'defines.json');
  fs.writeFileSync(file, raw ?? JSON.stringify(defines));
  return run(configScript, judged ? ['--judged', file] : [file], env);
}

const judgedDefaults = {
  FAKE_BACKEND: 'false',
  DINNER_MODE: 'simulated',
  LIVE_BACKEND: 'none',
  CLOUD_ROUTES: '',
  RECAPTCHA_SITE_KEY: 'site-key',
};

test('config: the judged defaults pass', () => {
  const r = checkConfig(judgedDefaults);
  assert.equal(r.code, 0, r.out);
  assert.match(r.out, /OK \(judged\): LIVE_BACKEND=none DINNER_MODE=simulated CLOUD_ROUTES=<none>/);
});

test('config: LIVE_BACKEND missing means none; aiLogic passes', () => {
  const { LIVE_BACKEND, ...rest } = judgedDefaults;
  assert.equal(checkConfig(rest).code, 0);
  assert.equal(checkConfig({ ...rest, LIVE_BACKEND: '' }).code, 0);
  assert.equal(checkConfig({ ...rest, LIVE_BACKEND: 'aiLogic' }).code, 0);
});

test('config: LIVE_BACKEND=ephemeral fails, judged or not', () => {
  for (const judged of [true, false]) {
    const r = checkConfig({ ...judgedDefaults, LIVE_BACKEND: 'ephemeral' }, { judged });
    assert.equal(r.code, 1, r.out);
    assert.match(r.out, /::error::LIVE_BACKEND=ephemeral is not allowed/);
  }
});

test('config: unknown LIVE_BACKEND values fail', () => {
  for (const value of ['AiLogic', 'ailogic', ' none', 'none ', 'native']) {
    const r = checkConfig({ ...judgedDefaults, LIVE_BACKEND: value });
    assert.equal(r.code, 1, `${value}: ${r.out}`);
    assert.match(r.out, /LIVE_BACKEND must be aiLogic or none/);
  }
});

test('config: judged build requires DINNER_MODE=simulated', () => {
  for (const value of ['real', '']) {
    const r = checkConfig({ ...judgedDefaults, DINNER_MODE: value });
    assert.equal(r.code, 1, r.out);
    assert.match(r.out, /requires DINNER_MODE=simulated/);
  }
  const { DINNER_MODE, ...missing } = judgedDefaults;
  assert.equal(checkConfig(missing).code, 1);
});

test('config: non-judged build accepts real, simulated or missing DINNER_MODE', () => {
  const { DINNER_MODE, ...missing } = judgedDefaults;
  assert.equal(checkConfig(missing, { judged: false }).code, 0);
  for (const value of ['real', 'simulated']) {
    assert.equal(checkConfig({ ...judgedDefaults, DINNER_MODE: value }, { judged: false }).code, 0);
  }
});

test('config: unknown DINNER_MODE fails even outside the judged build', () => {
  for (const value of ['simulate', 'Simulated', 'fake', ' real']) {
    const r = checkConfig({ ...judgedDefaults, DINNER_MODE: value }, { judged: false });
    assert.equal(r.code, 1, `${value}: ${r.out}`);
    assert.match(r.out, /DINNER_MODE must be real or simulated/);
  }
});

test('config: CLOUD_ROUTES accepts only the G1 route names', () => {
  for (const value of ['', 'hybridFallback', 'hybridFallback,research,nearby,live', ' research , live', 'live,live']) {
    const r = checkConfig({ ...judgedDefaults, CLOUD_ROUTES: value });
    assert.equal(r.code, 0, `${JSON.stringify(value)}: ${r.out}`);
  }
  for (const value of ['Research', 'hybrid', 'research,labels', 'research;live', 'research live']) {
    const r = checkConfig({ ...judgedDefaults, CLOUD_ROUTES: value });
    assert.equal(r.code, 1, `${JSON.stringify(value)}: ${r.out}`);
    assert.match(r.out, /CLOUD_ROUTES contains unknown route/);
  }
});

test('config: CLOUD_ROUTES with an empty entry fails', () => {
  for (const value of ['research,', ',live', 'research,,live', ',', 'research, ,live']) {
    const r = checkConfig({ ...judgedDefaults, CLOUD_ROUTES: value });
    assert.equal(r.code, 1, `${JSON.stringify(value)}: ${r.out}`);
    assert.match(r.out, /CLOUD_ROUTES has an empty entry/);
  }
});

test('config: APPCHECK_DEBUG_TOKEN in the file fails without printing it', () => {
  const r = checkConfig({ ...judgedDefaults, APPCHECK_DEBUG_TOKEN: TOKEN });
  assert.equal(r.code, 1, r.out);
  assert.match(r.out, /APPCHECK_DEBUG_TOKEN is set in the defines file/);
  assert.ok(!r.out.includes(TOKEN), 'token value must not be echoed');
  assert.equal(checkConfig({ ...judgedDefaults, APPCHECK_DEBUG_TOKEN: '' }).code, 0);
});

test('config: a token next to an invalid value is never printed', () => {
  // Mixed valid/invalid: the token is valid on its own, a later key is not.
  for (const bad of [{ FAKE_BACKEND: 'false\n' }, { CLOUD_ROUTES: 'research\tlive' }, { LIVE_BACKEND: '\r' }]) {
    const r = checkConfig({ ...judgedDefaults, APPCHECK_DEBUG_TOKEN: TOKEN, ...bad });
    assert.equal(r.code, 1, r.out);
    assert.match(r.out, /contains a tab or newline/);
    assert.ok(!r.out.includes(TOKEN), `token leaked: ${r.out}`);
    assert.ok(!r.out.includes('site-key'), `value leaked: ${r.out}`);
  }
  const broken = checkConfig(null, { raw: `{"APPCHECK_DEBUG_TOKEN": "${TOKEN}", oops}` });
  assert.equal(broken.code, 1, broken.out);
  assert.match(broken.out, /not valid JSON/);
  assert.ok(!broken.out.includes(TOKEN));
});

test('config: APPCHECK_DEBUG_TOKEN in the environment fails without printing it', () => {
  const r = checkConfig(judgedDefaults, { env: { APPCHECK_DEBUG_TOKEN: TOKEN } });
  assert.equal(r.code, 1, r.out);
  assert.match(r.out, /APPCHECK_DEBUG_TOKEN is set in the environment/);
  assert.ok(!r.out.includes(TOKEN));
});

test('config: judged build rejects a FAKE_BACKEND rehearsal (string or JSON boolean)', () => {
  for (const value of ['true', true]) {
    const r = checkConfig({ ...judgedDefaults, FAKE_BACKEND: value });
    assert.equal(r.code, 1, r.out);
    assert.match(r.out, /must not be a FAKE_BACKEND rehearsal/);
  }
  assert.equal(checkConfig({ ...judgedDefaults, FAKE_BACKEND: 'true' }, { judged: false }).code, 0);
});

test('config: every problem is reported, not just the first', () => {
  const r = checkConfig({
    LIVE_BACKEND: 'ephemeral', DINNER_MODE: 'simulate', CLOUD_ROUTES: 'oops', APPCHECK_DEBUG_TOKEN: 'x',
  });
  assert.equal(r.code, 1);
  assert.equal((r.out.match(/::error::/g) || []).length, 5, r.out);
  assert.match(r.out, /5 problem\(s\)/);
});

test('config: malformed input and usage', () => {
  assert.equal(checkConfig(null, { raw: '{not json' }).code, 1);
  assert.equal(checkConfig(null, { raw: '["LIVE_BACKEND"]' }).code, 1);
  const multiline = checkConfig({ ...judgedDefaults, CLOUD_ROUTES: 'research\nlive' });
  assert.equal(multiline.code, 1);
  assert.match(multiline.out, /contains a tab or newline/);
  assert.equal(run(configScript, [path.join(tempDir(), 'missing.json')]).code, 1);
  assert.equal(run(configScript, []).code, 2);
  assert.equal(run(configScript, ['--nope', 'x']).code, 2);
});

// --- check_web_bundle.sh ---------------------------------------------------

function bundle(files = {}) {
  const dir = tempDir();
  const all = {
    'main.dart.js': 'if(o!=null)m.FIREBASE_APPCHECK_DEBUG_TOKEN=o\nelse m.FIREBASE_APPCHECK_DEBUG_TOKEN=!0\n',
    'index.html': '<script src="flutter_bootstrap.js" async></script>',
    'version.json': JSON.stringify({ app_name: 'soussight', version: '1.0.0', build_number: '1' }),
    ...files,
  };
  for (const [name, content] of Object.entries(all)) {
    if (content === null) continue;
    const file = path.join(dir, name);
    fs.mkdirSync(path.dirname(file), { recursive: true });
    fs.writeFileSync(file, content);
  }
  return dir;
}

function readVersion(dir) {
  return JSON.parse(fs.readFileSync(path.join(dir, 'version.json'), 'utf8'));
}

test('bundle: a clean build passes, including the plugin debug-token property in main.dart.js', () => {
  const r = run(bundleScript, [bundle()]);
  assert.equal(r.code, 0, r.out);
  assert.match(r.out, /Web bundle OK/);
});

test('bundle: missing main.dart.js fails', () => {
  const r = run(bundleScript, [bundle({ 'main.dart.js': null })]);
  assert.equal(r.code, 1, r.out);
  assert.match(r.out, /main\.dart\.js not found/);
});

test('bundle: a compiled-in debug token (quoted UUID) fails without printing it', () => {
  for (const quote of ['"', "'", '`']) {
    const dir = bundle({ 'main.dart.js': `x(new A.zz(${quote}${TOKEN}${quote},""))` });
    const r = run(bundleScript, [dir]);
    assert.equal(r.code, 1, r.out);
    assert.match(r.out, /Possible App Check debug token \(quoted UUID literal\) in .*main\.dart\.js/);
    assert.ok(!r.out.includes(TOKEN));
  }
  const upper = run(bundleScript, [bundle({ 'assets/x.json': `{"id":"${TOKEN.toUpperCase()}"}` })]);
  assert.equal(upper.code, 1, upper.out);
});

test('bundle: binary files are not scanned for UUIDs', () => {
  const binary = Buffer.concat([Buffer.from([0, 1, 2, 0]), Buffer.from(`"${TOKEN}"`)]);
  const r = run(bundleScript, [bundle({ 'canvaskit/canvaskit.wasm': binary })]);
  assert.equal(r.code, 0, r.out);
});

test('bundle: FIREBASE_APPCHECK_DEBUG_TOKEN outside compiled Dart fails', () => {
  const html = '<script>self.FIREBASE_APPCHECK_DEBUG_TOKEN = true;</script>';
  const r = run(bundleScript, [bundle({ 'index.html': html })]);
  assert.equal(r.code, 1, r.out);
  assert.match(r.out, /FIREBASE_APPCHECK_DEBUG_TOKEN referenced in .*index\.html/);
  const part = run(bundleScript, [bundle({ 'main.dart.js_1.part.js': 'a.FIREBASE_APPCHECK_DEBUG_TOKEN=b' })]);
  assert.equal(part.code, 0, part.out);
});

test('bundle: the environment debug token value is searched and never printed', () => {
  const secret = 'not-a-uuid-debug-value';
  const r = run(bundleScript, [bundle({ 'soussight_live.js': `const t = ${secret};` })],
    { APPCHECK_DEBUG_TOKEN: secret });
  assert.equal(r.code, 1, r.out);
  assert.match(r.out, /APPCHECK_DEBUG_TOKEN is set in the environment/);
  assert.match(r.out, /value appears in .*soussight_live\.js/);
  assert.ok(!r.out.includes(secret));
});

test('bundle: ephemeral Live markers fail, or warn with --warn-live-marker', () => {
  const markers = [
    '"/ws/google.ai.generativelanguage."+h.c+".GenerativeService.BidiGenerateContentConstrained"',
    'A.vE("wss","generativelanguage.googleapis.com")',
  ];
  for (const js of markers) {
    const strict = run(bundleScript, [bundle({ 'main.dart.js': js })]);
    assert.equal(strict.code, 1, strict.out);
    assert.match(strict.out, /::error::Ephemeral Live transport marker/);
    const lenient = run(bundleScript, ['--warn-live-marker', bundle({ 'main.dart.js': js })]);
    assert.equal(lenient.code, 0, lenient.out);
    assert.match(lenient.out, /::warning::Ephemeral Live transport marker/);
  }
  // AI Logic's own host is not a marker.
  const aiLogic = run(bundleScript, [bundle({ 'main.dart.js': '"firebasevertexai.googleapis.com"' })]);
  assert.equal(aiLogic.code, 0, aiLogic.out);
});

test('bundle: --commit merges the SHA, ref and non-secret config into version.json', () => {
  const dir = bundle();
  const defines = path.join(tempDir(), 'defines.json');
  fs.writeFileSync(defines, JSON.stringify({ ...judgedDefaults, CLOUD_ROUTES: 'research', LIVE_BACKEND: '' }));
  const r = run(bundleScript, ['--commit', SHA, '--ref', 'v1.0.0', '--config', defines, dir]);
  assert.equal(r.code, 0, r.out);
  const version = readVersion(dir);
  assert.equal(version.app_name, 'soussight');
  assert.equal(version.version, '1.0.0');
  assert.equal(version.commit, SHA);
  assert.equal(version.ref, 'v1.0.0');
  assert.deepEqual(version.config, { LIVE_BACKEND: 'none', DINNER_MODE: 'simulated', CLOUD_ROUTES: 'research' });
  assert.ok(!JSON.stringify(version).includes('site-key'), 'only allowlisted keys are copied');
});

test('bundle: re-stamping drops an earlier ref and config', () => {
  const dir = bundle({
    'version.json': JSON.stringify({ version: '1.0.0', commit: 'old', ref: 'old-tag', config: { DINNER_MODE: 'real' } }),
  });
  const r = run(bundleScript, ['--commit', SHA, dir]);
  assert.equal(r.code, 0, r.out);
  assert.deepEqual(readVersion(dir), { version: '1.0.0', commit: SHA });
});

test('bundle: --commit creates version.json when Flutter did not', () => {
  const dir = bundle({ 'version.json': null });
  const r = run(bundleScript, ['--commit', SHA, dir]);
  assert.equal(r.code, 0, r.out);
  assert.deepEqual(readVersion(dir), { commit: SHA });
});

test('bundle: a rejected bundle does not get a version.json stamp', () => {
  const dir = bundle({ 'main.dart.js': `"${TOKEN}"` });
  const before = fs.readFileSync(path.join(dir, 'version.json'), 'utf8');
  assert.equal(run(bundleScript, ['--commit', SHA, dir]).code, 1);
  assert.equal(fs.readFileSync(path.join(dir, 'version.json'), 'utf8'), before);
});

test('bundle: malformed --commit and usage errors', () => {
  for (const sha of ['abc123', SHA.toUpperCase(), `${SHA}0`, 'HEAD']) {
    const r = run(bundleScript, ['--commit', sha, bundle()]);
    assert.equal(r.code, 1, `${sha}: ${r.out}`);
    assert.match(r.out, /--commit must be a full lowercase hex SHA/);
  }
  assert.equal(run(bundleScript, []).code, 2);
  assert.equal(run(bundleScript, ['--commit']).code, 2);
  assert.equal(run(bundleScript, [bundle(), bundle()]).code, 2);
});
