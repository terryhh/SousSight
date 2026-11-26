{{flutter_js}}
{{flutter_build_config}}

// SS-110 (#241): SousSight's own app-shell worker, web/sw.js.
//
// Flutter 3.47's flutter_service_worker.js is a cleanup worker that
// unregisters every worker at this scope and reloads the page, and the
// default bootstrap registers it whenever ANY worker is already registered.
// So this bootstrap calls _flutter.loader.load() with no serviceWorkerSettings
// (test/web/sw_test.cjs checks this), and registers sw.js itself once the
// first frame has painted, so the first visit's downloads are not slowed.
(function () {
  'use strict';

  const COMMIT = /^[0-9a-f]{40}([0-9a-f]{24})?$/;
  // A random number Flutter writes here per build (null with
  // --pwa-strategy=none and under flutter run). It identifies this exact
  // artifact: rebuilding the same commit with other settings changes it.
  // The page and sw.js read it from the DEPLOYED copy of this file, never
  // from the copy this page is running, which may be an older cached build.
  const localBuild = {{flutter_service_worker_version}};
  const BUILD_NUMBER = /const localBuild = "([0-9]{1,12})"/;
  const WARM_HOSTS = ['www.gstatic.com', 'fonts.gstatic.com'];

  try {
    performance.setResourceTimingBufferSize(1000);
  } catch (_) {}

  // The deployed build: `<commit>-<n>` (`local-<n>` when version.json has
  // no stamped commit), '' when the server answered but names no usable
  // build, or null when it was unreachable.
  async function shellBuildId() {
    let version;
    let bootstrap;
    try {
      const init = { cache: 'no-store', credentials: 'same-origin' };
      const [versionResponse, bootstrapResponse] = await Promise.all([
        fetch('version.json', init),
        // The query makes sw.js pass this through to the network.
        fetch('flutter_bootstrap.js?soussight-build-probe=1', init),
      ]);
      if (!versionResponse.ok || !bootstrapResponse.ok) return null;
      version = await versionResponse.json();
      bootstrap = await bootstrapResponse.text();
    } catch (_) {
      return null;
    }
    const number = BUILD_NUMBER.exec(bootstrap);
    if (!number) return '';
    const commit = version && typeof version.commit === 'string' && COMMIT.test(version.commit) ? version.commit : 'local';
    return commit + '-' + number[1];
  }

  // Resources this page loaded before the worker controlled it. Only
  // query-free URLs on this origin (outside /api/ and /__/) or the two static
  // Google hosts are sent; API calls, and any token that might ride in their
  // URLs, never leave this function.
  function warmUrls() {
    const urls = new Set();
    for (const entry of performance.getEntriesByType('resource')) {
      let url;
      try {
        url = new URL(entry.name);
      } catch (_) {
        continue;
      }
      if (url.search !== '' || url.hash !== '') continue;
      if (url.origin === location.origin) {
        if (url.pathname.startsWith('/api/') || url.pathname.startsWith('/__/')) continue;
      } else if (url.protocol !== 'https:' || !WARM_HOSTS.includes(url.hostname)) {
        continue;
      }
      urls.add(url.href);
    }
    return Array.from(urls);
  }

  async function warm() {
    const registration = await navigator.serviceWorker.ready;
    if (registration.active) {
      registration.active.postMessage({ type: 'soussight-warm', urls: warmUrls() });
    }
  }

  async function registerShellWorker() {
    if (!('serviceWorker' in navigator) || !window.isSecureContext) return;
    try {
      const build = await shellBuildId();
      if (build === null) return;
      if (build === '') {
        // A deploy this page cannot version (no per-build number, e.g.
        // --pwa-strategy=none). Rather than leave an older worker serving an older
        // cached build, replace it with the inert worker, which clears the
        // shell caches when it activates at the next launch.
        if (await navigator.serviceWorker.getRegistration()) {
          await navigator.serviceWorker.register('sw.js?v=off', { updateViaCache: 'none' });
        }
        return;
      }
      await navigator.serviceWorker.register('sw.js?v=' + encodeURIComponent(build), {
        updateViaCache: 'none',
      });
      await warm();
      // Fonts and images requested just after the first frame.
      setTimeout(() => warm().catch(() => {}), 10000);
    } catch (_) {
      // Offline or blocked: the app still runs; the next launch tries again.
    }
  }

  let started = false;
  function start() {
    if (started) return;
    started = true;
    registerShellWorker();
  }
  window.addEventListener('flutter-first-frame', start, { once: true });
  setTimeout(start, 30000);
})();

_flutter.loader.load();
