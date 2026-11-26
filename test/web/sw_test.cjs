// Unit tests for the SS-110 app-shell worker (web/sw.js), its registration in
// web/flutter_bootstrap.js, the manifest and the sw.js Hosting header.
// Everything runs against fakes: no browser, no network. Evidence level: fakes.
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const ROOT = path.join(__dirname, '../..');
const SW_SOURCE = fs.readFileSync(path.join(ROOT, 'web/sw.js'), 'utf8');
const BOOTSTRAP_SOURCE = fs.readFileSync(path.join(ROOT, 'web/flutter_bootstrap.js'), 'utf8');

const ORIGIN = 'https://soussight.example';
const SCOPE = `${ORIGIN}/`;
// Synthetic build ids, built at runtime (AGENT.md §5.8).
const COMMIT = '0123456789abcdef'.repeat(3).slice(0, 40);
const NEXT_COMMIT = 'fedcba9876543210'.repeat(3).slice(0, 40);
const ENGINE = 'abcdef0123456789'.repeat(3).slice(0, 40);
const NEXT_ENGINE = '9876543210fedcba'.repeat(3).slice(0, 40);
// Flutter's random per-build number, as written into flutter_bootstrap.js.
const N = '1111';
const NEXT_N = '2222';
const BUILD = `${COMMIT}-${N}`;
const NEXT_BUILD = `${NEXT_COMMIT}-${NEXT_N}`;
// The same commit rebuilt (for example with other repository variables).
const REBUILD = `${COMMIT}-${NEXT_N}`;
// Built from parts so this file never carries the Gemini Developer API host
// as one literal (tool/check_web_bundle.sh greps for it).
const GEMINI_DEV_HOST = ['generative', 'language.googleapis.com'].join('');

class FakeCache {
  constructor() {
    this.entries = new Map();
  }
  static key(request) {
    return typeof request === 'string' ? request : request.url;
  }
  async match(request) {
    const response = this.entries.get(FakeCache.key(request));
    return response ? response.clone() : undefined;
  }
  async put(request, response) {
    if (response.bodyUsed) throw new TypeError('body already used');
    this.entries.set(FakeCache.key(request), response);
  }
  async keys() {
    return [...this.entries.keys()].map((url) => ({ url }));
  }
}

class FakeCacheStorage {
  constructor() {
    this.store = new Map();
  }
  async open(name) {
    if (!this.store.has(name)) this.store.set(name, new FakeCache());
    return this.store.get(name);
  }
  async keys() {
    return [...this.store.keys()];
  }
  async delete(name) {
    return this.store.delete(name);
  }
  urls(name) {
    return [...(this.store.get(name)?.entries.keys() ?? [])];
  }
}

function okResponse(body, type = 'application/javascript') {
  return new Response(body, { status: 200, headers: { 'content-type': type } });
}

/** A fresh worker global running web/sw.js registered as sw.js?v=<version>. */
function worker({ version = BUILD, active = null, network, setTimeoutImpl, caches } = {}) {
  const listeners = new Map();
  const calls = [];
  const logs = [];
  const counters = { claim: 0, skipWaiting: 0 };
  const cacheStorage = caches ?? new FakeCacheStorage();
  const handler = network ?? defaultNetwork({ deploy: deployOf(version) });
  const sandbox = {
    URL,
    Headers,
    Response,
    Promise,
    Number,
    Object,
    Array,
    Error,
    TypeError,
    setTimeout: setTimeoutImpl ?? setTimeout,
    clearTimeout,
    console: {
      warn: (...args) => logs.push(args.map(String).join(' ')),
      log: (...args) => logs.push(args.map(String).join(' ')),
      error: (...args) => logs.push(args.map(String).join(' ')),
    },
    caches: cacheStorage,
    location: { href: version === null ? `${ORIGIN}/sw.js` : `${ORIGIN}/sw.js?v=${encodeURIComponent(version)}` },
    registration: { scope: SCOPE, active },
    clients: {
      claim: async () => {
        counters.claim += 1;
      },
    },
    skipWaiting: async () => {
      counters.skipWaiting += 1;
    },
    addEventListener(type, listener) {
      if (!listeners.has(type)) listeners.set(type, []);
      listeners.get(type).push(listener);
    },
    fetch: async (input, init) => {
      const url = typeof input === 'string' ? input : input.url;
      calls.push({ url, init });
      return handler(url, init);
    },
  };
  sandbox.self = sandbox;
  vm.createContext(sandbox);
  vm.runInContext(SW_SOURCE, sandbox, { filename: 'web/sw.js' });

  function emit(type, event) {
    for (const listener of listeners.get(type) ?? []) listener(event);
  }
  async function lifecycle(type) {
    const waits = [];
    emit(type, { waitUntil: (promise) => waits.push(promise) });
    await Promise.all(waits);
  }
  return {
    shell: sandbox.soussightShell,
    caches: cacheStorage,
    calls,
    logs,
    counters,
    listeners,
    install: () => lifecycle('install'),
    activate: () => lifecycle('activate'),
    /** Dispatches a fetch event; resolves to the response, or null if not intercepted. */
    async fetch(request) {
      let responded = null;
      emit('fetch', {
        request,
        respondWith: (promise) => {
          responded = Promise.resolve(promise);
        },
        waitUntil() {},
      });
      return responded ? responded : null;
    },
    async message(data) {
      const waits = [];
      emit('message', { data, waitUntil: (promise) => waits.push(promise) });
      await Promise.all(waits);
    },
  };
}

/** The deployment a build id describes: { commit?, n, engine }. */
function deployOf(version) {
  const match = /^(.*)-([0-9]+)$/.exec(version ?? '');
  if (!match) return { commit: COMMIT, n: N, engine: ENGINE };
  return { commit: match[1] === 'local' ? undefined : match[1], n: match[2], engine: ENGINE };
}

/** What Flutter writes into a build's flutter_bootstrap.js, reduced to the parts sw.js reads. */
function bootstrapText({ n, engine }) {
  const number = n === null ? 'null' : `"${n}"`;
  return `_flutter.buildConfig = {"engineRevision":"${engine}","builds":[]};\nconst localBuild = ${number} /* deprecated */;`;
}

/**
 * Network that serves a deployment: shell files, SDK modules, version.json and
 * a bootstrap naming the build number. [deploy] may be mutated mid-test to
 * model a new release landing on Hosting.
 */
function defaultNetwork({ deploy = { commit: COMMIT, n: N, engine: ENGINE }, missing = [], fail = [] } = {}) {
  return async (url) => {
    const parsed = new URL(url);
    if (fail.some((pattern) => url.includes(pattern))) throw new TypeError('Failed to fetch');
    if (parsed.origin === ORIGIN) {
      const file = parsed.pathname.slice(1);
      if (missing.includes(file)) return new Response('not found', { status: 404 });
      if (file === 'version.json') {
        return okResponse(JSON.stringify({ app_name: 'soussight', version: '1.0.0', commit: deploy.commit }), 'application/json');
      }
      if (file === 'flutter_bootstrap.js') return okResponse(bootstrapText(deploy));
      if (deploy.tag) return okResponse(`network:${deploy.tag}:${file}`);
      return okResponse(`network:${file}`);
    }
    if (parsed.hostname === 'www.gstatic.com' || parsed.hostname === 'fonts.gstatic.com') {
      return okResponse(`network:${url}`);
    }
    return okResponse('api');
  };
}

const offline = async () => {
  throw new TypeError('Failed to fetch');
};

function request(url, { method = 'GET', mode = 'cors', headers = {} } = {}) {
  return { url, method, mode, headers: new Headers(headers) };
}

async function text(response) {
  return response ? response.text() : null;
}

// ---------------------------------------------------------------- routing

test('API, auth and token-bearing traffic is never intercepted', () => {
  const { shell } = worker();
  const passthrough = [
    request('https://firestore.googleapis.com/google.firestore.v1.Firestore/Listen/channel'),
    request('https://firebasevertexai.googleapis.com/v1beta/projects/p/models/m:generateContent'),
    request('https://firebaseappcheck.googleapis.com/v1/projects/p/apps/a:exchangeRecaptchaEnterpriseToken'),
    request('https://content-firebaseappcheck.googleapis.com/v1/projects/p/apps/a:exchangeDebugToken'),
    request('https://identitytoolkit.googleapis.com/v1/accounts:signUp'),
    request('https://securetoken.googleapis.com/v1/token'),
    request('https://firebaseinstallations.googleapis.com/v1/projects/p/installations'),
    request('https://firebaseremoteconfig.googleapis.com/v1/projects/p/namespaces/firebase:fetch'),
    request(`https://${GEMINI_DEV_HOST}/v1beta/models`),
    request('https://googleapis.com/anything'),
    request('https://us-central1-devfest.cloudfunctions.net/liveSession'),
    request('https://livesession-abc-uc.a.run.app/'),
    request(`${ORIGIN}/api/live-session`),
    request(`${ORIGIN}/api/dinner-ready`),
    request(`${ORIGIN}/__/auth/handler`),
    request(`${ORIGIN}/__/firebase/init.json`),
    request(`${ORIGIN}/main.dart.js`, { headers: { 'X-Firebase-AppCheck': 'synthetic' } }),
    request(`${ORIGIN}/main.dart.js`, { headers: { Authorization: 'Bearer synthetic' } }),
    request(`${ORIGIN}/main.dart.js`, { method: 'POST' }),
    request(`${ORIGIN}/assets/video.mp4`, { headers: { Range: 'bytes=0-' } }),
    request(`${ORIGIN}/sw.js`),
    request(`${ORIGIN}/flutter_service_worker.js`),
    request(`${ORIGIN}/main.dart.js?token=synthetic`),
    request('https://www.google.com/recaptcha/enterprise.js?render=k'),
    request('https://www.gstatic.com/recaptcha/releases/abc/recaptcha__en.js'),
    request('https://www.gstatic.com/firebasejs/12.0.0/firebase-app.js'),
    request(`https://www.gstatic.com/firebasejs/${'13.1.0'}/firebase-app.js?v=1`),
    request('https://www.googletagmanager.com/gtag/js'),
    request('https://fonts.googleapis.com/css2?family=Roboto'),
    request('https://cdn.example.com/lib.js'),
    request('wss://example.com/socket'),
    request('chrome-extension://abc/script.js'),
  ];
  for (const r of passthrough) {
    assert.equal(shell.routeFor(r), 'passthrough', `${r.method} ${r.url}`);
  }
});

test('the shell, pinned SDK, CanvasKit and fonts are cache-first; index and version are network-first', () => {
  const { shell } = worker();
  const expectations = [
    [`${ORIGIN}/main.dart.js`, 'cache-first'],
    [`${ORIGIN}/flutter_bootstrap.js`, 'cache-first'],
    [`${ORIGIN}/flutter.js`, 'cache-first'],
    [`${ORIGIN}/soussight_live.js`, 'cache-first'],
    [`${ORIGIN}/assets/FontManifest.json`, 'cache-first'],
    [`${ORIGIN}/assets/fonts/MaterialIcons-Regular.otf`, 'cache-first'],
    [`${ORIGIN}/assets/packages/ai_logic_hybrid/assets/ai_logic_hybrid.js`, 'cache-first'],
    [`${ORIGIN}/canvaskit/chromium/canvaskit.wasm`, 'cache-first'],
    [`${ORIGIN}/icons/Icon-maskable-512.png`, 'cache-first'],
    [`https://www.gstatic.com/firebasejs/${shell.FIREBASE_JS_SDK_VERSION}/firebase-ai.js`, 'cache-first'],
    [`https://www.gstatic.com/firebasejs/${shell.FIREBASE_JS_SDK_VERSION}/firebase-firestore-pipelines.js`, 'cache-first'],
    [`https://www.gstatic.com/flutter-canvaskit/${ENGINE}/chromium/canvaskit.wasm`, 'cache-first'],
    [`https://www.gstatic.com/flutter-canvaskit/${ENGINE}/canvaskit.js`, 'cache-first'],
    ['https://fonts.gstatic.com/s/roboto/v32/KFOmCnqEu92Fr1Me5Q.ttf', 'cache-first'],
    [`${ORIGIN}/`, 'network-first'],
    [`${ORIGIN}/index.html`, 'network-first'],
    [`${ORIGIN}/version.json`, 'network-first'],
  ];
  for (const [url, route] of expectations) {
    assert.equal(shell.routeFor(request(url)), route, url);
  }
  assert.equal(shell.routeFor(request(`${ORIGIN}/cook/session-1`, { mode: 'navigate' })), 'navigate');
  assert.equal(shell.routeFor(request(`${ORIGIN}/?step=3`, { mode: 'navigate' })), 'navigate');
  // Navigations to reserved or API paths still go straight to the network.
  assert.equal(shell.routeFor(request(`${ORIGIN}/__/auth/handler?x=1`, { mode: 'navigate' })), 'passthrough');
  assert.equal(shell.routeFor(request(`${ORIGIN}/api/vonage-status`, { mode: 'navigate' })), 'passthrough');
  // Unversioned CanvasKit paths are not immutable, so they are not cached.
  assert.equal(shell.routeFor(request('https://www.gstatic.com/flutter-canvaskit/latest/canvaskit.js')), 'passthrough');
});

test('the cache is named by the build: commit plus Flutter build number', () => {
  assert.equal(worker().shell.cacheName, `soussight-shell-${BUILD}`);
  assert.equal(worker({ version: 'local-42' }).shell.cacheName, 'soussight-shell-local-42');
  // Codex #249: the same commit rebuilt is a different worker and cache.
  assert.notEqual(worker({ version: REBUILD }).shell.cacheName, worker().shell.cacheName);
});

test('the deployed identity combines version.json commit and the bootstrap build number', () => {
  const { shell } = worker();
  assert.equal(shell.identityOf({ commit: COMMIT }, bootstrapText({ n: N, engine: ENGINE })), BUILD);
  assert.equal(shell.identityOf({ commit: COMMIT }, bootstrapText({ n: NEXT_N, engine: ENGINE })), REBUILD);
  assert.equal(shell.identityOf({ version: '1.0.0' }, bootstrapText({ n: '7', engine: ENGINE })), 'local-7');
  assert.equal(shell.identityOf({ commit: 'nope' }, bootstrapText({ n: '7', engine: ENGINE })), 'local-7');
  assert.equal(shell.identityOf({ commit: COMMIT }, bootstrapText({ n: null, engine: ENGINE })), '');
  // The pattern that reads the number never matches its own source text.
  assert.equal(shell.identityOf({ commit: COMMIT }, BOOTSTRAP_SOURCE), '');
});

test('an unknown or missing version makes the worker inert and clears SousSight caches (kill switch)', async () => {
  for (const version of [null, '', 'off', 'main', COMMIT, `${COMMIT.toUpperCase()}-1`, `${COMMIT}x-1`, 'local-abc', 'local-', `${COMMIT}-`]) {
    const caches = new FakeCacheStorage();
    await caches.open(`soussight-shell-${BUILD}`);
    await caches.open('someone-else');
    const w = worker({ version, caches });
    assert.equal(w.shell.enabled, false, String(version));
    assert.equal(w.shell.routeFor(request(`${ORIGIN}/main.dart.js`)), 'passthrough');
    assert.equal(await w.fetch(request(`${ORIGIN}/`, { mode: 'navigate' })), null);
    await w.install();
    await w.activate();
    assert.deepEqual(await caches.keys(), ['someone-else']);
    assert.equal(w.calls.length, 0, 'an inert worker fetches nothing');
    assert.equal(w.counters.claim, 0);
  }
});

// ---------------------------------------------------------------- install

test('install pre-caches the shell, the pinned Firebase SDK modules, and nothing else', async () => {
  const w = worker();
  await w.install();
  const cached = w.caches.urls(w.shell.cacheName);
  for (const file of [...w.shell.SHELL_REQUIRED, ...w.shell.SHELL_OPTIONAL]) {
    assert.ok(cached.includes(`${ORIGIN}/${file}`), file);
  }
  for (const module of w.shell.FIREBASE_SDK_MODULES) {
    assert.ok(cached.includes(`https://www.gstatic.com/firebasejs/13.1.0/${module}`), module);
  }
  for (const call of w.calls) {
    const host = new URL(call.url).hostname;
    assert.ok(host === 'soussight.example' || host === 'www.gstatic.com', `unexpected install fetch ${call.url}`);
  }
  assert.ok(!cached.some((url) => /googleapis\.com|\/api\/|\/__\//.test(url)));
});

test('install refuses a cache whose deployment is another commit or another build of the same commit', async () => {
  for (const other of [NEXT_BUILD, REBUILD]) {
    const w = worker({ network: defaultNetwork({ deploy: deployOf(other) }) });
    await assert.rejects(w.install(), /build changed during install/, other);
    assert.deepEqual(await w.caches.keys(), []);
    assert.ok(w.logs.every((line) => !line.includes(ORIGIN)), 'logs carry no URLs');
  }
});

test('install reads the deployed bootstrap through the network, never a cached copy', async () => {
  const w = worker();
  await w.install();
  const probes = w.calls.filter((call) => call.url.includes('flutter_bootstrap.js?'));
  assert.equal(probes.length, 2, 'checked before and after the downloads');
  for (const probe of probes) {
    assert.equal(probe.init.cache, 'no-store');
    assert.equal(w.shell.routeFor(request(probe.url)), 'passthrough', 'no worker answers the probe');
  }
});

// Codex #249 finding 3: a deploy that lands while install downloads.
for (const [label, switchAfter] of [
  ['after index.html', 'index.html'],
  ['after flutter_bootstrap.js', 'flutter_bootstrap.js'],
  ['after main.dart.js', 'main.dart.js'],
  ['during the optional files', 'manifest.json'],
]) {
  test(`a deploy that lands ${label} discards the half-built cache`, async () => {
    const deploy = { ...deployOf(BUILD), tag: 'A' };
    const base = defaultNetwork({ deploy });
    const caches = new FakeCacheStorage();
    const w = worker({
      caches,
      network: async (url, init) => {
        const response = await base(url, init);
        if (new URL(url).pathname === `/${switchAfter}` && !url.includes('?')) {
          Object.assign(deploy, deployOf(NEXT_BUILD), { tag: 'B' });
        }
        return response;
      },
    });
    await assert.rejects(w.install(), /build changed during install/);
    assert.deepEqual(await caches.keys(), [], 'no cache mixes builds A and B');
  });
}

test('install fails cleanly when a required shell file is missing', async () => {
  const w = worker({ network: defaultNetwork({ missing: ['main.dart.js'] }) });
  await assert.rejects(w.install(), /required shell file missing/);
  assert.deepEqual(await w.caches.keys(), [], 'the partial cache is deleted');
});

test('a missing optional file or SDK module does not fail the install', async () => {
  const base = defaultNetwork();
  const w = worker({
    network: async (url, init) => {
      if (url.endsWith('/firebase-analytics.js')) throw new TypeError('blocked');
      if (url.endsWith('/soussight_live.js')) return new Response('', { status: 404 });
      return base(url, init);
    },
  });
  await w.install();
  const cached = w.caches.urls(w.shell.cacheName);
  assert.ok(cached.includes(`${ORIGIN}/main.dart.js`));
  assert.ok(!cached.includes(`${ORIGIN}/soussight_live.js`));
});

test('a local build (no stamped commit) installs under local-<n>', async () => {
  const w = worker({ version: 'local-7' });
  await w.install();
  assert.ok(w.caches.urls('soussight-shell-local-7').includes(`${ORIGIN}/main.dart.js`));
});

// ---------------------------------------------------------------- lifecycle

test('the first install claims the open page; an update waits for the next launch', async () => {
  const first = worker();
  await first.install();
  await first.activate();
  assert.equal(first.counters.claim, 1);
  assert.equal(first.counters.skipWaiting, 0);

  const caches = first.caches;
  const update = worker({
    version: NEXT_BUILD,
    active: { scriptURL: `${ORIGIN}/sw.js?v=${BUILD}` },
    network: defaultNetwork({ deploy: deployOf(NEXT_BUILD) }),
    caches,
  });
  await update.install();
  assert.deepEqual((await caches.keys()).sort(), [`soussight-shell-${BUILD}`, `soussight-shell-${NEXT_BUILD}`].sort(),
    'the running build keeps its cache while the update waits');
  assert.equal(update.counters.skipWaiting, 0, 'never skipWaiting: no mid-session takeover');
  await update.activate();
  assert.equal(update.counters.claim, 0, 'an update never claims open pages');
  assert.deepEqual(await caches.keys(), [`soussight-shell-${NEXT_BUILD}`]);
});

// Codex #249 finding 1: the update must open offline as completely as the
// build it replaces, including what only the page's warm-up taught build A.
async function warmedBuildA(caches, engine = ENGINE) {
  const a = worker({ caches, network: defaultNetwork({ deploy: { ...deployOf(BUILD), engine, tag: 'A' } }) });
  await a.install();
  await a.activate();
  await a.message({
    type: 'soussight-warm',
    urls: [
      `https://www.gstatic.com/flutter-canvaskit/${engine}/chromium/canvaskit.js`,
      `https://www.gstatic.com/flutter-canvaskit/${engine}/chromium/canvaskit.wasm`,
      'https://fonts.gstatic.com/s/roboto/v32/regular.woff2',
      `${ORIGIN}/assets/assets/reference-cooking/onion.jpg`,
    ],
  });
  return a;
}

test('an update carries CanvasKit, fonts and learned assets forward, so it opens offline after taking over', async () => {
  const caches = new FakeCacheStorage();
  await warmedBuildA(caches, ENGINE);
  const b = worker({
    version: NEXT_BUILD,
    active: { scriptURL: `${ORIGIN}/sw.js?v=${BUILD}` },
    network: defaultNetwork({ deploy: { ...deployOf(NEXT_BUILD), engine: NEXT_ENGINE, tag: 'B' } }),
    caches,
  });
  await b.install();
  const fetched = b.calls.map((call) => call.url);
  assert.ok(fetched.includes(`https://www.gstatic.com/flutter-canvaskit/${NEXT_ENGINE}/chromium/canvaskit.wasm`),
    'CanvasKit is fetched at the new engine revision');
  assert.ok(!fetched.some((url) => url.startsWith('https://fonts.gstatic.com/')), 'immutable fonts are copied, not re-fetched');
  await b.activate();
  assert.deepEqual(await caches.keys(), [`soussight-shell-${NEXT_BUILD}`], 'A is gone once B takes over');

  const offlineB = worker({ version: NEXT_BUILD, caches, network: offline });
  for (const url of [
    `https://www.gstatic.com/flutter-canvaskit/${NEXT_ENGINE}/chromium/canvaskit.js`,
    `https://www.gstatic.com/flutter-canvaskit/${NEXT_ENGINE}/chromium/canvaskit.wasm`,
    'https://fonts.gstatic.com/s/roboto/v32/regular.woff2',
    `${ORIGIN}/main.dart.js`,
  ]) {
    const response = await offlineB.fetch(request(url));
    assert.ok(response && response.ok, `offline ${url}`);
  }
  assert.equal(await text(await offlineB.fetch(request(`${ORIGIN}/assets/assets/reference-cooking/onion.jpg`))),
    'network:B:assets/assets/reference-cooking/onion.jpg', 'learned same-origin assets come from the new deploy');
  assert.equal(await text(await offlineB.fetch(request(`${ORIGIN}/main.dart.js`))), 'network:B:main.dart.js');
  assert.equal(offlineB.calls.length, 0);
});

test('an update on the same engine copies CanvasKit without downloading it again', async () => {
  const caches = new FakeCacheStorage();
  await warmedBuildA(caches, ENGINE);
  const b = worker({ version: REBUILD, caches, active: {}, network: defaultNetwork({ deploy: deployOf(REBUILD) }) });
  await b.install();
  assert.ok(!b.calls.some((call) => call.url.includes('/flutter-canvaskit/')));
  assert.ok(b.caches.urls(`soussight-shell-${REBUILD}`).includes(`https://www.gstatic.com/flutter-canvaskit/${ENGINE}/chromium/canvaskit.wasm`));
});

test('an update that cannot get its CanvasKit fails, keeping the running build and its cache', async () => {
  const caches = new FakeCacheStorage();
  await warmedBuildA(caches, ENGINE);
  const b = worker({
    version: NEXT_BUILD,
    active: {},
    network: defaultNetwork({ deploy: { ...deployOf(NEXT_BUILD), engine: NEXT_ENGINE }, fail: ['/flutter-canvaskit/'] }),
    caches,
  });
  await assert.rejects(b.install(), /Failed to fetch/);
  assert.deepEqual(await caches.keys(), [`soussight-shell-${BUILD}`]);
  assert.ok(caches.urls(`soussight-shell-${BUILD}`).includes(`https://www.gstatic.com/flutter-canvaskit/${ENGINE}/chromium/canvaskit.wasm`));
});

test('carry-over never copies anything the routing rules would not cache', async () => {
  const caches = new FakeCacheStorage();
  const a = await caches.open(`soussight-shell-${BUILD}`);
  await a.put('https://firestore.googleapis.com/v1/doc', okResponse('api'));
  await a.put(`${ORIGIN}/api/live-session`, okResponse('api'));
  await a.put('https://www.gstatic.com/firebasejs/12.0.0/firebase-app.js', okResponse('old sdk'));
  const b = worker({ version: NEXT_BUILD, caches, active: {}, network: defaultNetwork({ deploy: deployOf(NEXT_BUILD) }) });
  await b.install();
  const cached = caches.urls(`soussight-shell-${NEXT_BUILD}`);
  assert.ok(!cached.some((url) => /googleapis|\/api\/|12\.0\.0/.test(url)));
  assert.ok(!b.calls.some((call) => /googleapis|\/api\//.test(call.url)));
});

test('the worker never calls skipWaiting', () => {
  assert.ok(!/skipWaiting\s*\(/.test(SW_SOURCE));
});

// ---------------------------------------------------------------- fetch

test('cache-first serves cached shell files with no network request', async () => {
  const caches = new FakeCacheStorage();
  const seeded = worker({ caches });
  await seeded.install();
  const w = worker({ caches, network: offline });
  const response = await w.fetch(request(`${ORIGIN}/main.dart.js`));
  assert.equal(await text(response), 'network:main.dart.js');
  assert.equal(w.calls.length, 0);
});

test('cache-first fills the cache from the network on a miss, but never stores errors', async () => {
  const w = worker({
    network: async (url) => (url.endsWith('missing.png') ? new Response('nope', { status: 404 }) : okResponse(`net:${url}`)),
  });
  const fontUrl = 'https://fonts.gstatic.com/s/roboto/v32/regular.woff2';
  assert.equal(await text(await w.fetch(request(fontUrl))), `net:${fontUrl}`);
  assert.ok(w.caches.urls(w.shell.cacheName).includes(fontUrl));
  const again = await w.fetch(request(fontUrl));
  assert.equal(await text(again), `net:${fontUrl}`);
  assert.equal(w.calls.length, 1, 'second read comes from the cache');

  const miss = await w.fetch(request(`${ORIGIN}/assets/missing.png`));
  assert.equal(miss.status, 404);
  assert.ok(!w.caches.urls(w.shell.cacheName).includes(`${ORIGIN}/assets/missing.png`));
});

test('API requests are left to the browser and nothing about them is cached', async () => {
  const w = worker();
  await w.install();
  const before = w.calls.length;
  for (const url of [
    'https://firebasevertexai.googleapis.com/v1beta/projects/p/locations/global/publishers/google/models/m:generateContent',
    'https://content-firebaseappcheck.googleapis.com/v1/projects/p/apps/a:exchangeRecaptchaEnterpriseToken',
    `${ORIGIN}/api/live-session`,
  ]) {
    assert.equal(await w.fetch(request(url)), null, url);
    assert.equal(await w.fetch(request(url, { method: 'POST' })), null, url);
  }
  assert.equal(w.calls.length, before, 'the worker made no request of its own');
  assert.ok(!w.caches.urls(w.shell.cacheName).some((url) => /googleapis|\/api\//.test(url)));
});

test('offline navigation to any app path opens the cached index.html', async () => {
  const caches = new FakeCacheStorage();
  await worker({ caches }).install();
  const w = worker({ caches, network: offline });
  for (const url of [`${ORIGIN}/`, `${ORIGIN}/cook/session-1`, `${ORIGIN}/?from=homescreen`]) {
    assert.equal(await text(await w.fetch(request(url, { mode: 'navigate' }))), 'network:index.html', url);
  }
});

test('online navigation returns the network page and leaves the cached build untouched', async () => {
  const caches = new FakeCacheStorage();
  await worker({ caches }).install();
  const w = worker({ caches, network: async () => okResponse('fresh index') });
  assert.equal(await text(await w.fetch(request(`${ORIGIN}/`, { mode: 'navigate' }))), 'fresh index');
  const cached = await (await caches.open(`soussight-shell-${BUILD}`)).match(`${ORIGIN}/index.html`);
  assert.equal(await cached.text(), 'network:index.html');
});

test('a navigation that hangs falls back to the cached shell after the timeout', async () => {
  const caches = new FakeCacheStorage();
  await worker({ caches }).install();
  const delays = [];
  const w = worker({
    caches,
    network: () => new Promise(() => {}),
    setTimeoutImpl: (fn, ms) => {
      delays.push(ms);
      return setTimeout(fn, 0);
    },
  });
  assert.equal(await text(await w.fetch(request(`${ORIGIN}/`, { mode: 'navigate' }))), 'network:index.html');
  assert.deepEqual(delays, [4000]);
});

test('with no cached shell, navigation simply waits for the network', async () => {
  const w = worker({ network: async () => okResponse('first visit') });
  assert.equal(await text(await w.fetch(request(`${ORIGIN}/`, { mode: 'navigate' }))), 'first visit');
});

test('version.json is network-first, falls back offline, and is never overwritten at runtime', async () => {
  const caches = new FakeCacheStorage();
  await worker({ caches }).install();
  const timers = [];
  const online = worker({
    caches,
    network: defaultNetwork({ deploy: deployOf(NEXT_BUILD) }),
    setTimeoutImpl: (fn, ms) => {
      timers.push(ms);
      return setTimeout(fn, ms);
    },
  });
  const fresh = JSON.parse(await text(await online.fetch(request(`${ORIGIN}/version.json`))));
  assert.equal(fresh.commit, NEXT_COMMIT);
  assert.deepEqual(timers, [], 'plain fetches of version.json do not race a timer');

  const off = worker({ caches, network: offline });
  const cached = JSON.parse(await text(await off.fetch(request(`${ORIGIN}/version.json`))));
  assert.equal(cached.commit, COMMIT, 'the cached copy still names the installed build');
});

// ---------------------------------------------------------------- warm-up

test('warm-up caches what the page loaded, and refuses API, query and unknown-host URLs', async () => {
  const w = worker();
  await w.install();
  const before = w.calls.length;
  const allowed = [
    `https://www.gstatic.com/flutter-canvaskit/${ENGINE}/chromium/canvaskit.js`,
    `https://www.gstatic.com/flutter-canvaskit/${ENGINE}/chromium/canvaskit.wasm`,
    'https://fonts.gstatic.com/s/roboto/v32/regular.woff2',
    `${ORIGIN}/assets/assets/reference-cooking/onion.jpg`,
  ];
  const refused = [
    'https://firestore.googleapis.com/google.firestore.v1.Firestore/Listen/channel?gsessionid=synthetic',
    'https://content-firebaseappcheck.googleapis.com/v1/projects/p/apps/a:exchangeDebugToken',
    `${ORIGIN}/api/live-session`,
    `${ORIGIN}/main.dart.js?appcheck=synthetic`,
    'https://www.google.com/recaptcha/enterprise/anchor',
    'not a url',
    42,
  ];
  await w.message({ type: 'soussight-warm', urls: [...allowed, ...refused, `${ORIGIN}/main.dart.js`] });
  const fetched = w.calls.slice(before).map((call) => call.url);
  assert.deepEqual(fetched.sort(), [...allowed].sort(), 'already-cached and refused URLs are not fetched');
  const cached = w.caches.urls(w.shell.cacheName);
  for (const url of allowed) assert.ok(cached.includes(url), url);
  assert.ok(!cached.some((url) => /googleapis|\/api\/|\?|recaptcha/.test(url)));
});

test('warm-up ignores unrelated messages and is capped', async () => {
  const w = worker({ network: async (url) => okResponse(url) });
  await w.message({ type: 'other', urls: [`${ORIGIN}/a.js`] });
  await w.message(null);
  assert.equal(w.calls.length, 0);
  const many = Array.from({ length: 400 }, (_, i) => `${ORIGIN}/assets/f${i}.png`);
  await w.message({ type: 'soussight-warm', urls: many });
  assert.equal(w.calls.length, 300);
});

// ---------------------------------------------------------------- pins and bundle hygiene

function installedPackageRoot(name) {
  const configPath = path.join(ROOT, '.dart_tool/package_config.json');
  if (!fs.existsSync(configPath)) return null;
  const config = JSON.parse(fs.readFileSync(configPath, 'utf8'));
  const entry = config.packages.find((p) => p.name === name);
  if (!entry) return null;
  const uri = new URL(entry.rootUri, `file://${path.join(ROOT, '.dart_tool')}/`);
  return uri.pathname;
}

test('the pinned Firebase JS SDK version matches FlutterFire firebase_core_web', (t) => {
  const root = installedPackageRoot('firebase_core_web');
  if (!root) return t.skip('run flutter pub get first');
  const source = fs.readFileSync(path.join(root, 'lib/src/firebase_sdk_version.dart'), 'utf8');
  const pinned = /supportedFirebaseJsSdkVersion\s*=\s*'([^']+)'/.exec(source)[1];
  assert.equal(worker().shell.FIREBASE_JS_SDK_VERSION, pinned);
});

test('every Firebase JS module the app loads is pre-cached', (t) => {
  const config = path.join(ROOT, '.dart_tool/package_config.json');
  if (!fs.existsSync(config)) return t.skip('run flutter pub get first');
  const packages = JSON.parse(fs.readFileSync(config, 'utf8')).packages
    .map((p) => p.name)
    .filter((name) => /^(firebase|cloud)_.*_web$/.test(name) && name !== 'firebase_core_web');
  const expected = new Set(['firebase-app.js']);
  for (const name of packages) {
    const libDir = path.join(installedPackageRoot(name), 'lib');
    const sources = fs.readdirSync(libDir).filter((f) => f.endsWith('.dart')).map((f) => fs.readFileSync(path.join(libDir, f), 'utf8'));
    for (const source of sources) {
      for (const match of source.matchAll(/registerService\(\s*'([a-z-]+)'/g)) {
        expected.add(match[1] === 'firestore' ? 'firebase-firestore-pipelines.js' : `firebase-${match[1]}.js`);
      }
    }
  }
  const bridge = fs.readFileSync(path.join(ROOT, 'packages/ai_logic_hybrid/assets/ai_logic_hybrid.js'), 'utf8');
  for (const match of bridge.matchAll(/firebasejs\/\$\{version\}\/(firebase-[a-z-]+\.js)/g)) expected.add(match[1]);
  assert.deepEqual([...worker().shell.FIREBASE_SDK_MODULES].sort(), [...expected].sort());
});

test('the worker and bootstrap carry nothing tool/check_web_bundle.sh rejects', () => {
  const uuid = /["'`][0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}["'`]/;
  for (const [name, source] of [['sw.js', SW_SOURCE], ['flutter_bootstrap.js', BOOTSTRAP_SOURCE]]) {
    assert.ok(!uuid.test(source), name);
    assert.ok(!source.includes('FIREBASE_APPCHECK_DEBUG_TOKEN'), name);
    assert.ok(!source.includes(GEMINI_DEV_HOST), name);
    assert.ok(!source.includes('BidiGenerateContentConstrained'), name);
  }
});

// ---------------------------------------------------------------- bootstrap

function bootstrap({
  versionJson,
  localBuild = `"${N}" /* deprecated */`,
  deployedNumber = N,
  fetchImpl,
  resources = [],
  controller = null,
  existing = null,
} = {}) {
  const listeners = new Map();
  const timers = [];
  const registered = [];
  const posted = [];
  const loads = [];
  const fetched = [];
  const active = { postMessage: (message) => posted.push(message) };
  const source = BOOTSTRAP_SOURCE
    .replace('{{flutter_js}}', 'window._flutter = { loader: { load: (...args) => loads.push(args) } };')
    .replace('{{flutter_build_config}}', '_flutter.buildConfig = {"engineRevision":"x","builds":[]};')
    .replace('{{flutter_service_worker_version}}', localBuild);
  assert.ok(!source.includes('{{'), 'every template placeholder is a Flutter built-in');
  const window = {
    isSecureContext: true,
    addEventListener(type, listener) {
      listeners.set(type, listener);
    },
  };
  const sandbox = {
    window,
    location: { origin: ORIGIN },
    URL,
    Set,
    Array,
    loads,
    navigator: {
      serviceWorker: {
        controller,
        register: async (url, options) => {
          registered.push({ url, options });
          return {};
        },
        ready: Promise.resolve({ active }),
        getRegistration: async () => existing ?? undefined,
      },
    },
    performance: {
      setResourceTimingBufferSize() {},
      getEntriesByType: (type) => (type === 'resource' ? resources.map((name) => ({ name })) : []),
    },
    fetch: async (url, init) => {
      fetched.push({ url, init });
      if (fetchImpl) return fetchImpl(url, init);
      if (url.startsWith('flutter_bootstrap.js?')) return okResponse(bootstrapText({ n: deployedNumber, engine: ENGINE }));
      return okResponse(JSON.stringify(versionJson ?? { version: '1.0.0', commit: COMMIT }), 'application/json');
    },
    setTimeout: (fn, ms) => timers.push({ fn, ms }),
  };
  sandbox.window._flutter = undefined;
  vm.createContext(sandbox);
  // `window` and the global are the same object in a page.
  vm.runInContext('var _flutter; Object.defineProperty(window, "_flutter", { get() { return _flutter; }, set(v) { _flutter = v; } });', sandbox);
  vm.runInContext(source, sandbox, { filename: 'web/flutter_bootstrap.js' });
  const flush = () => new Promise((resolve) => setImmediate(resolve));
  return {
    loads,
    registered,
    posted,
    fetched,
    timers,
    async firstFrame() {
      listeners.get('flutter-first-frame')?.();
      for (let i = 0; i < 10; i += 1) await flush();
    },
  };
}

test('the bootstrap loads Flutter without serviceWorkerSettings, so Flutter never registers its cleanup worker', async () => {
  const page = bootstrap();
  assert.equal(page.loads.length, 1);
  assert.equal(page.loads[0].length, 0, '_flutter.loader.load() takes no service worker settings');
  assert.ok(!/serviceWorkerSettings\s*:/.test(BOOTSTRAP_SOURCE.replace(/\/\/.*$/gm, '')));
  await page.firstFrame();
  assert.ok(page.registered.every((r) => !r.url.includes('flutter_service_worker')));
});

test('the worker is registered after the first frame, versioned by the deployed commit and build number', async () => {
  const page = bootstrap();
  assert.equal(page.registered.length, 0, 'nothing registers before the first frame');
  assert.equal(page.fetched.length, 0);
  await page.firstFrame();
  assert.deepEqual(page.registered.map((r) => r.url), [`sw.js?v=${BUILD}`]);
  assert.equal(page.registered[0].options.updateViaCache, 'none');
  assert.deepEqual(page.fetched.map((f) => f.url).sort(), ['flutter_bootstrap.js?soussight-build-probe=1', 'version.json']);
  assert.ok(page.fetched.every((f) => f.init.cache === 'no-store'));
  assert.equal(worker().shell.routeFor(request(`${ORIGIN}/flutter_bootstrap.js?soussight-build-probe=1`)), 'passthrough');
});

test('a page running an older cached build registers the DEPLOYED build, including a rebuild of the same commit', async () => {
  // Codex #249 finding 2: same commit, new artifact.
  const page = bootstrap({ localBuild: `"${N}"`, deployedNumber: NEXT_N });
  await page.firstFrame();
  assert.deepEqual(page.registered.map((r) => r.url), [`sw.js?v=${REBUILD}`]);
});

test('a local build without a commit registers a local-<n> worker; a fresh page registers none without either', async () => {
  const local = bootstrap({ versionJson: { version: '1.0.0' } });
  await local.firstFrame();
  assert.deepEqual(local.registered.map((r) => r.url), [`sw.js?v=local-${N}`]);

  const none = bootstrap({ versionJson: { version: '1.0.0' }, localBuild: 'null /* deprecated */', deployedNumber: null });
  await none.firstFrame();
  assert.deepEqual(none.registered, []);

  const bogus = bootstrap({ versionJson: { commit: 'not-a-sha' }, localBuild: 'null', deployedNumber: null });
  await bogus.firstFrame();
  assert.deepEqual(bogus.registered, []);
});

test('an unversionable deploy retires an existing worker instead of leaving an old build cached', async () => {
  const page = bootstrap({ versionJson: { version: '1.0.0' }, localBuild: 'null', deployedNumber: null, existing: { scope: SCOPE } });
  await page.firstFrame();
  assert.deepEqual(page.registered.map((r) => r.url), ['sw.js?v=off']);
  assert.equal(page.posted.length, 0, 'nothing to warm for an inert worker');
  const inert = worker({ version: 'off' });
  assert.equal(inert.shell.enabled, false);
});

test('registration is skipped quietly when version.json cannot be fetched, keeping the current worker', async () => {
  for (const fetchImpl of [offline, async () => new Response('', { status: 503 })]) {
    const page = bootstrap({ fetchImpl, existing: { scope: SCOPE } });
    await page.firstFrame();
    assert.deepEqual(page.registered, []);
  }
});

test('the bootstrap falls back to registering after 30 s if no frame is reported', () => {
  const page = bootstrap();
  assert.ok(page.timers.some((t) => t.ms === 30000));
});

test('the warm-up message carries only static resource URLs, never API or query URLs', async () => {
  const page = bootstrap({
    resources: [
      `${ORIGIN}/main.dart.js`,
      `https://www.gstatic.com/flutter-canvaskit/${ENGINE}/chromium/canvaskit.wasm`,
      'https://fonts.gstatic.com/s/roboto/v32/regular.woff2',
      'https://firestore.googleapis.com/google.firestore.v1.Firestore/Listen/channel?gsessionid=synthetic',
      'https://content-firebaseappcheck.googleapis.com/v1/projects/p/apps/a:exchangeDebugToken',
      `${ORIGIN}/api/live-session`,
      `${ORIGIN}/__/firebase/init.json`,
      `${ORIGIN}/assets/a.png?token=synthetic`,
      'http://www.gstatic.com/insecure.js',
      'https://cdn.example.com/x.js',
    ],
  });
  await page.firstFrame();
  assert.equal(page.posted.length, 1);
  assert.equal(page.posted[0].type, 'soussight-warm');
  assert.deepEqual(page.posted[0].urls, [
    `${ORIGIN}/main.dart.js`,
    `https://www.gstatic.com/flutter-canvaskit/${ENGINE}/chromium/canvaskit.wasm`,
    'https://fonts.gstatic.com/s/roboto/v32/regular.woff2',
  ]);
  assert.ok(page.timers.some((t) => t.ms === 10000), 'a second warm-up follows late font loads');
});

// ---------------------------------------------------------------- manifest and hosting

test('the manifest is installable: name, scope, colours and maskable icons that exist', () => {
  const manifest = JSON.parse(fs.readFileSync(path.join(ROOT, 'web/manifest.json'), 'utf8'));
  assert.equal(manifest.short_name, 'SousSight');
  assert.match(manifest.name, /^SousSight/);
  assert.equal(manifest.display, 'standalone');
  for (const key of ['id', 'start_url', 'scope']) assert.equal(manifest[key], './', key);
  const index = fs.readFileSync(path.join(ROOT, 'web/index.html'), 'utf8');
  assert.ok(index.includes(`<meta name="theme-color" content="${manifest.theme_color}">`));
  assert.ok(index.includes(`background: ${manifest.background_color}`));
  for (const size of ['192x192', '512x512']) {
    for (const purpose of [undefined, 'maskable']) {
      const icon = manifest.icons.find((i) => i.sizes === size && i.purpose === purpose);
      assert.ok(icon, `${size} ${purpose ?? 'any'} icon`);
      assert.ok(fs.existsSync(path.join(ROOT, 'web', icon.src)), icon.src);
    }
  }
});

test('Hosting serves sw.js no-cache and the worker never caches what Hosting rewrites to Functions', () => {
  const hosting = JSON.parse(fs.readFileSync(path.join(ROOT, 'firebase.json'), 'utf8')).hosting;
  const rule = hosting.headers.find((h) => h.source === '/sw.js');
  assert.ok(rule, '/sw.js header rule');
  assert.deepEqual(rule.headers, [{ key: 'Cache-Control', value: 'no-cache' }]);
  const { shell } = worker();
  for (const rewrite of hosting.rewrites.filter((r) => r.function)) {
    assert.equal(shell.routeFor(request(`${ORIGIN}${rewrite.source}`)), 'passthrough', rewrite.source);
    assert.equal(shell.routeFor(request(`${ORIGIN}${rewrite.source}`, { mode: 'navigate' })), 'passthrough', rewrite.source);
  }
});
