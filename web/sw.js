// SousSight app-shell service worker (SS-110, card #241).
//
// Goal: once the hosted app has been opened, it opens again with no
// connection, so a cook can keep using Chrome's on-device model offline.
//
// Registered by web/flutter_bootstrap.js as `sw.js?v=<build>`. <build> is
// `<commit>-<n>`: the full commit CI stamps into version.json, and the random
// number Flutter writes into each build's flutter_bootstrap.js, so rebuilding
// the same commit with other settings is still a new build. An unstamped
// local build is `local-<n>`. A different <build> is a different worker
// script, which is how the browser notices an update. Both the page and this
// worker read <build> from the DEPLOYED files (version.json, and
// flutter_bootstrap.js fetched with a query so no worker answers it).
//
// Install (precache) never mixes builds: it checks the deployed <build>
// before and after downloading, and that the bootstrap it cached carries <n>;
// any mismatch discards the new cache and the previous worker stays. It also
// carries over what the previous build's cache learned from the page:
// immutable pinned files (SDK, fonts) are copied; CanvasKit is copied, or
// fetched at this build's engine revision (required, so an update can never
// leave the app without its renderer); other same-origin files are re-fetched
// from this deploy.
//
// Routing (routeFor):
//   * passthrough (never intercepted, never cached): anything that is not a
//     plain GET; Range requests; requests carrying Authorization or App Check
//     headers; *.googleapis.com (Firebase AI, App Check, Firestore, Auth,
//     Installations, ...); Cloud Functions hosts; same-origin /api/** (Hosting
//     rewrites to Functions) and /__/** (Firebase Hosting reserved URLs, the
//     auth handler); sw.js itself and Flutter's flutter_service_worker.js;
//     any URL with a query string; every cross-origin host not listed below.
//   * navigate: page navigations. Network first (with a short timeout when a
//     cached shell exists), falling back to the cached index.html, because
//     Hosting rewrites every path to index.html.
//   * network-first: index.html and version.json. The network copy is
//     returned but never written to the cache, so the cache always holds one
//     consistent build.
//   * cache-first: every other same-origin GET (the Flutter build output,
//     assets, local canvaskit, soussight_live.js, icons), the Firebase JS SDK
//     at the exact version FlutterFire pins, CanvasKit from the engine
//     revision path on www.gstatic.com, and font files from fonts.gstatic.com.
//
// Updates take over at the next launch, never mid-session: a new worker
// installs into its own cache and waits (no skipWaiting) until every tab of
// the old version has closed. Only the very first install claims the open
// page, since there is no older build for it to mix with.
//
// This worker never logs URLs, headers or tokens.
'use strict';

const CACHE_PREFIX = 'soussight-shell-';

// FlutterFire's firebase_core_web 4.1.0 `supportedFirebaseJsSdkVersion`
// (DESIGN.md §3). test/web/sw_test.cjs fails if the installed package moves.
const FIREBASE_JS_SDK_VERSION = '13.1.0';
const FIREBASE_SDK_BASE = `https://www.gstatic.com/firebasejs/${FIREBASE_JS_SDK_VERSION}/`;
// The modules the app loads: one per registered FlutterFire web plugin
// (firestore loads its pipelines bundle) plus firebase-ai.js, which the
// ai_logic_hybrid web bridge imports.
const FIREBASE_SDK_MODULES = [
  'firebase-app.js',
  'firebase-app-check.js',
  'firebase-auth.js',
  'firebase-firestore-pipelines.js',
  'firebase-remote-config.js',
  'firebase-analytics.js',
  'firebase-ai.js',
];

// Install fails (and the previous worker, if any, stays) without these.
const SHELL_REQUIRED = ['index.html', 'flutter_bootstrap.js', 'main.dart.js'];
// Cached when present; a missing one does not fail the install.
const SHELL_OPTIONAL = [
  'flutter.js',
  'version.json',
  'manifest.json',
  'favicon.png',
  'icons/Icon-192.png',
  'icons/Icon-512.png',
  'icons/Icon-maskable-192.png',
  'icons/Icon-maskable-512.png',
  'soussight_live.js',
  'assets/AssetManifest.bin',
  'assets/AssetManifest.bin.json',
  'assets/FontManifest.json',
  'assets/packages/ai_logic_hybrid/assets/ai_logic_hybrid.js',
];

const NAVIGATION_TIMEOUT_MS = 4000;
const MAX_WARM_URLS = 300;

const COMMIT_PATTERN = /^[0-9a-f]{40}([0-9a-f]{24})?$/;
const BUILD_ID_PATTERN = /^(?:[0-9a-f]{40}(?:[0-9a-f]{24})?|local)-([0-9]{1,12})$/;
// Written by Flutter into web/flutter_bootstrap.js at build time.
const BUILD_NUMBER_IN_BOOTSTRAP = /const localBuild = "([0-9]{1,12})"/;
const ENGINE_REVISION_IN_BOOTSTRAP = /"engineRevision":"([0-9a-f]{40})"/;
const CANVASKIT_PATH = /^\/flutter-canvaskit\/([0-9a-f]{40})\/(.+)$/;
// A query makes this worker pass the request through to the network.
const BUILD_PROBE = 'flutter_bootstrap.js?soussight-build-probe=1';

const buildId = new URL(self.location.href).searchParams.get('v') || '';
const buildMatch = BUILD_ID_PATTERN.exec(buildId);
// An unrecognised version (including none) makes this worker inert: it
// intercepts nothing and clears SousSight caches, so `sw.js?v=off` is a
// kill switch.
const enabled = Boolean(buildMatch);
const buildNumber = buildMatch ? buildMatch[1] : '';
const cacheName = enabled ? CACHE_PREFIX + buildId : '';

function scopeUrl() {
  return new URL(self.registration.scope);
}

/** Path of [url] relative to the registration scope, or null if outside it. */
function scopedPath(url) {
  const scope = scopeUrl();
  if (url.origin !== scope.origin || !url.pathname.startsWith(scope.pathname)) {
    return null;
  }
  return url.pathname.slice(scope.pathname.length);
}

function isApiHost(hostname) {
  return (
    hostname === 'googleapis.com' ||
    hostname.endsWith('.googleapis.com') ||
    hostname.endsWith('.cloudfunctions.net') ||
    hostname.endsWith('.run.app')
  );
}

function hasCredentialHeader(headers) {
  if (!headers || typeof headers.has !== 'function') return false;
  return (
    headers.has('authorization') ||
    headers.has('x-firebase-appcheck') ||
    headers.has('x-goog-api-key')
  );
}

/**
 * How to answer [request]: 'passthrough', 'navigate', 'network-first' or
 * 'cache-first'. Pure apart from reading the registration scope.
 */
function routeFor(request) {
  if (!enabled) return 'passthrough';
  if (!request || request.method !== 'GET') return 'passthrough';
  let url;
  try {
    url = new URL(request.url);
  } catch (_) {
    return 'passthrough';
  }
  if (url.protocol !== 'https:' && url.protocol !== 'http:') return 'passthrough';
  if (hasCredentialHeader(request.headers)) return 'passthrough';
  if (request.headers && typeof request.headers.has === 'function' && request.headers.has('range')) {
    return 'passthrough';
  }
  if (isApiHost(url.hostname)) return 'passthrough';

  const scope = scopeUrl();
  if (url.origin === scope.origin) {
    const path = scopedPath(url);
    if (path === null) return 'passthrough';
    if (path.startsWith('api/') || path === 'api' || path.startsWith('__/')) return 'passthrough';
    if (path === 'sw.js' || path === 'flutter_service_worker.js') return 'passthrough';
    if (request.mode === 'navigate') return 'navigate';
    if (path === '' || path === 'index.html' || path === 'version.json') return 'network-first';
    if (url.search !== '') return 'passthrough';
    return 'cache-first';
  }

  if (url.search !== '' || url.protocol !== 'https:') return 'passthrough';
  if (url.hostname === 'www.gstatic.com') {
    if (url.href.startsWith(FIREBASE_SDK_BASE) && url.pathname.endsWith('.js')) return 'cache-first';
    if (CANVASKIT_PATH.test(url.pathname)) return 'cache-first';
    return 'passthrough';
  }
  if (url.hostname === 'fonts.gstatic.com' && url.pathname.startsWith('/s/')) return 'cache-first';
  return 'passthrough';
}

function isStorable(response) {
  return Boolean(response) && response.ok && (response.type === 'basic' || response.type === 'cors' || response.type === 'default');
}

function shellUrl(path) {
  return new URL(path, self.registration.scope).href;
}

function sdkUrls() {
  return FIREBASE_SDK_MODULES.map((name) => FIREBASE_SDK_BASE + name);
}

async function fetchForCache(url) {
  const sameOrigin = new URL(url).origin === scopeUrl().origin;
  // Same-origin shell files are served no-cache; revalidate so the cache
  // gets this deploy's bytes. Pinned cross-origin URLs are immutable.
  return fetch(url, sameOrigin ? { cache: 'no-cache', credentials: 'same-origin' } : { mode: 'cors', credentials: 'omit' });
}

/** The build id a deployment's version.json and bootstrap describe, or ''. */
function identityOf(version, bootstrapText) {
  const number = BUILD_NUMBER_IN_BOOTSTRAP.exec(bootstrapText || '');
  if (!number) return '';
  const commit = version && typeof version.commit === 'string' && COMMIT_PATTERN.test(version.commit) ? version.commit : 'local';
  return `${commit}-${number[1]}`;
}

async function deployedIdentity() {
  const init = { cache: 'no-store', credentials: 'same-origin' };
  const [version, bootstrap] = await Promise.all([fetch(shellUrl('version.json'), init), fetch(shellUrl(BUILD_PROBE), init)]);
  if (!version.ok || !bootstrap.ok) throw new Error('deployment identity unavailable');
  return identityOf(await version.json(), await bootstrap.text());
}

async function requireDeployedBuild() {
  // A deploy landed before or during the downloads: cache nothing under the
  // wrong name. The next launch registers the matching worker.
  if ((await deployedIdentity()) !== buildId) throw new Error('build changed during install');
}

async function storeRequired(cache, url) {
  const response = await fetchForCache(url);
  if (!isStorable(response)) throw new Error('required shell file missing');
  await cache.put(url, response);
}

async function storeOptional(cache, url) {
  try {
    const response = await fetchForCache(url);
    if (isStorable(response)) await cache.put(url, response);
  } catch (_) {
    // Best effort: the page's warm-up message and runtime caching fill gaps.
  }
}

/**
 * Copies or re-fetches what earlier SousSight caches learned from the page,
 * so the update is as complete offline as the build it replaces.
 */
async function carryOver(cache, engineRevision) {
  const scope = scopeUrl();
  const names = (await caches.keys()).filter((name) => name.startsWith(CACHE_PREFIX) && name !== cacheName);
  for (const name of names) {
    const previous = await caches.open(name);
    for (const request of await previous.keys()) {
      let url;
      try {
        url = new URL(request.url);
      } catch (_) {
        continue;
      }
      if (routeFor({ method: 'GET', url: url.href, mode: 'cors', headers: new Headers() }) !== 'cache-first') continue;
      const canvasKit = url.hostname === 'www.gstatic.com' ? CANVASKIT_PATH.exec(url.pathname) : null;
      if (canvasKit) {
        if (!engineRevision) continue;
        const target = `https://www.gstatic.com/flutter-canvaskit/${engineRevision}/${canvasKit[2]}`;
        if (await cache.match(target)) continue;
        const copy = canvasKit[1] === engineRevision ? await previous.match(url.href) : null;
        if (copy) await cache.put(target, copy);
        else await storeRequired(cache, target);
      } else if (url.origin !== scope.origin) {
        // Pinned or content-addressed URLs: the bytes cannot have changed.
        if (await cache.match(url.href)) continue;
        const copy = await previous.match(url.href);
        if (copy) await cache.put(url.href, copy);
      } else if (!(await cache.match(url.href))) {
        await storeOptional(cache, url.href);
      }
    }
  }
}

async function precache() {
  await requireDeployedBuild();
  const cache = await caches.open(cacheName);
  try {
    for (const path of SHELL_REQUIRED) await storeRequired(cache, shellUrl(path));
    const bootstrap = await (await cache.match(shellUrl('flutter_bootstrap.js'))).text();
    const number = BUILD_NUMBER_IN_BOOTSTRAP.exec(bootstrap);
    if (!number || number[1] !== buildNumber) throw new Error('build changed during install');
    const engine = ENGINE_REVISION_IN_BOOTSTRAP.exec(bootstrap);
    await Promise.all([...SHELL_OPTIONAL.map(shellUrl), ...sdkUrls()].map((url) => storeOptional(cache, url)));
    await carryOver(cache, engine ? engine[1] : null);
    await requireDeployedBuild();
  } catch (error) {
    await caches.delete(cacheName);
    throw error;
  }
}

let firstInstall = false;

self.addEventListener('install', (event) => {
  if (!enabled) return;
  firstInstall = !self.registration.active;
  event.waitUntil(
    precache().catch((error) => {
      console.warn('SousSight shell cache: install skipped:', error && error.message);
      throw error;
    }),
  );
});

self.addEventListener('activate', (event) => {
  event.waitUntil(
    (async () => {
      const names = await caches.keys();
      await Promise.all(
        names
          .filter((name) => name.startsWith(CACHE_PREFIX) && name !== cacheName)
          .map((name) => caches.delete(name)),
      );
      if (enabled && firstInstall) await self.clients.claim();
    })(),
  );
});

async function cacheFirst(request) {
  const cache = await caches.open(cacheName);
  const cached = await cache.match(request.url);
  if (cached) return cached;
  const response = await fetch(request);
  if (isStorable(response)) {
    try {
      await cache.put(request.url, response.clone());
    } catch (_) {
      // Quota or a body already used: serve without caching.
    }
  }
  return response;
}

async function cachedShell(path) {
  const cache = await caches.open(cacheName);
  return cache.match(shellUrl(path));
}

async function networkFirst(request, fallbackPath, timeoutMs) {
  const network = fetch(request);
  const cached = await cachedShell(fallbackPath);
  if (!cached) return network;
  if (!Number.isFinite(timeoutMs)) {
    // setTimeout treats Infinity as 0, so wait on the network alone.
    try {
      return await network;
    } catch (_) {
      return cached;
    }
  }
  let timer;
  const timeout = new Promise((resolve) => {
    timer = setTimeout(() => resolve(null), timeoutMs);
  });
  try {
    const winner = await Promise.race([network, timeout]);
    return winner || cached;
  } catch (_) {
    return cached;
  } finally {
    clearTimeout(timer);
    network.catch(() => {});
  }
}

self.addEventListener('fetch', (event) => {
  const route = routeFor(event.request);
  if (route === 'passthrough') return;
  if (route === 'cache-first') {
    event.respondWith(cacheFirst(event.request));
  } else if (route === 'navigate') {
    event.respondWith(networkFirst(event.request, 'index.html', NAVIGATION_TIMEOUT_MS));
  } else {
    const path = scopedPath(new URL(event.request.url));
    // Plain fetches of version.json/index.html wait for the network as long
    // as it takes; only a failure falls back to the cached copy.
    event.respondWith(networkFirst(event.request, path === 'version.json' ? 'version.json' : 'index.html', Infinity));
  }
});

async function warm(urls) {
  const cache = await caches.open(cacheName);
  for (const raw of urls.slice(0, MAX_WARM_URLS)) {
    if (typeof raw !== 'string') continue;
    let url;
    try {
      url = new URL(raw);
    } catch (_) {
      continue;
    }
    url.hash = '';
    const probe = { method: 'GET', url: url.href, mode: 'cors', headers: new Headers() };
    if (routeFor(probe) !== 'cache-first') continue;
    if (await cache.match(url.href)) continue;
    try {
      const response = await fetchForCache(url.href);
      if (isStorable(response)) await cache.put(url.href, response);
    } catch (_) {
      // Offline or blocked: try again on a later launch.
    }
  }
}

// The page sends the resources it loaded before this worker controlled it
// (main.dart.js, the CanvasKit variant it picked, fonts, SDK modules) so the
// first visit is enough to open offline next time.
self.addEventListener('message', (event) => {
  const data = event.data;
  if (!enabled || !data || data.type !== 'soussight-warm' || !Array.isArray(data.urls)) return;
  event.waitUntil(warm(data.urls));
});

// Exposed for test/web/sw_test.cjs.
self.soussightShell = Object.freeze({
  routeFor,
  identityOf,
  buildId,
  cacheName,
  enabled,
  FIREBASE_JS_SDK_VERSION,
  FIREBASE_SDK_MODULES,
  SHELL_REQUIRED,
  SHELL_OPTIONAL,
});
