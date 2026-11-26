// SS-110 offline check in a real Chrome: load the built app, let the shell
// worker cache it, deploy a rebuild of the same commit (a new Flutter build
// number) and check it waits for the next launch and takes over with a
// complete cache, then cut the network, reload and reopen, and require
// Flutter's first frame each time. Opt-in because it needs a build and Chrome:
//
//   ./tool/build_web.sh --dart-define=FAKE_BACKEND=true
//   SOUSSIGHT_OFFLINE_CHECK_BUILD=build/web node --test test/web/offline_chrome_test.cjs
//
// Optional: CHROME_PATH (default: Google Chrome on macOS, else google-chrome),
// SOUSSIGHT_OFFLINE_CHECK_SCREENSHOT=<dir> to save before/after screenshots.
//
// "Offline" is real, not DevTools emulation: the local app server drops every
// connection, and Chrome's only route to other hosts (www.gstatic.com for
// CanvasKit and the Firebase SDK, fonts.gstatic.com) is a local proxy that
// starts refusing too. No dependencies beyond Node 22 (global WebSocket).
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const http = require('node:http');
const net = require('node:net');
const { spawn } = require('node:child_process');

const BUILD = process.env.SOUSSIGHT_OFFLINE_CHECK_BUILD;
const SHOTS = process.env.SOUSSIGHT_OFFLINE_CHECK_SCREENSHOT;

function chromePath() {
  if (process.env.CHROME_PATH) return process.env.CHROME_PATH;
  const mac = '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
  return fs.existsSync(mac) ? mac : 'google-chrome';
}

const TYPES = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript',
  '.mjs': 'text/javascript',
  '.json': 'application/json',
  '.wasm': 'application/wasm',
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.otf': 'font/otf',
  '.ttf': 'font/ttf',
  '.bin': 'application/octet-stream',
};

/** Static server shaped like firebase.json Hosting: SPA rewrite, /api/ to Functions. */
function appServer(root) {
  const sockets = new Set();
  // `buildNumber` simulates deploying a rebuild: the served bootstrap carries
  // a different Flutter build number, everything else is byte-identical.
  const state = { offline: false, buildNumber: null };
  const server = http.createServer((req, res) => {
    if (state.offline) return req.socket.destroy();
    const url = new URL(req.url, 'http://local');
    if (url.pathname.startsWith('/api/')) {
      res.writeHead(503).end();
      return;
    }
    let file = path.join(root, decodeURIComponent(url.pathname));
    if (!file.startsWith(path.resolve(root))) return res.writeHead(403).end();
    if (!fs.existsSync(file) || fs.statSync(file).isDirectory()) file = path.join(root, 'index.html');
    if (state.buildNumber && path.basename(file) === 'flutter_bootstrap.js') {
      const body = fs.readFileSync(file, 'utf8').replace(/const localBuild = "[0-9]+"/, `const localBuild = "${state.buildNumber}"`);
      res.writeHead(200, { 'content-type': 'text/javascript', 'cache-control': 'no-cache' });
      res.end(body);
      return;
    }
    res.writeHead(200, {
      'content-type': TYPES[path.extname(file)] ?? 'application/octet-stream',
      'cache-control': 'no-cache',
    });
    fs.createReadStream(file).pipe(res);
  });
  server.on('connection', (socket) => {
    sockets.add(socket);
    socket.on('close', () => sockets.delete(socket));
  });
  return {
    server,
    state,
    goOffline() {
      state.offline = true;
      for (const socket of sockets) socket.destroy();
    },
  };
}

/** HTTP(S) forward proxy for every non-loopback host, with an off switch. */
function proxyServer() {
  const sockets = new Set();
  const state = { offline: false, hosts: new Set() };
  const server = http.createServer((req, res) => {
    // Plain-HTTP proxying is not needed by the app; refuse it.
    res.writeHead(502).end();
  });
  server.on('connect', (req, client, head) => {
    const [host, port] = req.url.split(':');
    if (state.offline) return client.destroy();
    state.hosts.add(host);
    const upstream = net.connect(Number(port) || 443, host, () => {
      client.write('HTTP/1.1 200 Connection Established\r\n\r\n');
      upstream.write(head);
      upstream.pipe(client);
      client.pipe(upstream);
    });
    for (const s of [client, upstream]) {
      sockets.add(s);
      s.on('close', () => sockets.delete(s));
      s.on('error', () => s.destroy());
    }
  });
  return {
    server,
    state,
    goOffline() {
      state.offline = true;
      for (const socket of sockets) socket.destroy();
    },
  };
}

const listen = (server) =>
  new Promise((resolve) => server.listen(0, '127.0.0.1', () => resolve(server.address().port)));

async function waitFor(fn, { timeout = 60000, interval = 250, what }) {
  const deadline = Date.now() + timeout;
  let last;
  while (Date.now() < deadline) {
    last = await fn();
    if (last) return last;
    await new Promise((r) => setTimeout(r, interval));
  }
  throw new Error(`Timed out waiting for ${what} (last: ${JSON.stringify(last)})`);
}

/** Minimal Chrome DevTools Protocol client over one browser WebSocket. */
async function devtools(wsUrl) {
  const ws = new WebSocket(wsUrl);
  await new Promise((resolve, reject) => {
    ws.addEventListener('open', resolve, { once: true });
    ws.addEventListener('error', reject, { once: true });
  });
  let id = 0;
  const pending = new Map();
  ws.addEventListener('message', (event) => {
    const message = JSON.parse(event.data);
    if (message.id && pending.has(message.id)) {
      const { resolve, reject } = pending.get(message.id);
      pending.delete(message.id);
      if (message.error) reject(new Error(message.error.message));
      else resolve(message.result);
    }
  });
  const send = (method, params = {}, sessionId) =>
    new Promise((resolve, reject) => {
      id += 1;
      pending.set(id, { resolve, reject });
      ws.send(JSON.stringify({ id, method, params, ...(sessionId ? { sessionId } : {}) }));
    });
  return { send, close: () => ws.close() };
}

async function openPage(cdp, url) {
  const { targetId } = await cdp.send('Target.createTarget', { url: 'about:blank' });
  const { sessionId } = await cdp.send('Target.attachToTarget', { targetId, flatten: true });
  const page = {
    targetId,
    send: (method, params) => cdp.send(method, params, sessionId),
    async eval(expression) {
      const result = await page.send('Runtime.evaluate', { expression, awaitPromise: true, returnByValue: true });
      if (result.exceptionDetails) throw new Error(result.exceptionDetails.text);
      return result.result.value;
    },
  };
  await page.send('Page.enable');
  await page.send('Runtime.enable');
  // Record Flutter's own first-frame event; the loading screen's 20 s
  // fallback timer is not evidence that Flutter rendered.
  await page.send('Page.addScriptToEvaluateOnNewDocument', {
    source: "window.__ssFrames = 0; window.addEventListener('flutter-first-frame', () => { window.__ssFrames += 1; });",
  });
  await page.send('Page.navigate', { url });
  return page;
}

const firstFrame = (page, what) =>
  waitFor(() => page.eval('window.__ssFrames > 0 && !!document.querySelector("flutter-view, flt-glass-pane")'), {
    what,
  });

async function screenshot(page, name) {
  if (!SHOTS) return;
  fs.mkdirSync(SHOTS, { recursive: true });
  const { data } = await page.send('Page.captureScreenshot', { format: 'png' });
  fs.writeFileSync(path.join(SHOTS, `${name}.png`), Buffer.from(data, 'base64'));
}

test('the built app opens again with no network once it has been opened', { skip: !BUILD && 'set SOUSSIGHT_OFFLINE_CHECK_BUILD=build/web', timeout: 240000 }, async (t) => {
  const root = path.resolve(BUILD);
  assert.ok(fs.existsSync(path.join(root, 'main.dart.js')), `${root} has no main.dart.js; build first`);
  assert.ok(fs.existsSync(path.join(root, 'sw.js')), `${root} has no sw.js`);

  const app = appServer(root);
  const proxy = proxyServer();
  const appPort = await listen(app.server);
  const proxyPort = await listen(proxy.server);
  const origin = `http://127.0.0.1:${appPort}`;
  const profile = fs.mkdtempSync(path.join(os.tmpdir(), 'soussight-offline-'));
  const chrome = spawn(chromePath(), [
    '--headless=new',
    '--remote-debugging-port=0',
    `--user-data-dir=${profile}`,
    `--proxy-server=http://127.0.0.1:${proxyPort}`,
    '--no-first-run',
    '--no-default-browser-check',
    '--disable-background-networking',
    '--disable-component-update',
    '--window-size=1280,900',
    'about:blank',
  ], { stdio: 'ignore' });
  const exited = new Promise((resolve) => chrome.once('exit', resolve));
  t.after(async () => {
    chrome.kill('SIGKILL');
    await exited;
    app.server.closeAllConnections?.();
    app.server.close();
    proxy.server.close();
    fs.rmSync(profile, { recursive: true, force: true, maxRetries: 5, retryDelay: 200 });
  });

  const portFile = path.join(profile, 'DevToolsActivePort');
  const [debugPort, browserPath] = (await waitFor(() => fs.existsSync(portFile) && fs.readFileSync(portFile, 'utf8').trim(), {
    what: 'Chrome DevTools port',
    timeout: 30000,
  })).split('\n');
  const cdp = await devtools(`ws://127.0.0.1:${debugPort}${browserPath}`);
  t.after(() => cdp.close());

  // 1. First visit, online.
  const page = await openPage(cdp, `${origin}/`);
  await firstFrame(page, 'first frame online');
  const shell = await waitFor(
    () =>
      page.eval(`(async () => {
        if (!navigator.serviceWorker.controller) return null;
        const names = (await caches.keys()).filter((n) => n.startsWith('soussight-shell-'));
        if (names.length !== 1) return null;
        const keys = (await (await caches.open(names[0])).keys()).map((r) => r.url);
        const has = (re) => keys.some((u) => re.test(u));
        if (!has(/\\/main\\.dart\\.js$/) || !has(/canvaskit\\.wasm$/)) return null;
        return {
          cache: names[0],
          worker: navigator.serviceWorker.controller.scriptURL.replace(location.origin, ''),
          entries: keys.length,
          canvasKit: keys.filter((u) => /canvaskit\\.(js|wasm)$/.test(u)).map((u) => u.replace(location.origin, '')),
          firebaseSdk: keys.filter((u) => u.includes('/firebasejs/')).length,
          apiEntries: keys.filter((u) => /googleapis\\.com|\\/api\\/|\\/__\\//.test(u)),
        };
      })()`),
    { what: 'the shell cache to hold main.dart.js and CanvasKit', timeout: 90000, interval: 500 },
  );
  t.diagnostic(`online: ${JSON.stringify(shell)}; proxied hosts: ${[...proxy.state.hosts].join(', ')}`);
  assert.match(shell.cache, /^soussight-shell-(local|[0-9a-f]{40})-\d+$/);
  assert.match(shell.worker, /^\/sw\.js\?v=/);
  assert.deepEqual(shell.apiEntries, [], 'no API response is cached');
  await screenshot(page, 'online');

  // 1b. Deploy a rebuild of the same commit. The open page still runs build A
  // from the cache; it must register B, and B must wait (no mid-session swap).
  const oldBuild = shell.worker.split('v=')[1];
  const newNumber = String((Number(oldBuild.split('-').pop()) + 1) % 4294967296);
  app.state.buildNumber = newNumber;
  await page.send('Page.reload', { ignoreCache: false });
  await firstFrame(page, 'first frame after the rebuild was deployed');
  const waiting = await waitFor(
    () =>
      page.eval(`(async () => {
        const registration = await navigator.serviceWorker.getRegistration();
        const next = registration && registration.waiting;
        if (!next) return null;
        const names = (await caches.keys()).filter((n) => n.startsWith('soussight-shell-'));
        return {
          waiting: next.scriptURL.replace(location.origin, ''),
          controller: navigator.serviceWorker.controller.scriptURL.replace(location.origin, ''),
          caches: names,
        };
      })()`),
    { what: 'the rebuilt worker to install and wait', timeout: 90000, interval: 500 },
  );
  t.diagnostic(`update waiting: ${JSON.stringify(waiting)}`);
  assert.match(waiting.waiting, new RegExp(`-${newNumber}$`), 'the page registered the deployed rebuild');
  assert.equal(waiting.controller, shell.worker, 'the running build keeps control mid-session');
  assert.equal(waiting.caches.length, 2);

  // 1c. Next launch: close the only tab, then open the app again (online).
  // The waiting worker activates only once no tab uses the old one, so leave
  // a gap as a real relaunch does; retry if Chrome had not let go yet.
  let updated = page;
  const takeoverProbe = `(async () => {
        const controller = navigator.serviceWorker.controller;
        if (!controller || !controller.scriptURL.endsWith('-${newNumber}')) return null;
        const names = (await caches.keys()).filter((n) => n.startsWith('soussight-shell-'));
        if (names.length !== 1) return null;
        const keys = (await (await caches.open(names[0])).keys()).map((r) => r.url);
        return {
          worker: controller.scriptURL.replace(location.origin, ''),
          cache: names[0],
          canvasKit: keys.filter((u) => /canvaskit\\.wasm$/.test(u)).length,
          fonts: keys.filter((u) => u.startsWith('https://fonts.gstatic.com/')).length,
          firebaseSdk: keys.filter((u) => u.includes('/firebasejs/')).length,
          entries: keys.length,
        };
      })()`;
  let takeover = null;
  for (let launch = 0; launch < 5 && !takeover; launch += 1) {
    await cdp.send('Target.closeTarget', { targetId: updated.targetId });
    await new Promise((r) => setTimeout(r, 1500));
    updated = await openPage(cdp, `${origin}/`);
    await firstFrame(updated, 'first frame on the launch after the update');
    takeover = await waitFor(() => updated.eval(takeoverProbe), {
      what: 'the rebuilt worker to take over and drop the old cache',
      timeout: 10000,
      interval: 500,
    }).catch(() => null);
  }
  assert.ok(takeover, 'the rebuilt worker took over at a later launch');
  t.diagnostic(`after update: ${JSON.stringify(takeover)}`);
  assert.ok(takeover.canvasKit >= 1, 'CanvasKit carried into the new cache');
  assert.equal(takeover.firebaseSdk, shell.firebaseSdk);
  const current = updated;

  // 2. Cut every route out, then reload.
  app.goOffline();
  proxy.goOffline();
  const blocked = await current.eval(`fetch('${origin}/main.dart.js?probe=' + Date.now()).then(() => 'reachable', () => 'blocked')`);
  assert.equal(blocked, 'blocked', 'the app server is really unreachable');
  await current.send('Page.reload', { ignoreCache: false });
  await firstFrame(current, 'first frame after an offline reload');
  await screenshot(current, 'offline-reload');

  // 3. Close the tab and open the app again, still offline ("next launch").
  await cdp.send('Target.closeTarget', { targetId: current.targetId });
  const reopened = await openPage(cdp, `${origin}/`);
  await firstFrame(reopened, 'first frame on an offline relaunch');
  await screenshot(reopened, 'offline-relaunch');
  const controlled = await reopened.eval('navigator.serviceWorker.controller && navigator.serviceWorker.controller.scriptURL.replace(location.origin, "")');
  assert.equal(controlled, takeover.worker);
});
