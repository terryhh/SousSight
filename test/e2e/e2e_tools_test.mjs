// Unit tests for the hero-journey tooling in tool/e2e (SS-087): the request
// policy, the configuration check, the preview pixel test, the static
// server and run.sh's argument handling. No browser, network or Playwright
// install needed: run with `node --test test/e2e/`.
import assert from 'node:assert/strict';
import { spawn, spawnSync } from 'node:child_process';
import { mkdtempSync, mkdirSync, rmSync, writeFileSync } from 'node:fs';
import { request } from 'node:http';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { after, describe, test } from 'node:test';
import { fileURLToPath } from 'node:url';

import { COPY } from '../../tool/e2e/copy.mjs';
import {
  configProblems,
  decideRequest,
  fatalConsoleErrors,
  isProvisionalBlockError,
  partitionProvisionalErrors,
  initialPolicy,
  looksLikePreview,
  pixelStats,
  refinePolicy,
} from '../../tool/e2e/policy.mjs';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..', '..');
const e2e = join(root, 'tool', 'e2e');

const URLS = {
  gemini:
    'https://firebasevertexai.googleapis.com/v1beta/projects/p/locations/global/publishers/google/models/m:generateContent',
  generativeLanguage: 'https://generativelanguage.googleapis.com/v1beta/models/x',
  liveToken: 'http://localhost:8787/api/live-token',
  dinner: 'https://example.web.app/api/dinner-ready',
  vonage: 'https://api.nexmo.com/v1/messages',
  vonageApi: 'https://api-eu.vonage.com/v1/messages',
  firestore: 'https://firestore.googleapis.com/google.firestore.v1.Firestore/Write/channel',
  auth: 'https://identitytoolkit.googleapis.com/v1/accounts:signUp',
  appCheck: 'https://content-firebaseappcheck.googleapis.com/v1/x',
  installations: 'https://firebaseinstallations.googleapis.com/v1/projects/p',
  firebaseConfig: 'https://firebase.googleapis.com/v1alpha/projects/-/apps/x/webConfig',
  analytics: 'https://www.google-analytics.com/g/collect?v=2',
  gtm: 'https://www.googletagmanager.com/gtag/js?id=G-X',
  canvaskit: 'https://www.gstatic.com/flutter-canvaskit/abc/canvaskit.wasm',
  font: 'https://fonts.gstatic.com/s/roboto/v32/x.woff2',
  local: 'http://localhost:8787/main.dart.js',
  vonageAsset: 'http://localhost:8787/assets/vonage_logo.png',
};

describe('decideRequest', () => {
  test('analytics is aborted under every policy and never forbidden', () => {
    for (const policy of ['provisional', 'rehearsal', 'real']) {
      for (const url of [URLS.analytics, URLS.gtm]) {
        assert.deepEqual(decideRequest(url, policy, { allowAi: true }), {
          action: 'abort',
          kind: 'analytics',
          forbidden: false,
        });
      }
    }
  });

  test('rehearsal blocks and forbids every Firebase, AI, dinner and Vonage request', () => {
    for (const key of [
      'gemini',
      'generativeLanguage',
      'liveToken',
      'dinner',
      'vonage',
      'vonageApi',
      'firestore',
      'auth',
      'appCheck',
      'installations',
      'firebaseConfig',
    ]) {
      const decision = decideRequest(URLS[key], 'rehearsal', { allowAi: true });
      assert.equal(decision.action, 'abort', key);
      assert.equal(decision.forbidden, true, key);
    }
  });

  test('provisional blocks the same requests without failing yet', () => {
    for (const key of ['gemini', 'dinner', 'firestore', 'auth', 'liveToken']) {
      const decision = decideRequest(URLS[key], 'provisional', { allowAi: true });
      assert.equal(decision.action, 'abort', key);
      assert.equal(decision.forbidden, false, key);
    }
  });

  test('real lets Firebase through and aborts AI unless allowed', () => {
    for (const key of ['firestore', 'auth', 'appCheck', 'installations']) {
      assert.equal(decideRequest(URLS[key], 'real').action, 'allow', key);
    }
    for (const key of ['gemini', 'generativeLanguage', 'liveToken', 'dinner', 'vonage']) {
      assert.deepEqual(decideRequest(URLS[key], 'real'), {
        action: 'abort',
        kind: 'ai',
        forbidden: false,
      });
      assert.equal(decideRequest(URLS[key], 'real', { allowAi: true }).action, 'allow', key);
    }
  });

  test('app shell, CanvasKit, fonts and look-alike asset names are allowed', () => {
    for (const policy of ['provisional', 'rehearsal', 'real']) {
      for (const key of ['canvaskit', 'font', 'local', 'vonageAsset']) {
        assert.deepEqual(decideRequest(URLS[key], policy), {
          action: 'allow',
          kind: 'other',
          forbidden: false,
        });
      }
    }
  });

  test('an unknown policy is an error, not a silent allow', () => {
    assert.throws(() => decideRequest(URLS.gemini, 'auto'), /unknown policy/);
  });
});

describe('configuration', () => {
  test('defaults are valid', () => {
    assert.deepEqual(configProblems({}), []);
    assert.deepEqual(configProblems({ E2E_MODE: 'real', E2E_ALLOW_AI: '1' }), []);
    assert.deepEqual(configProblems({ E2E_MODE: 'rehearsal', E2E_REQUIRE_PREVIEW: '1' }), []);
  });

  test('bad values are reported', () => {
    assert.equal(configProblems({ E2E_MODE: 'demo' }).length, 1);
    assert.equal(configProblems({ E2E_REQUIRE_PREVIEW: 'yes' }).length, 1);
    assert.equal(configProblems({ E2E_ALLOW_AI: 'true' }).length, 1);
    assert.match(
      configProblems({ E2E_MODE: 'rehearsal', E2E_ALLOW_AI: '1' })[0],
      /no sense/,
    );
  });

  test('auto starts provisional; explicit modes start with their own policy', () => {
    assert.equal(initialPolicy('auto'), 'provisional');
    assert.equal(initialPolicy('rehearsal'), 'rehearsal');
    assert.equal(initialPolicy('real'), 'real');
  });
});

describe('refinePolicy', () => {
  const blocked = ['https://firestore.googleapis.com/x'];

  test('a rehearsal that was blocked provisionally fails: those requests were forbidden', () => {
    assert.deepEqual(refinePolicy('provisional', 'rehearsal', blocked), {
      policy: 'rehearsal',
      forbidden: blocked,
      reload: false,
    });
  });

  test('a real build that was blocked provisionally is reloaded, not failed', () => {
    assert.deepEqual(refinePolicy('provisional', 'real', blocked), {
      policy: 'real',
      forbidden: [],
      reload: true,
    });
    assert.equal(refinePolicy('provisional', 'real', []).reload, false);
  });

  test('an explicit mode keeps its policy', () => {
    assert.deepEqual(refinePolicy('real', 'real', blocked), {
      policy: 'real',
      forbidden: [],
      reload: false,
    });
    assert.equal(refinePolicy('rehearsal', 'rehearsal', []).policy, 'rehearsal');
  });

  test('an unknown mode is an error', () => {
    assert.throws(() => refinePolicy('provisional', 'auto', []), /unknown mode/);
  });
});

describe('provisional console errors', () => {
  // Captured verbatim from a real-build auto run (report.json, 2026-11-26).
  const ANALYTICS_FETCH =
    'TypeError: Failed to fetch\n    at https://www.gstatic.com/firebasejs/13.1.0/firebase-analytics.js:1:11014\n' +
    '    at retryIfServerError (https://www.gstatic.com/firebasejs/13.1.0/firebase-analytics.js:1:7824)\n' +
    '    at createInstallationRequest (https://www.gstatic.com/firebasejs/13.1.0/firebase-analytics.js:1:10990)';
  const BLOCKED_LINE = 'Failed to load resource: net::ERR_BLOCKED_BY_CLIENT.Inspector';
  const UNRELATED = 'Unrelated first-load widget failure';
  const blocked = [
    'https://firebase.googleapis.com/v1alpha/projects/-/apps/1:4:web:c/webConfig',
    'https://firebaseinstallations.googleapis.com/v1/projects/p/installations',
  ];

  test('an unrelated first-load error still fails the run after the reload', () => {
    // The regression Codex found: refine -> set aside -> reload left this
    // error only in the exempt bucket, so the run went green.
    const firstLoad = [BLOCKED_LINE, ANALYTICS_FETCH, UNRELATED];
    const { setAside, fatal } = partitionProvisionalErrors(firstLoad, blocked);
    assert.deepEqual(setAside, [BLOCKED_LINE, ANALYTICS_FETCH]);
    assert.deepEqual(fatal, [UNRELATED]);
    // What the spec's final check sees: the first load's leftovers plus the
    // reloaded page's errors (none here).
    assert.deepEqual(fatalConsoleErrors([...fatal]), [UNRELATED]);
  });

  test('the known analytics fetch failure is set aside only when its host was blocked', () => {
    assert.equal(isProvisionalBlockError(ANALYTICS_FETCH, blocked), true);
    assert.equal(isProvisionalBlockError(ANALYTICS_FETCH, []), false);
    assert.equal(
      isProvisionalBlockError(ANALYTICS_FETCH, ['https://firestore.googleapis.com/x']),
      false,
      'a different host being blocked does not explain this failure',
    );
  });

  test('the remote-config installation failure (trunk added Remote Config) is exempt only when installations was blocked', () => {
    // Captured verbatim from a real-build auto run at ae9e8be (phone).
    const REMOTE_CONFIG_FETCH =
      'TypeError: Failed to fetch\n    at https://www.gstatic.com/firebasejs/13.1.0/firebase-remote-config.js:1:11751\n' +
      '    at retryIfServerError (https://www.gstatic.com/firebasejs/13.1.0/firebase-remote-config.js:1:8563)\n' +
      '    at createInstallationRequest (https://www.gstatic.com/firebasejs/13.1.0/firebase-remote-config.js:1:11727)\n' +
      '    at async registerInstallation (https://www.gstatic.com/firebasejs/13.1.0/firebase-remote-config.js:1:11351)';
    assert.equal(isProvisionalBlockError(REMOTE_CONFIG_FETCH, blocked), true);
    assert.equal(
      isProvisionalBlockError(REMOTE_CONFIG_FETCH, [blocked[0]]),
      false,
      'only the webConfig request blocked: not explained',
    );
    const { fatal } = partitionProvisionalErrors(
      [REMOTE_CONFIG_FETCH, ANALYTICS_FETCH, UNRELATED],
      blocked,
    );
    assert.deepEqual(fatal, [UNRELATED]);
  });

  test('rehearsal forbids Remote Config fetches', () => {
    assert.equal(
      decideRequest('https://firebaseremoteconfig.googleapis.com/v1/projects/p/namespaces/firebase:fetch', 'rehearsal').forbidden,
      true,
    );
  });

  test('each Firebase module is tied to its own hosts', () => {
    const fetchIn = (module) =>
      `TypeError: Failed to fetch\n    at https://www.gstatic.com/firebasejs/13.1.0/${module}.js:1:1`;
    const firestore = ['https://firestore.googleapis.com/google.firestore.v1.Firestore/Listen'];
    assert.equal(isProvisionalBlockError(fetchIn('firebase-firestore'), firestore), true);
    assert.equal(isProvisionalBlockError(fetchIn('firebase-auth'), firestore), false);
    assert.equal(isProvisionalBlockError(fetchIn('firebase-unknown'), firestore), false);
  });

  test('look-alike errors are not exempt', () => {
    const lookAlikes = [
      // fetch failure in app code, not in the Firebase SDK
      'TypeError: Failed to fetch\n    at http://localhost:8787/main.dart.js:1:2',
      // SDK module served from somewhere else
      'TypeError: Failed to fetch\n    at https://evil.example/firebasejs/13.1.0/firebase-analytics.js:1:2',
      // a different error raised inside the SDK
      'TypeError: Cannot read properties of undefined\n    at https://www.gstatic.com/firebasejs/13.1.0/firebase-analytics.js:1:2',
      // Failed to fetch with no stack
      'TypeError: Failed to fetch',
      // a different network failure
      'Failed to load resource: net::ERR_CONNECTION_REFUSED',
      'Failed to load resource: the server responded with a status of 500 ()',
      UNRELATED,
    ];
    for (const text of lookAlikes) {
      assert.equal(isProvisionalBlockError(text, blocked), false, text);
    }
  });

  test('nothing is set aside when nothing was blocked', () => {
    assert.deepEqual(partitionProvisionalErrors([BLOCKED_LINE, UNRELATED], []), {
      setAside: [],
      fatal: [BLOCKED_LINE, UNRELATED],
    });
  });

  test('the final check ignores only Chrome\'s line for requests the run aborted', () => {
    assert.deepEqual(
      fatalConsoleErrors([
        BLOCKED_LINE,
        'Failed to load resource: net::ERR_BLOCKED_BY_CLIENT',
        'Failed to load resource: net::ERR_BLOCKED_BY_CLIENT.Inspector and more',
        UNRELATED,
      ]),
      ['Failed to load resource: net::ERR_BLOCKED_BY_CLIENT.Inspector and more', UNRELATED],
    );
  });
});

describe('preview pixel test', () => {
  const fill = (n, [r, g, b]) => {
    const data = new Uint8ClampedArray(n * 4);
    for (let i = 0; i < n; i += 1) data.set([r, g, b, 255], i * 4);
    return data;
  };

  test('the empty placeholder gradient is not a preview', () => {
    const start = pixelStats(fill(100, [0x21, 0x49, 0x37]));
    const end = pixelStats(fill(100, [0x10, 0x2d, 0x24]));
    assert.equal(start.gradientShare, 1);
    assert.equal(end.gradientShare, 1);
    assert.equal(looksLikePreview(start), false);
  });

  test('a bright camera frame is a preview', () => {
    const stats = pixelStats(fill(100, [180, 170, 150]));
    assert.equal(stats.gradientShare, 0);
    assert.deepEqual(stats.mean, [180, 170, 150]);
    assert.equal(looksLikePreview(stats), true);
  });

  test('half and half is not enough', () => {
    const data = new Uint8ClampedArray(8 * 4);
    data.set(fill(4, [0x21, 0x49, 0x37]), 0);
    data.set(fill(4, [200, 200, 200]), 16);
    const stats = pixelStats(data);
    assert.equal(stats.gradientShare, 0.5);
    assert.equal(looksLikePreview(stats), false);
  });

  test('dark but not green (e.g. a black frame) is not counted as the gradient', () => {
    assert.equal(pixelStats(fill(10, [40, 10, 10])).gradientShare, 0);
  });

  test('missing or empty input abstains', () => {
    assert.equal(looksLikePreview(undefined), false);
    assert.equal(looksLikePreview({}), false);
    assert.equal(looksLikePreview(pixelStats(new Uint8ClampedArray(0))), false);
  });
});

describe('serve.mjs', () => {
  const dirs = [];
  const children = [];
  after(() => {
    for (const child of children) child.kill();
    for (const dir of dirs) rmSync(dir, { recursive: true, force: true });
  });

  async function start() {
    const dir = mkdtempSync(join(tmpdir(), 'soussight-e2e-'));
    dirs.push(dir);
    const build = join(dir, 'web');
    mkdirSync(join(build, 'assets'), { recursive: true });
    writeFileSync(join(build, 'index.html'), '<!doctype html><title>app</title>');
    writeFileSync(join(build, 'main.dart.js'), 'console.log(1)');
    writeFileSync(join(build, 'assets', 'x.wasm'), 'wasm');
    writeFileSync(join(dir, 'secret.txt'), 'secret');
    const child = spawn(process.execPath, [join(e2e, 'serve.mjs'), build, '0']);
    children.push(child);
    const port = await new Promise((resolvePort, reject) => {
      child.stdout.on('data', (chunk) => {
        const match = /localhost:(\d+)/.exec(String(chunk));
        if (match) resolvePort(Number(match[1]));
      });
      child.on('exit', (code) => reject(new Error(`server exited ${code}`)));
    });
    return port;
  }

  function get(port, path) {
    return new Promise((resolveGet, reject) => {
      const req = request({ host: 'localhost', port, path }, (res) => {
        let body = '';
        res.on('data', (c) => (body += c));
        res.on('end', () => resolveGet({ status: res.statusCode, headers: res.headers, body }));
      });
      req.on('error', reject);
      req.end();
    });
  }

  test('serves files with types and the hosting security headers', async () => {
    const port = await start();
    const js = await get(port, '/main.dart.js');
    assert.equal(js.status, 200);
    assert.match(js.headers['content-type'], /javascript/);
    assert.equal(js.headers['cache-control'], 'no-store');
    assert.match(js.headers['permissions-policy'], /camera=\(self\)/);
    assert.equal(js.headers['x-content-type-options'], 'nosniff');
    assert.equal((await get(port, '/assets/x.wasm')).headers['content-type'], 'application/wasm');
    assert.match((await get(port, '/')).body, /<title>app/);
  });

  test('routes fall back to the shell; missing assets are 404', async () => {
    const port = await start();
    assert.match((await get(port, '/cook?recipe=x')).body, /<title>app/);
    assert.equal((await get(port, '/assets/missing.png')).status, 404);
  });

  test('never serves files outside the build directory and survives bad escapes', async () => {
    const port = await start();
    const traversal = await get(port, '/..%2fsecret.txt');
    assert.equal(traversal.status, 404);
    assert.doesNotMatch(traversal.body, /secret/);
    assert.equal((await get(port, '/%E0%A4%A.js')).status, 404);
    assert.equal((await get(port, '/main.dart.js')).status, 200, 'still serving');
  });
});

describe('run.sh', () => {
  test('refuses a missing build directory before installing or launching anything', () => {
    const result = spawnSync(join(e2e, 'run.sh'), ['/nonexistent/build/web'], {
      encoding: 'utf8',
      env: { ...process.env, E2E_BASE_URL: '' },
    });
    assert.equal(result.status, 2);
    assert.match(result.stderr, /No Flutter web build/);
    assert.match(result.stderr, /build_web\.sh --dart-define=FAKE_BACKEND=true/);
  });
});

describe('COPY (app wording the journey matches)', () => {
  // [entry, wording before the SS-089 UX pass, wording after it]
  const pairs = [
    ['rehearsalBanner', 'Rehearsal mode · Camera, microphone, and Gemini are not used.', 'Practice mode (pretend answers) · Nothing is sent.'],
    ['pantryUnavailable', 'Ingredient matching is unavailable right now. Pick a recipe below.', "Matching your food didn't work. Pick a recipe below."],
    ['composer', 'Ask Coach Lite (on-device)…', 'Ask a question…'],
    ['coachBlocked', "This device can't run the on-device coach right now.", "I can't answer that here yet."],
    ['watchRefused', "This device's on-device model can't look at photos.", 'Watch stopped: the camera view was unclear.'],
    ['ledgerButton', 'What was sent', 'What we sent'],
    ['ledgerHeading', 'What left this device', 'What we sent'],
    ['onDeviceButton', 'On-device AI', 'On this device'],
    ['simulatedBadge', 'Where this ran: Simulated', 'Where this ran: Practice mode'],
  ];

  test('watchRefused accepts the no-vision refusal of a build without Live', () => {
    // SS-089: a real build with no photo model and no Live coach refuses up
    // front with this wording; the journey must treat it as a refusal.
    assert.match(
      "This device can't check photos yet — \"On this device\" shows how to set it up. Meanwhile, look for: Both slices lie flat.",
      COPY.watchRefused,
    );
    assert.match("This device's on-device model can't look at photos.", COPY.watchRefused);
    assert.doesNotMatch('Watching on this device for: the cue', COPY.watchRefused);
  });

  test('each entry accepts the old and the new wording', () => {
    for (const [key, before, now] of pairs) {
      assert.ok(COPY[key] instanceof RegExp, key);
      assert.match(before, COPY[key], `${key} (old)`);
      assert.match(now, COPY[key], `${key} (new)`);
    }
  });

  test('button names are matched exactly, not by substring', () => {
    assert.doesNotMatch('What was sent and more', COPY.ledgerButton);
    assert.doesNotMatch('Keep Pantry scan on this device', COPY.onDeviceButton);
    assert.doesNotMatch('Find my meal now', COPY.findMeal);
  });

  test('literal punctuation is escaped', () => {
    assert.match("Don't send", COPY.consentDecline);
    assert.doesNotMatch('Nothing was sentX', /^Nothing was sent\.$/);
    assert.doesNotMatch('Nothing was sentX', COPY.coachBlocked);
  });

  test('the live-coach alert does not match unrelated text', () => {
    assert.doesNotMatch('Connect your camera and microphone', COPY.liveCoachNeeded);
  });
});
