// Tests for tool/verify_all.sh (SS-088). Run with `node --test test/tool/*.cjs`.
// Every run uses stub flutter/node/npm/python3 executables on a minimal PATH
// and a temporary VERIFY_OUT_DIR, so nothing is built, tested or written in the
// repository. On macOS this also exercises bash 3.2.
'use strict';

const assert = require('node:assert/strict');
const { spawnSync } = require('node:child_process');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const test = require('node:test');

const root = path.resolve(__dirname, '..', '..');
const script = path.join(root, 'tool', 'verify_all.sh');

const created = [];
function tempDir() {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'soussight-verify-'));
  created.push(dir);
  return dir;
}
test.after(() => {
  for (const dir of created) fs.rmSync(dir, { recursive: true, force: true });
});

// A stub records its argv in calls.log, prints a ::warning:: line when its
// joined arguments match WARN_PATTERN and fails when they match FAIL_PATTERN. `flutter test --coverage
// --coverage-path FILE` writes a tiny lcov file like the real tool.
const STUB = `#!/bin/sh
name=$(basename "$0")
printf '%s %s\\n' "$name" "$*" >> "$STUB_LOG"
if [ -n "$WARN_PATTERN" ] && printf '%s %s' "$name" "$*" | grep -Eq "$WARN_PATTERN"; then
  echo "::warning::stub $name warns on purpose"
fi
if [ -n "$FAIL_PATTERN" ] && printf '%s %s' "$name" "$*" | grep -Eq "$FAIL_PATTERN"; then
  echo "stub $name failing on purpose"
  exit 3
fi
if [ "$name" = flutter ] && [ "$1" = test ] && ! { [ -n "$NO_LCOV_PATTERN" ] && printf '%s' "$*" | grep -Eq "$NO_LCOV_PATTERN"; }; then
  while [ $# -gt 0 ]; do
    if [ "$1" = --coverage-path ]; then
      printf 'SF:lib/a.dart\\nDA:1,1\\nend_of_record\\n' > "$2"
    fi
    shift
  done
fi
exit 0
`;

function stubs(names = ['flutter', 'node', 'npm', 'python3']) {
  const dir = tempDir();
  for (const name of names) {
    const file = path.join(dir, name);
    fs.writeFileSync(file, STUB);
    fs.chmodSync(file, 0o755);
  }
  return dir;
}

function verify(args, { env = {}, stubNames, cwd, outDir, scriptPath = script } = {}) {
  const bin = stubs(stubNames);
  const out = outDir ?? tempDir();
  const home = tempDir();
  const log = path.join(tempDir(), 'calls.log');
  const result = spawnSync(scriptPath, args, {
    encoding: 'utf8',
    cwd,
    env: {
      PATH: `${bin}:/usr/bin:/bin`,
      HOME: home,
      VERIFY_OUT_DIR: out,
      STUB_LOG: log,
      ANDROID_HOME: path.join(home, 'no-android-sdk'),
      ...env,
    },
  });
  const read = (name) => {
    const file = path.isAbsolute(name) ? name : path.resolve(cwd ?? process.cwd(), out, name);
    return fs.existsSync(file) ? fs.readFileSync(file, 'utf8') : '';
  };
  return {
    code: result.status,
    out: `${result.stdout}${result.stderr}`,
    calls: read(log),
    summary: read('summary.txt'),
    markdown: read('summary.md'),
    outDir: out,
  };
}

function row(summary, step) {
  const line = summary.split('\n').find((l) => l.includes(step));
  assert.ok(line, `no summary row for ${step}:\n${summary}`);
  return line;
}

test('--help prints the usage and every flag', () => {
  const r = verify(['--help']);
  assert.equal(r.code, 0, r.out);
  for (const flag of ['--quick', '--no-native', '--no-e2e', '--dry-run', '--update-baseline']) {
    assert.match(r.out, new RegExp(flag));
  }
  assert.equal(r.calls, '');
});

test('an unknown option is a usage error', () => {
  const r = verify(['--fast']);
  assert.equal(r.code, 2, r.out);
  assert.match(r.out, /Unknown option: --fast/);
});

test('without Flutter the script stops with a usage error', () => {
  const r = verify(['--dry-run'], { stubNames: ['node'] });
  assert.equal(r.code, 2, r.out);
  assert.match(r.out, /Flutter is not on PATH/);
});

test('--dry-run plans every step and executes nothing', () => {
  const r = verify(['--dry-run']);
  assert.equal(r.code, 0, r.out);
  assert.equal(r.calls, '', 'dry run must not invoke any tool');
  assert.match(r.out, /Dry run: nothing was executed/);
  for (const step of ['flutter pub get (app)', 'flutter analyze (app)', 'flutter analyze (plugin)',
    'flutter test --coverage (app)', 'flutter test --coverage (plugin)', 'coverage gate',
    'node bridge + media tests', 'script tests (test/tool)', 'functions check + tests',
    'web build (rehearsal)', 'judged build config check', 'web build (judged)',
    'judged bundle check', 'gitleaks full history']) {
    assert.match(row(r.summary, step), /PLAN/, step);
  }
  assert.match(row(r.summary, 'judged build config check'), /--judged .*judged_defines\.json/);
  assert.match(row(r.summary, 'judged bundle check'), /--config .*judged_defines\.json build\/web/);
  assert.match(row(r.summary, 'Android debug APK'), /SKIP .*no Android SDK at/);
  assert.match(row(r.summary, 'Firestore rules (emulator)'), /SKIP .*firebase CLI not found/);
  assert.match(r.markdown, /^\| # \| Step \| Result \| Time \| Note \|/);
});

test('--quick skips Chrome, emulator, builds, scan and journey with the reason', () => {
  const r = verify(['--dry-run', '--quick']);
  assert.equal(r.code, 0, r.out);
  for (const step of ['plugin web tests (Chrome)', 'Firestore rules (emulator)',
    'web build (rehearsal)', 'web build (judged)', 'judged bundle check', 'Android debug APK',
    'iOS build (no codesign)', 'gitleaks full history', 'browser journey (e2e)']) {
    assert.match(row(r.summary, step), /SKIP .*--quick/, step);
  }
  assert.match(row(r.summary, 'coverage gate'), /PLAN/);
});

test('--no-native and --no-e2e skip only their steps', () => {
  const r = verify(['--dry-run', '--no-native', '--no-e2e']);
  assert.equal(r.code, 0, r.out);
  assert.match(row(r.summary, 'Android debug APK'), /SKIP .*--no-native/);
  assert.match(row(r.summary, 'iOS build (no codesign)'), /SKIP .*--no-native/);
  assert.match(row(r.summary, 'browser journey (e2e)'), /SKIP .*--no-e2e/);
  assert.match(row(r.summary, 'web build (judged)'), /PLAN/);
});

test('a green quick run passes, gates coverage and reports skips as not a pass', () => {
  const r = verify(['--quick']);
  assert.equal(r.code, 0, r.out);
  assert.match(r.out, /RESULT: GREEN \(with \d+ skipped; a skip is not a pass\)/);
  assert.match(row(r.summary, 'flutter analyze (app)'), /PASS/);
  assert.match(row(r.summary, 'coverage gate'), /PASS/);
  // lcov goes to the output directory, never the repository's coverage/.
  assert.match(r.calls, /flutter test --no-pub --coverage --coverage-path .*app\.lcov\.info/);
  assert.match(r.calls, /python3 -I tool\/coverage\/coverage_gate\.py --app-lcov .*app\.lcov\.info --plugin-lcov .*plugin\.lcov\.info/);
  assert.match(r.calls, /npm --prefix functions run check/);
  assert.ok(fs.existsSync(path.join(r.outDir, 'logs')), 'logs directory');
});

test('a failing step is reported, later steps still run, and the exit is 1', () => {
  const r = verify(['--quick'], { env: { FAIL_PATTERN: '^flutter analyze' } });
  assert.equal(r.code, 1, r.out);
  assert.match(r.out, /RESULT: RED/);
  assert.match(row(r.summary, 'flutter analyze (app)'), /FAIL .*exit 3; log .*flutter-analyze-app\.log/);
  assert.match(r.out, /stub flutter failing on purpose/, 'the failing log tail is shown');
  assert.match(row(r.summary, 'functions check + tests'), /PASS/);
  assert.match(r.calls, /npm --prefix functions test/);
});

test('the coverage gate never runs on stale data when a test step fails', () => {
  const r = verify(['--quick'], { env: { FAIL_PATTERN: '^flutter test --no-pub --coverage --coverage-path [^ ]*app' } });
  assert.equal(r.code, 1, r.out);
  assert.match(row(r.summary, 'flutter test --coverage (app)'), /FAIL/);
  assert.match(row(r.summary, 'coverage gate'), /FAIL .*no fresh lcov/);
  assert.doesNotMatch(r.calls, /coverage_gate\.py/);
});

test('missing lcov after passing tests fails the run instead of going GREEN', () => {
  const r = verify(['--quick'], { env: { NO_LCOV_PATTERN: 'plugin\\.lcov' } });
  assert.equal(r.code, 1, r.out);
  assert.match(row(r.summary, 'flutter test --coverage (plugin)'), /PASS/);
  assert.match(row(r.summary, 'coverage gate'), /FAIL .*no fresh lcov; gate not run/);
  assert.match(r.out, /RESULT: RED/);
  assert.doesNotMatch(r.out, /RESULT: GREEN/);
});

test('--allow-coverage-skip turns a missing lcov into an explicit skip', () => {
  const r = verify(['--quick', '--allow-coverage-skip'], { env: { NO_LCOV_PATTERN: 'plugin\\.lcov' } });
  assert.equal(r.code, 0, r.out);
  assert.match(row(r.summary, 'coverage gate'), /SKIP .*allowed by --allow-coverage-skip/);
  assert.match(r.out, /RESULT: GREEN \(with \d+ skipped/);
});

test('a relative VERIFY_OUT_DIR resolves against the caller, so plugin lcov is gated', () => {
  const cwd = tempDir();
  const r = verify(['--quick'], { cwd, outDir: 'rel-out' });
  assert.equal(r.code, 0, r.out);
  const abs = fs.realpathSync(path.join(cwd, 'rel-out'));
  assert.match(row(r.summary, 'coverage gate'), /PASS/);
  assert.ok(r.calls.includes(`--coverage-path ${abs}/app.lcov.info`), r.calls);
  assert.ok(r.calls.includes(`--coverage-path ${abs}/plugin.lcov.info`), r.calls);
  assert.ok(r.calls.includes(`--plugin-lcov ${abs}/plugin.lcov.info`), r.calls);
  assert.ok(fs.existsSync(path.join(abs, 'plugin.lcov.info')));
});

test('--e2e-base-url needs a URL', () => {
  for (const args of [['--e2e-base-url'], ['--e2e-base-url', 'build/web']]) {
    const r = verify(args);
    assert.equal(r.code, 2, r.out);
    assert.match(r.out, /--e2e-base-url needs an http\(s\) URL/);
  }
});

test('--update-baseline is passed to the coverage gate', () => {
  const r = verify(['--quick', '--update-baseline']);
  assert.equal(r.code, 0, r.out);
  assert.match(r.calls, /coverage_gate\.py .*--update-baseline/);
});

test('without node the Node steps are skipped with the reason', () => {
  const r = verify(['--quick'], { stubNames: ['flutter', 'python3'] });
  // /usr/bin may provide node on some runners; only assert when it does not.
  if (fs.existsSync('/usr/bin/node') || fs.existsSync('/bin/node')) return;
  assert.equal(r.code, 0, r.out);
  assert.match(row(r.summary, 'node bridge + media tests'), /SKIP .*node not found/);
  assert.match(row(r.summary, 'functions check + tests'), /SKIP .*node not found/);
});

test('warnings from a passing step are surfaced in the summary', () => {
  const r = verify(['--quick'], { env: { WARN_PATTERN: '^flutter analyze --no-pub' } });
  assert.equal(r.code, 0, r.out);
  assert.match(row(r.summary, 'flutter analyze (app)'), /PASS .*1 ::warning:: line\(s\); see .*flutter-analyze-app\.log/);
  assert.doesNotMatch(row(r.summary, 'flutter test --coverage (app)'), /warning/);
});

// A throwaway repository: a copy of verify_all.sh plus stub tool scripts, so
// the full (non-quick) flow including the browser journey runs in seconds.
function fakeRepo() {
  const repo = tempDir();
  const write = (rel, body, mode = 0o755) => {
    const file = path.join(repo, rel);
    fs.mkdirSync(path.dirname(file), { recursive: true });
    fs.writeFileSync(file, body);
    fs.chmodSync(file, mode);
  };
  write('tool/verify_all.sh', fs.readFileSync(script, 'utf8'));
  fs.mkdirSync(path.join(repo, 'packages/ai_logic_hybrid'), { recursive: true });
  fs.mkdirSync(path.join(repo, 'functions/node_modules'), { recursive: true });
  // The rehearsal and judged builds leave different index.html files in build/web.
  write('tool/build_web.sh', `#!/bin/sh
mkdir -p build/web
case "$*" in
  *FAKE_BACKEND=true*) echo rehearsal-build > build/web/index.html ;;
  *) echo judged-build > build/web/index.html ;;
esac
`);
  write('tool/check_build_config.sh', '#!/bin/sh\nexit 0\n');
  write('tool/check_web_bundle.sh', '#!/bin/sh\nexit 0\n');
  write('tool/e2e/run.sh', `#!/bin/sh
{
  echo "args=$*"
  echo "E2E_BASE_URL=\${E2E_BASE_URL-<unset>}"
  echo "E2E_ALLOW_AI=\${E2E_ALLOW_AI-<unset>}"
  echo "E2E_MODE=\${E2E_MODE-<unset>}"
  if [ -n "$1" ] && [ -f "$1/index.html" ]; then echo "index=$(cat "$1/index.html")"; fi
  echo ---
} >> "$E2E_LOG"
`);
  write('bin/chrome', '#!/bin/sh\nexit 0\n');
  write('bin/gitleaks', '#!/bin/sh\necho 8.30.1\n');
  return repo;
}

function e2eRun(extraArgs = [], env = {}) {
  const repo = fakeRepo();
  const e2eLog = path.join(tempDir(), 'e2e.log');
  const r = verify(['--no-native', ...extraArgs], {
    scriptPath: path.join(repo, 'tool/verify_all.sh'),
    env: {
      CHROME_EXECUTABLE: path.join(repo, 'bin/chrome'),
      GITLEAKS: path.join(repo, 'bin/gitleaks'),
      E2E_LOG: e2eLog,
      // A caller's environment must not leak into the default journey.
      E2E_BASE_URL: 'https://example.invalid/',
      E2E_ALLOW_AI: '1',
      ...env,
    },
  });
  const e2e = fs.existsSync(e2eLog) ? fs.readFileSync(e2eLog, 'utf8') : '';
  return { ...r, e2e, repo };
}

test('the default journey runs the rehearsal artifact with AI and URLs forced off', () => {
  const r = e2eRun();
  assert.equal(r.code, 0, r.out);
  assert.match(row(r.summary, 'browser journey (e2e)'), /PASS/);
  assert.doesNotMatch(r.summary, /hosted URL/);
  const runs = r.e2e.split('---\n').filter(Boolean);
  assert.equal(runs.length, 1, r.e2e);
  assert.match(runs[0], /args=.*e2e-rehearsal-web/);
  assert.match(runs[0], /E2E_BASE_URL=<unset>/);
  assert.match(runs[0], /E2E_ALLOW_AI=0/);
  assert.match(runs[0], /E2E_MODE=rehearsal/);
  // build/web holds the judged build by then; the journey saw the rehearsal.
  assert.match(runs[0], /index=rehearsal-build/);
  assert.equal(fs.readFileSync(path.join(r.repo, 'build/web/index.html'), 'utf8').trim(), 'judged-build');
});

test('without a rehearsal artifact the journey is skipped, never pointed at build/web', () => {
  const repo = fakeRepo();
  fs.writeFileSync(path.join(repo, 'tool/build_web.sh'), '#!/bin/sh\nexit 1\n');
  const e2eLog = path.join(tempDir(), 'e2e.log');
  const failed = verify(['--no-native'], {
    scriptPath: path.join(repo, 'tool/verify_all.sh'),
    env: { CHROME_EXECUTABLE: path.join(repo, 'bin/chrome'), GITLEAKS: path.join(repo, 'bin/gitleaks'), E2E_LOG: e2eLog },
  });
  assert.equal(failed.code, 1, failed.out);
  assert.match(row(failed.summary, 'web build (rehearsal)'), /FAIL/);
  assert.match(row(failed.summary, 'browser journey (e2e)'), /SKIP .*no rehearsal artifact/);
  assert.ok(!fs.existsSync(e2eLog), 'run.sh must not be called');
});

test('--e2e-base-url adds a separate hosted journey that still blocks AI', () => {
  const r = e2eRun(['--e2e-base-url', 'https://soussight.example.test/']);
  assert.equal(r.code, 0, r.out);
  assert.match(row(r.summary, 'browser journey (e2e)'), /PASS/);
  assert.match(row(r.summary, 'browser journey (hosted URL)'), /PASS/);
  const runs = r.e2e.split('---\n').filter(Boolean);
  assert.equal(runs.length, 2, r.e2e);
  assert.match(runs[1], /E2E_BASE_URL=https:\/\/soussight\.example\.test\//);
  assert.match(runs[1], /E2E_ALLOW_AI=0/);
  assert.match(runs[1], /E2E_MODE=auto/);
});
