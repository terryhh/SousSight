// Argument and path guards of tool/generate_illustrations.mjs (SS-098).
// Every case is refused before Playwright loads, so nothing is launched and
// no model can be called.
const test = require('node:test');
const assert = require('node:assert');
const { spawnSync } = require('node:child_process');
const { mkdtempSync, mkdirSync, symlinkSync } = require('node:fs');
const { join, resolve } = require('node:path');
const { tmpdir } = require('node:os');

const repo = resolve(__dirname, '..', '..');
const script = join(repo, 'tool', 'generate_illustrations.mjs');

function run(...args) {
  const r = spawnSync(process.execPath, [script, ...args], {
    encoding: 'utf8',
    // Make sure no Playwright could be found even if a guard regressed.
    env: { ...process.env, PLAYWRIGHT_MODULE: '/nonexistent/playwright.mjs' },
  });
  return { code: r.status, out: `${r.stdout}${r.stderr}` };
}

const outside = mkdtempSync(join(tmpdir(), 'illus-build-'));

test('usage errors exit 2', () => {
  assert.equal(run().code, 2);
  assert.equal(run('nope', outside).code, 2);
  assert.equal(run('gate', outside).code, 2); // no evidence dir
});

test('--max must be a whole number', () => {
  for (const args of [[], ['--max'], ['--max', 'abc'], ['--max', '-1'], ['--max', '1.5'], ['--max', '']]) {
    const r = run('premade', outside, ...args);
    assert.equal(r.code, 2, `${JSON.stringify(args)}: ${r.out}`);
    assert.match(r.out, /--max/);
  }
  assert.equal(run('premade', outside, '--max', '99999999999999999999').code, 2);
});

test('builds inside, containing or linking into the repository are refused', () => {
  const inside = join(repo, 'build');
  mkdirSync(inside, { recursive: true });
  for (const dir of [repo, inside, resolve(repo, '..')]) {
    const r = run('premade', dir, '--max', '0');
    assert.equal(r.code, 2, `${dir}: ${r.out}`);
    assert.match(r.out, /Refusing a build/);
  }
  const link = join(outside, 'link-to-repo');
  symlinkSync(repo, link);
  const r = run('premade', link, '--max', '0');
  assert.equal(r.code, 2, r.out);
  assert.match(r.out, /Refusing a build/);
});

test('a missing build directory is refused', () => {
  const r = run('premade', join(outside, 'missing'), '--max', '0');
  assert.equal(r.code, 2);
  assert.match(r.out, /No build directory/);
});

test('a valid outside build gets past the guards', () => {
  // It then fails to load the (deliberately missing) Playwright module.
  const r = run('premade', outside, '--max', '0');
  assert.notEqual(r.code, 0);
  assert.doesNotMatch(r.out, /Refusing|--max|usage/);
});

// The pure helpers, imported without launching anything.
const { writeFileSync } = require('node:fs');
const { realpathSync } = require('node:fs');
const lib = () => import(join(repo, 'tool', 'generate_illustrations_lib.mjs'));

test('within compares path components, not prefixes', async () => {
  const { within } = await lib();
  assert.equal(within('/a/build', '/a/build'), true);
  assert.equal(within('/a/build', '/a/build/x/y.js'), true);
  assert.equal(within('/a/build', '/a/build2/x'), false);
  assert.equal(within('/a/build', '/a'), false);
  assert.equal(within('/a/build', '/b/build'), false);
});

test('fileToServe picks the final file, then canonicalizes it', async () => {
  const { fileToServe } = await lib();
  const root = realpathSync(mkdtempSync(join(tmpdir(), 'illus-serve-')));
  const build = join(root, 'build');
  mkdirSync(join(build, 'assets'), { recursive: true });
  writeFileSync(join(build, 'main.js'), 'x');
  writeFileSync(join(root, 'secret.txt'), 'secret');
  // index.html is a symlink that leads outside the build.
  symlinkSync(join(root, 'secret.txt'), join(build, 'index.html'));
  symlinkSync(join(root, 'secret.txt'), join(build, 'leak.js'));
  assert.equal(fileToServe(build, '/main.js?v=1'), join(build, 'main.js'));
  assert.equal(fileToServe(build, '/leak.js'), null);
  // Missing paths and directories fall back to index.html, which escapes.
  assert.equal(fileToServe(build, '/missing'), null);
  assert.equal(fileToServe(build, '/assets'), null);
  assert.equal(fileToServe(build, '/../secret.txt'), null);
  assert.equal(fileToServe(build, '/%E0%A4%A'), null); // bad escape
  // With a real index.html, the fallback serves it.
  const build2 = join(root, 'build2');
  mkdirSync(join(build2, 'assets'), { recursive: true });
  writeFileSync(join(build2, 'index.html'), '<html>');
  assert.equal(fileToServe(build2, '/missing'), join(build2, 'index.html'));
  assert.equal(fileToServe(build2, '/assets'), join(build2, 'index.html'));
  assert.equal(fileToServe(build2, '/../build/main.js'), null); // escapes: refused
});

test('model traffic is armed only for the matching build mode', async () => {
  const { modeAllowed } = await lib();
  assert.equal(modeAllowed('premade', 15, { mode: 'premade', max: 15 }), true);
  assert.equal(modeAllowed('premade', 1, { mode: 'premade', max: 15 }), false);
  assert.equal(modeAllowed('premade', 15, { mode: 'premade', max: 'x' }), false);
  assert.equal(modeAllowed('premade', 15, { mode: 'gate', max: 0 }), false);
  assert.equal(modeAllowed('gate', 1, { mode: 'premade', max: 15 }), false);
  assert.equal(modeAllowed('gate', 1, { mode: 'gate', max: 0 }), true);
  assert.equal(modeAllowed('gate', 1, null), false);
});

test('the gate evidence predicate passes only on complete evidence', async () => {
  const { gateEvidenceOk } = await lib();
  const model = 'gemini-nano-banana-2.1';
  const good = {
    shown: true,
    model,
    legs: [{
      feature: 'step_illustration',
      kinds: ['text'],
      transferPermitted: true,
      provenance: 'cloudAdapter',
      modelLabel: `${model} (text→image)`,
      error: null,
      pending: false,
    }],
    requests: [{ path: `/v1beta/projects/p/models/${model}:generateContent`, status: 200 }],
  };
  assert.equal(gateEvidenceOk(good), true);
  const variants = [
    { shown: false },
    { model: undefined },
    { legs: [] },
    { legs: [good.legs[0], good.legs[0]] },
    { legs: [{ ...good.legs[0], feature: 'research' }] },
    { legs: [{ ...good.legs[0], kinds: ['text', 'image'] }] },
    { legs: [{ ...good.legs[0], modelLabel: 'other (text→image)' }] },
    { legs: [{ ...good.legs[0], provenance: 'unknown' }] },
    { legs: [{ ...good.legs[0], error: 'network' }] },
    { legs: [{ ...good.legs[0], pending: true }] },
    { requests: [] },
    { requests: [{ ...good.requests[0], status: 429 }] },
    { requests: [{ path: '/v1beta/models/other:generateContent', status: 200 }] },
    { requests: [good.requests[0], good.requests[0]] },
  ];
  for (const change of variants) {
    assert.equal(gateEvidenceOk({ ...good, ...change }), false, JSON.stringify(change));
  }
});

test('every checkout counts: a linked worktree refuses the primary build/web', async () => {
  const { checkoutRoots, refusedBuild } = await lib();
  const porcelain = [
    'worktree /src/SousSight',
    'HEAD abc',
    'branch refs/heads/main',
    '',
    'worktree /src/SousSight/.worktrees/feature',
    'HEAD def',
    '',
  ].join('\n');
  const roots = checkoutRoots('/src/SousSight/.worktrees/feature', porcelain);
  assert.deepEqual(roots.sort(), ['/src/SousSight', '/src/SousSight/.worktrees/feature']);
  assert.match(refusedBuild('/src/SousSight/build/web', roots), /Refusing a build/);
  assert.match(refusedBuild('/src/SousSight/.worktrees/other/build', roots), /Refusing a build/);
  assert.match(refusedBuild('/src', roots), /Refusing a build/);
  assert.equal(refusedBuild('/tmp/illus/build', roots), null);
});

test('from this checkout, the primary checkout\'s build/web is refused', () => {
  const porcelain = spawnSync('git', ['-C', repo, 'worktree', 'list', '--porcelain'], { encoding: 'utf8' }).stdout;
  const primary = porcelain.split('\n').find((l) => l.startsWith('worktree ')).slice('worktree '.length);
  const r = run('premade', join(primary, 'build', 'web'), '--max', '0');
  assert.equal(r.code, 2, r.out);
  assert.match(r.out, /Refusing a build/);
});
