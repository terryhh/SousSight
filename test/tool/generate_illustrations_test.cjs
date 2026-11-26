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
