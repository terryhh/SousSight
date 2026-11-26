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
import { existsSync, mkdirSync, readFileSync, statSync, writeFileSync, createReadStream } from 'node:fs';
import { dirname, extname, join, normalize, resolve, sep } from 'node:path';
import { fileURLToPath } from 'node:url';

const repo = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const [mode, buildArg, third] = process.argv.slice(2);
const maxFlag = process.argv.indexOf('--max');
const cap = mode === 'gate' ? 1 : Number(maxFlag > 0 ? process.argv[maxFlag + 1] : 0);
if (!['premade', 'gate'].includes(mode) || !buildArg) {
  console.error('usage: premade <build-dir> --max N | gate <build-dir> <evidence-dir>');
  process.exit(2);
}
const build = resolve(buildArg);
if (build.startsWith(repo + sep)) {
  console.error('Refusing a build inside the repository: it holds a debug token.');
  process.exit(2);
}

const { chromium } = await import(process.env.PLAYWRIGHT_MODULE ?? 'playwright');

const types = {
  '.html': 'text/html', '.js': 'text/javascript', '.mjs': 'text/javascript',
  '.json': 'application/json', '.wasm': 'application/wasm', '.png': 'image/png',
  '.jpg': 'image/jpeg', '.otf': 'font/otf', '.ttf': 'font/ttf', '.bin': 'application/octet-stream',
  '.frag': 'application/octet-stream',
};
const server = createServer((req, res) => {
  let path = normalize(join(build, decodeURIComponent(req.url.split('?')[0])));
  if (!path.startsWith(build)) return res.writeHead(403).end();
  if (!existsSync(path) || statSync(path).isDirectory()) path = join(build, 'index.html');
  res.writeHead(200, { 'content-type': types[extname(path)] ?? 'application/octet-stream', 'cache-control': 'no-store' });
  createReadStream(path).pipe(res);
}).listen(0, '127.0.0.1');
await new Promise((r) => server.once('listening', r));
const url = `http://127.0.0.1:${server.address().port}/`;

const browser = await chromium.launch({ channel: 'chrome', headless: true });
const page = await browser.newPage({ viewport: { width: 900, height: 1100 } });
let modelCalls = 0;
const statuses = [];
await page.route('**/*', (route) => {
  const u = new URL(route.request().url());
  if (/generateContent/.test(u.pathname)) {
    modelCalls += 1;
    if (modelCalls > cap) {
      statuses.push({ path: u.pathname, aborted: 'over cap' });
      return route.abort('blockedbyclient');
    }
  }
  return route.continue();
});
page.on('response', (r) => {
  const u = new URL(r.url());
  if (/generateContent/.test(u.pathname)) statuses.push({ path: u.pathname, status: r.status() });
});

let resolveDone;
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
    case 'ILLUSTRATION': { const img = JSON.parse(body); images.push(img.key); writePremade([img]); break; }
    case 'ILLUSTRATION_SKIP': console.log('skip', body); break;
    case 'ILLUSTRATION_ERROR': console.log('ERROR (stopping, no retry):', body); resolveDone('error'); break;
    case 'ILLUSTRATION_DONE': console.log('done', body); resolveDone('done'); break;
    case 'ILLUSTRATION_GATE_LEDGER': ledger.push(JSON.parse(body)); break;
    case 'ILLUSTRATION_GATE_STATE': states.push(JSON.parse(body)); break;
    default: if (m.type() === 'error') console.log('[console error]', text.slice(0, 300));
  }
});

await page.goto(url);
try {
  if (mode === 'premade') {
    const outcome = await Promise.race([done, new Promise((r) => setTimeout(() => r('timeout'), 15 * 60_000))]);
    console.log('outcome', outcome, 'images', images.length);
  } else {
    await gate(third);
  }
} finally {
  console.log(JSON.stringify({ modelRequests: modelCalls, responses: statuses }));
  await browser.close();
  server.closeAllConnections();
  server.close();
  process.exit(0); // the 15-minute guard timer must not hold the process
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
  await ask.click();
  const allow = page.getByRole('button', { name: 'Allow once' });
  await allow.waitFor({ timeout: 30_000 });
  await page.screenshot({ path: join(evidenceDir, 'gate-02-consent.png') });
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
  const result = { shown, states, ledger: ledger.at(-1) ?? null };
  writeFileSync(join(evidenceDir, 'gate-result.json'), `${JSON.stringify(result, null, 2)}\n`);
  console.log(JSON.stringify(result));
}
