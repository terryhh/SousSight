// Drives tool/generate_illustrations.dart in headless Chrome (SS-098).
//
//   node tool/generate_illustrations.mjs premade <build-dir> [--max N]
//   node tool/generate_illustrations.mjs gate <build-dir> <evidence-dir>
//
// <build-dir> is a `flutter build web --target=tool/generate_illustrations.dart`
// output built OUTSIDE the repository (it embeds the App Check debug token:
// delete it after the run). This script serves it on localhost, blocks every
// model request beyond the cap, and never prints console lines that mention
// the debug token.
//
// premade: writes assets/illustrations/<recipe>/<key>.jpg (resized to 800 px
//          wide, JPEG quality 70, with macOS `sips`) and merges each image's
//          prompt, model and date into assets/illustrations/manifest.json.
// gate:    clicks "Show me what it should look like", then "Allow once" in the
//          consent dialog, waits for the labelled illustration, and saves a
//          screenshot plus the ledger legs to <evidence-dir>.
//
// PLAYWRIGHT_MODULE may point at a Playwright index.mjs when `playwright` is
// not resolvable from here.
import { createServer } from 'node:http';
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { existsSync, mkdirSync, readFileSync, realpathSync, statSync, writeFileSync, createReadStream } from 'node:fs';
import { dirname, extname, join, resolve } from 'node:path';
import { fileToServe, gateEvidenceOk, modeAllowed, within } from './generate_illustrations_lib.mjs';
import { fileURLToPath } from 'node:url';

const usage = 'usage: premade <build-dir> --max N | gate <build-dir> <evidence-dir>';
const fail = (message, code = 2) => {
  console.error(message);
  process.exit(code);
};

const repo = realpathSync(resolve(dirname(fileURLToPath(import.meta.url)), '..'));
const [mode, buildArg, third] = process.argv.slice(2);
if (!['premade', 'gate'].includes(mode) || !buildArg) fail(usage);
let cap = 1;
if (mode === 'premade') {
  // A finite, non-negative integer only: NaN would disable the cap below.
  const at = process.argv.indexOf('--max');
  const raw = at > 0 ? process.argv[at + 1] : undefined;
  if (raw === undefined || !/^\d+$/.test(raw)) fail(`--max needs a whole number. ${usage}`);
  cap = Number(raw);
  if (!Number.isSafeInteger(cap)) fail(`--max is out of range. ${usage}`);
} else if (!third) {
  fail(usage);
}
if (!existsSync(buildArg) || !statSync(buildArg).isDirectory()) fail(`No build directory at ${buildArg}`);
// Canonical paths, so a symlink cannot smuggle the repository in.
const build = realpathSync(resolve(buildArg));
if (within(repo, build) || within(build, repo)) {
  fail('Refusing a build inside (or containing) the repository: it holds a debug token.');
}

const { chromium } = await import(process.env.PLAYWRIGHT_MODULE ?? 'playwright');

const types = {
  '.html': 'text/html', '.js': 'text/javascript', '.mjs': 'text/javascript',
  '.json': 'application/json', '.wasm': 'application/wasm', '.png': 'image/png',
  '.jpg': 'image/jpeg', '.otf': 'font/otf', '.ttf': 'font/ttf', '.bin': 'application/octet-stream',
  '.frag': 'application/octet-stream',
};
const server = createServer((req, res) => {
  const path = fileToServe(build, req.url);
  if (path === null) return res.writeHead(403).end();
  res.writeHead(200, { 'content-type': types[extname(path)] ?? 'application/octet-stream', 'cache-control': 'no-store' });
  createReadStream(path).pipe(res);
}).listen(0, '127.0.0.1');
await new Promise((r) => server.once('listening', r));
const url = `http://127.0.0.1:${server.address().port}/`;

const browser = await chromium.launch({ channel: 'chrome', headless: true });
const page = await browser.newPage({ viewport: { width: 900, height: 1100 } });
let modelCalls = 0;
const statuses = [];
// No model request passes until the page has announced a mode this run
// accepts, and (for the gate) until the cook's "Allow once" is clicked.
let announced = null;
let armed = false;
await page.route('**/*', (route) => {
  const u = new URL(route.request().url());
  if (/generateContent/.test(u.pathname)) {
    if (!armed || modelCalls >= cap) {
      statuses.push({ path: u.pathname, aborted: armed ? 'over cap' : 'not armed' });
      return route.abort('blockedbyclient');
    }
    modelCalls += 1;
  }
  return route.continue();
});
page.on('response', (r) => {
  const u = new URL(r.url());
  if (/generateContent/.test(u.pathname)) statuses.push({ path: u.pathname, status: r.status() });
});

let resolveDone;
let doneCalls = -1;
const done = new Promise((r) => { resolveDone = r; });
const images = [];
const ledger = [];
const states = [];
page.on('console', (m) => {
  const text = m.text();
  if (/debug token/i.test(text)) return; // never echo the token
  const [tag, ...rest] = text.split(' ');
  const body = rest.join(' ');
  switch (tag) {
    case 'ILLUSTRATION_MODE':
      announced = JSON.parse(body);
      if (!modeAllowed(mode, cap, announced)) {
        console.log('ERROR: build mode does not match this run:', body);
        resolveDone('wrong-mode');
      } else if (mode === 'premade') {
        armed = true;
      }
      break;
    case 'ILLUSTRATION':
      // Asset writes only for a pre-made run against a pre-made build.
      if (mode === 'premade' && announced?.mode === 'premade') {
        const img = JSON.parse(body);
        images.push(img.key);
        writePremade([img]);
      }
      break;
    case 'ILLUSTRATION_SKIP': console.log('skip', body); break;
    case 'ILLUSTRATION_ERROR': console.log('ERROR (stopping, no retry):', body); resolveDone('error'); break;
    case 'ILLUSTRATION_DONE': console.log('done', body); doneCalls = JSON.parse(body).calls; resolveDone('done'); break;
    case 'ILLUSTRATION_GATE_LEDGER': ledger.push(JSON.parse(body)); break;
    case 'ILLUSTRATION_GATE_STATE': states.push(JSON.parse(body)); break;
    default: if (m.type() === 'error') console.log('[console error]', text.slice(0, 300));
  }
});

let exitCode = 1;
let guard;
try {
  await page.goto(url);
  if (mode === 'premade') {
    const timeout = new Promise((r) => { guard = setTimeout(() => r('timeout'), 15 * 60_000); });
    const outcome = await Promise.race([done, timeout]);
    console.log('outcome', outcome, 'images', images.length);
    // Success only when the page finished and every call it made produced
    // an image that was written.
    if (outcome === 'done' && doneCalls === images.length) exitCode = 0;
  } else {
    if (await gate(third)) exitCode = 0;
  }
} catch (error) {
  console.error('FAILED:', error?.message ?? error);
} finally {
  clearTimeout(guard);
  console.log(JSON.stringify({ modelRequests: modelCalls, responses: statuses, exitCode }));
  await browser.close().catch(() => {});
  server.closeAllConnections();
  server.close();
  process.exit(exitCode);
}

function writePremade(list) {
  const root = join(repo, 'assets', 'illustrations');
  const manifestPath = join(root, 'manifest.json');
  const manifest = existsSync(manifestPath)
    ? JSON.parse(readFileSync(manifestPath, 'utf8'))
    : { label: 'AI illustration — not a photo of your food', images: [] };
  for (const img of list) {
    const dir = join(root, img.recipe);
    mkdirSync(dir, { recursive: true });
    const raw = join(dir, `${img.key}.raw${img.mimeType === 'image/png' ? '.png' : '.img'}`);
    const out = join(dir, `${img.key}.jpg`);
    writeFileSync(raw, Buffer.from(img.bytes, 'base64'));
    execFileSync('sips', ['-s', 'format', 'jpeg', '-s', 'formatOptions', '70', '--resampleWidth', '800', raw, '--out', out], { stdio: 'ignore' });
    execFileSync('rm', [raw]);
    const entry = {
      recipe: img.recipe,
      key: img.key,
      file: `${img.recipe}/${img.key}.jpg`,
      subject: img.subject,
      prompt: img.prompt,
      model: img.model,
      generatedAt: img.generatedAt,
      sourceMimeType: img.mimeType,
      postProcessing: 'sips: JPEG quality 70, 800 px wide',
      sha256: createHash('sha256').update(readFileSync(out)).digest('hex'),
    };
    manifest.images = manifest.images.filter((e) => !(e.recipe === img.recipe && e.key === img.key));
    manifest.images.push(entry);
    console.log('wrote', entry.file);
  }
  manifest.images.sort((a, b) => `${a.recipe}/${a.key}`.localeCompare(`${b.recipe}/${b.key}`));
  writeFileSync(manifestPath, `${JSON.stringify(manifest, null, 2)}\n`);
}

async function gate(evidenceDir) {
  mkdirSync(evidenceDir, { recursive: true });
  const placeholder = page.locator('flt-semantics-placeholder');
  await placeholder.waitFor({ state: 'attached', timeout: 60_000 });
  await placeholder.dispatchEvent('click');
  const ask = page.getByRole('button', { name: 'Show me what it should look like' });
  await ask.waitFor({ timeout: 60_000 });
  await page.screenshot({ path: join(evidenceDir, 'gate-01-ready.png') });
  if (!modeAllowed('gate', cap, announced)) {
    console.log('ERROR: not a gate build; nothing was requested.');
    return false;
  }
  await ask.click();
  const allow = page.getByRole('button', { name: 'Allow once' });
  await allow.waitFor({ timeout: 30_000 });
  await page.screenshot({ path: join(evidenceDir, 'gate-02-consent.png') });
  armed = true; // the one consented request may pass now
  await allow.click();
  const label = page.getByText('AI illustration — not a photo of your food')
    .or(page.getByLabel(/AI illustration — not a photo of your food/)).first();
  let shown = true;
  try {
    await label.waitFor({ timeout: 120_000 });
  } catch {
    shown = false;
  }
  await page.waitForTimeout(1500);
  await page.screenshot({ path: join(evidenceDir, 'gate-03-result.png') });
  const last = ledger.at(-1) ?? null;
  const evidence = {
    shown,
    legs: last?.legs ?? [],
    requests: statuses,
    model: announced?.model,
  };
  const ok = gateEvidenceOk(evidence);
  const result = { ok, ...evidence, states };
  writeFileSync(join(evidenceDir, 'gate-result.json'), `${JSON.stringify(result, null, 2)}\n`);
  console.log(JSON.stringify(result));
  return ok;
}
