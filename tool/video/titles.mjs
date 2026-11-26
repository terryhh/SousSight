#!/usr/bin/env node
// Renders the demo video's still images with headless Chrome (HTML -> PNG,
// 1920x1080, brand palette, system sans font):
//
//   node tool/video/titles.mjs --edl <edl.json> --out build/video/cards
//       title-<id>.png        full-frame title card (source: title)
//       caption-<id>.png      transparent lower-third caption overlay
//       placeholder-<id>.png  "Terry clip: <slot> — <instructions>" (source: terry)
//                             or "Capture missing: <step>" (source: capture)
//       phone-frame.png, phone-frame-rehearsal.png   bezel for phone clips
//
//   node tool/video/titles.mjs --contact-sheet <frames.json> --out <sheet.png>
//       frames.json: [{ "image": "<png path>", "label": "...", "detail": "..." }]
//
// Only title cards and these overlays are generated imagery. App footage is
// always a real recording (capture.mjs) or Terry's own clip.
import { mkdirSync, readFileSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { BRAND, CANVAS, FONT_STACK, PHONE_SCREEN, loadPlaywright, parseArgs } from './common.mjs';

export function escapeHtml(value) {
  return String(value ?? '')
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&#39;');
}

function page(body, { transparent = false, extraCss = '' } = {}) {
  const background = transparent
    ? 'transparent'
    : `radial-gradient(circle at 18% 12%, ${BRAND.cream} 0%, ${BRAND.paper} 62%, #ece5d6 100%)`;
  return `<!doctype html><html><head><meta charset="utf-8"><style>
html,body{margin:0;width:${CANVAS.width}px;height:${CANVAS.height}px;overflow:hidden;background:${background};
font-family:${FONT_STACK};-webkit-font-smoothing:antialiased;color:${BRAND.ink}}
*{box-sizing:border-box}
${extraCss}
</style></head><body>${body}</body></html>`;
}

const brandMark = `<div class="mark"><span class="dot"></span>SousSight</div>`;
const markCss = `.mark{display:flex;align-items:center;gap:14px;font-weight:700;font-size:34px;color:${BRAND.forest};letter-spacing:.2px}
.dot{width:22px;height:22px;border-radius:50%;background:${BRAND.terracotta};box-shadow:0 0 0 6px rgba(191,91,50,.18)}`;

/// Full-frame title card: headline and optional sub line.
export function titleCardHtml({ text, sub = '' }) {
  if (!text || !String(text).trim()) throw new Error('title card needs text');
  const css = `${markCss}
.wrap{position:absolute;inset:0;padding:120px 160px;display:flex;flex-direction:column;justify-content:center}
.wrap .mark{position:absolute;top:96px;left:160px}
h1{margin:0;font-size:104px;line-height:1.05;font-weight:800;color:${BRAND.forestDeep};letter-spacing:-1.5px;max-width:1500px}
.rule{width:180px;height:12px;border-radius:6px;background:${BRAND.gold};margin:44px 0 40px}
p{margin:0;font-size:46px;line-height:1.3;color:${BRAND.forest};max-width:1450px;font-weight:500}
.band{position:absolute;left:0;top:0;bottom:0;width:28px;background:linear-gradient(${BRAND.forest},${BRAND.forestDeep})}`;
  const body = `<div class="band"></div><div class="wrap">${brandMark}
<h1>${escapeHtml(text)}</h1><div class="rule"></div>${sub ? `<p>${escapeHtml(sub)}</p>` : ''}</div>`;
  return page(body, { extraCss: css });
}

/// Transparent full-frame overlay with a lower-third caption pill.
export function captionHtml(text) {
  if (!text || !String(text).trim()) throw new Error('caption needs text');
  const css = `.cap{position:absolute;left:50%;bottom:56px;transform:translateX(-50%);max-width:1560px;
padding:20px 44px;border-radius:999px;background:rgba(20,58,43,.9);color:${BRAND.cream};
font-size:46px;font-weight:650;line-height:1.2;text-align:center;box-shadow:0 10px 30px rgba(0,0,0,.25);
border:3px solid rgba(233,162,59,.85)}`;
  return page(`<div class="cap">${escapeHtml(text)}</div>`, { transparent: true, extraCss: css });
}

/// Stand-in card for a clip that is not there yet. kind: 'terry' | 'capture'.
export function placeholderHtml({ kind, slot, instructions = '', durationS }) {
  if (!['terry', 'capture'].includes(kind)) throw new Error(`unknown placeholder kind: ${kind}`);
  if (!slot) throw new Error('placeholder needs a slot');
  const label = kind === 'terry' ? 'Terry clip' : 'Capture missing';
  const headline = `${label}: ${slot}`;
  const detail =
    kind === 'terry'
      ? instructions
      : instructions || 'This build did not show this step, or capture.mjs has not been run.';
  const css = `${markCss}
body{background:repeating-linear-gradient(135deg,${BRAND.forestDeep} 0 36px,#173f2f 36px 72px)}
.box{position:absolute;inset:70px;border:6px dashed ${BRAND.gold};border-radius:36px;padding:90px 110px;color:${BRAND.cream};
display:flex;flex-direction:column;justify-content:center}
.tag{align-self:flex-start;background:${BRAND.gold};color:${BRAND.forestDeep};font-weight:800;font-size:30px;letter-spacing:3px;
padding:10px 22px;border-radius:12px;text-transform:uppercase}
h1{font-size:76px;line-height:1.1;margin:36px 0 28px;font-weight:800}
p{font-size:42px;line-height:1.35;margin:0;max-width:1500px;color:#f3ead7}
.dur{position:absolute;right:60px;bottom:44px;font-size:30px;color:${BRAND.gold};font-weight:700}`;
  const dur = typeof durationS === 'number' ? `<div class="dur">${durationS.toFixed(1)} s</div>` : '';
  const body = `<div class="box"><div class="tag">Placeholder — not app footage</div>
<h1>${escapeHtml(headline)}</h1><p>— ${escapeHtml(detail)}</p>${dur}</div>`;
  return page(body, { extraCss: css });
}

/// Transparent 1080p frame with a hole where the phone screen goes
/// (PHONE_SCREEN). With [label], a side note such as "Rehearsal build · simulated".
export function phoneFrameHtml({ label = '' } = {}) {
  const s = PHONE_SCREEN;
  const bezel = 18;
  const css = `.hole{position:absolute;left:${s.x}px;top:${s.y}px;width:${s.width}px;height:${s.height}px;border-radius:${s.radius}px;
box-shadow:0 0 0 2400px ${BRAND.paper}}
.bezel{position:absolute;left:${s.x - bezel}px;top:${s.y - bezel}px;width:${s.width + 2 * bezel}px;height:${s.height + 2 * bezel}px;
border-radius:${s.radius + bezel}px;border:${bezel}px solid #18221d;box-shadow:0 30px 70px rgba(20,58,43,.28),0 0 0 2px #3a4a41}
.label{position:absolute;left:${s.x + s.width + 90}px;top:${s.y + 40}px;font-size:30px;font-weight:700;color:${BRAND.forestDeep};
background:${BRAND.gold};padding:12px 22px;border-radius:14px;max-width:520px;line-height:1.25}`;
  const body = `<div class="hole"></div><div class="bezel"></div>${label ? `<div class="label">${escapeHtml(label)}</div>` : ''}`;
  return page(body, { transparent: true, extraCss: css });
}

/// Grid of labelled frames for reviewing a cut. [frames]: [{ src, label, detail }]
/// where src is a URL (data: URLs keep the page self-contained).
export function contactSheetHtml(frames, { columns = 4, title = 'SousSight demo — contact sheet' } = {}) {
  const cells = frames
    .map(
      (f) => `<figure><img src="${escapeHtml(f.src)}"><figcaption><b>${escapeHtml(f.label)}</b>
<span>${escapeHtml(f.detail ?? '')}</span></figcaption></figure>`,
    )
    .join('');
  const css = `html,body{height:auto;overflow:visible}
body{padding:36px;background:${BRAND.paper}}
h1{margin:0 0 24px;font-size:34px;color:${BRAND.forestDeep}}
.grid{display:grid;grid-template-columns:repeat(${columns},1fr);gap:22px}
figure{margin:0;background:${BRAND.cream};border-radius:14px;overflow:hidden;box-shadow:0 2px 8px rgba(0,0,0,.08)}
img{display:block;width:100%;aspect-ratio:16/9;object-fit:contain;background:#000}
figcaption{padding:10px 14px 14px;font-size:19px;line-height:1.3}
figcaption b{display:block;color:${BRAND.forest}}
figcaption span{color:#4c5a52}`;
  return page(`<h1>${escapeHtml(title)}</h1><div class="grid">${cells}</div>`, { extraCss: css });
}

/// The PNGs to render for an EDL: [{ out, html, transparent }].
export function cardJobsForEdl(segments, outDir) {
  if (!Array.isArray(segments)) throw new Error('EDL must be an array of segments');
  const jobs = [
    { out: join(outDir, 'phone-frame.png'), html: phoneFrameHtml(), transparent: true },
    {
      out: join(outDir, 'phone-frame-rehearsal.png'),
      html: phoneFrameHtml({ label: 'Rehearsal build · AI, camera and messages simulated' }),
      transparent: true,
    },
  ];
  for (const seg of segments) {
    const id = seg.id;
    if (!/^[A-Za-z0-9._-]+$/.test(String(id ?? ''))) throw new Error(`bad segment id: ${id}`);
    if (seg.source === 'title') {
      jobs.push({ out: join(outDir, `title-${id}.png`), html: titleCardHtml(seg.title ?? {}) });
    } else if (seg.source === 'terry') {
      jobs.push({
        out: join(outDir, `placeholder-${id}.png`),
        html: placeholderHtml({
          kind: 'terry',
          slot: seg.terry_clip,
          instructions: seg.terry_instructions,
          durationS: seg.duration_s,
        }),
      });
    } else if (seg.source === 'capture') {
      const step = seg.capture?.journey_step;
      const viewport = seg.capture?.viewport;
      jobs.push({
        out: join(outDir, `placeholder-${id}.png`),
        html: placeholderHtml({ kind: 'capture', slot: `${step} (${viewport})`, durationS: seg.duration_s }),
      });
    }
    if (seg.caption && String(seg.caption).trim()) {
      jobs.push({ out: join(outDir, `caption-${id}.png`), html: captionHtml(seg.caption), transparent: true });
    }
  }
  return jobs;
}

/// Renders [jobs] in one headless Chrome. fullPage jobs grow to fit content.
export async function renderJobs(jobs) {
  const { chromium } = await loadPlaywright();
  const browser = await chromium.launch({ channel: 'chrome', headless: true });
  try {
    const context = await browser.newContext({ viewport: CANVAS, deviceScaleFactor: 1 });
    const tab = await context.newPage();
    // Cards are self-contained: refuse any network fetch.
    await tab.route('**/*', (route) =>
      /^(data|about):/.test(route.request().url()) ? route.continue() : route.abort(),
    );
    for (const job of jobs) {
      await tab.setContent(job.html, { waitUntil: 'load' });
      await tab.screenshot({ path: job.out, omitBackground: Boolean(job.transparent), fullPage: Boolean(job.fullPage) });
    }
  } finally {
    await browser.close();
  }
}

function dataUrl(path) {
  return `data:image/png;base64,${readFileSync(path).toString('base64')}`;
}

async function main(argv) {
  const args = parseArgs(argv, { values: ['edl', 'out', 'contact-sheet', 'title'] });
  if (!args.out) throw new Error('--out is required');
  if (args['contact-sheet']) {
    const frames = JSON.parse(readFileSync(args['contact-sheet'], 'utf8')).map((f) => ({
      src: dataUrl(f.image),
      label: f.label,
      detail: f.detail,
    }));
    const html = contactSheetHtml(frames, args.title ? { title: args.title } : {});
    await renderJobs([{ out: resolve(args.out), html, fullPage: true }]);
    console.log(`contact sheet: ${resolve(args.out)}`);
    return;
  }
  if (!args.edl) throw new Error('--edl or --contact-sheet is required');
  const segments = JSON.parse(readFileSync(args.edl, 'utf8'));
  const outDir = resolve(args.out);
  mkdirSync(outDir, { recursive: true });
  const jobs = cardJobsForEdl(segments, outDir);
  await renderJobs(jobs);
  console.log(`rendered ${jobs.length} images into ${outDir}`);
}

if (import.meta.url === pathToFileURL(process.argv[1] ?? '').href) {
  main(process.argv.slice(2)).catch((error) => {
    console.error(`titles.mjs: ${error.message}`);
    process.exit(1);
  });
}
