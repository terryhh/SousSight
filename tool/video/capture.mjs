#!/usr/bin/env node
// Records the SousSight journey as real screen recordings, one clip per step
// (names in journey_steps.json), for the demo video.
//
//   node tool/video/capture.mjs                      # local REHEARSAL build in build/web
//   node tool/video/capture.mjs --build-dir build/web --viewports desktop
//   node tool/video/capture.mjs --base-url https://<hosted> --real-services [--allow-ai]
//
// Playwright drives the INSTALLED Google Chrome with a fake camera and
// microphone (tool/e2e's pinned Playwright and its helpers are reused) and
// records the page with recordVideo: 1920x1080 for desktop, 412x915 (rendered
// at 2x) for phone, which is then placed in a phone frame on a 1080p canvas.
// Interactions are paced like a person: a visible pointer glides to each
// control, text is typed key by key, and each step holds for a beat.
//
// Output (gitignored): build/video/capture/<viewport>/<step>.mp4 plus
// manifest.json saying what each step showed (or why it is absent) and
// evidence/ (console log, request report). Raw recordings are deleted unless
// --keep-raw.
//
// Safety: the default target is a rehearsal build and the run aborts if the
// rehearsal banner is missing or the page contacts Firebase or any AI,
// Live-token, dinner-message or Vonage endpoint. Real services need the
// explicit --real-services flag; model and messaging calls stay blocked
// unless --allow-ai is given as well. The recording is the page only: no
// browser chrome, profile, bookmarks or URL bar.
import { spawn, spawnSync } from 'node:child_process';
import { existsSync, mkdirSync, rmSync, writeFileSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { CANVAS, E2E_DIR, JOURNEY_STEPS, PHONE_SCREEN, REPO, VIEWPORTS, loadPlaywright, parseArgs } from './common.mjs';
import { phoneFrameHtml, renderJobs } from './titles.mjs';

// Defaults match the rehearsal's fixed simulated pantry result (bread, peanut
// butter, ...). For the hosted build, --pantry/--recipe/--question can follow
// DEMO-SCRIPT.md (chickpeas, Smashed Chickpea Salad Wrap).
export const PANTRY = 'bread, peanut butter, banana';
export const RECIPE = 'Peanut Butter Sandwich';
export const QUESTION = 'How thick should I spread the peanut butter?';

export const VIEWPORT_SPECS = Object.freeze({
  desktop: { viewport: { width: 1920, height: 1080 }, deviceScaleFactor: 1, video: { width: 1920, height: 1080 } },
  // recordVideo captures CSS pixels (a higher deviceScaleFactor only pads the
  // video), so the phone is recorded at 412x915 and scaled up slightly.
  phone: { viewport: { width: 412, height: 915 }, deviceScaleFactor: 1, video: { width: 412, height: 915 } },
});

const USAGE = `usage: node tool/video/capture.mjs [--build-dir build/web] [--viewports desktop,phone]
       [--out build/video/capture] [--port 8791] [--headed] [--no-cursor] [--keep-raw]
       [--pantry "<typed list>"] [--recipe "<recipe title>"] [--question "<coach question>"]
       node tool/video/capture.mjs --base-url <url> --real-services [--allow-ai]`;

export function escapeRegExp(text) {
  return String(text).replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

/// Validates options. Returns { problems: [...], config }.
export function captureConfig(args) {
  const problems = [];
  const viewports = (args.viewports ?? VIEWPORTS.join(',')).split(',').map((v) => v.trim()).filter(Boolean);
  for (const v of viewports) if (!VIEWPORTS.includes(v)) problems.push(`unknown viewport "${v}"`);
  if (viewports.length === 0) problems.push('no viewports selected');
  const real = Boolean(args['real-services']);
  if (args['base-url']) {
    let url;
    try {
      url = new URL(args['base-url']);
    } catch {
      problems.push(`--base-url is not a URL: ${args['base-url']}`);
    }
    if (url && url.protocol !== 'https:' && url.hostname !== 'localhost' && url.hostname !== '127.0.0.1') {
      problems.push('--base-url must be https (or http://localhost)');
    }
    if (url && (url.username || url.password || url.search || url.hash)) {
      problems.push('--base-url must not carry credentials, a query string or a fragment');
    }
    if (!real) problems.push('--base-url records a hosted build against real services; add --real-services to confirm');
    if (args['build-dir']) problems.push('use either --base-url or --build-dir, not both');
  }
  if (args['allow-ai'] && !real) problems.push('--allow-ai needs --real-services');
  const port = Number(args.port ?? 8791);
  if (!Number.isInteger(port) || port < 1024 || port > 65535) problems.push(`bad --port: ${args.port}`);
  for (const key of ['pantry', 'recipe', 'question']) {
    if (key in args && !String(args[key]).trim()) problems.push(`--${key} must not be empty`);
    if (key in args && String(args[key]).length > 200) problems.push(`--${key} is too long (200 characters max)`);
  }
  return {
    problems,
    config: {
      pantry: args.pantry ?? PANTRY,
      recipe: args.recipe ?? RECIPE,
      question: args.question ?? QUESTION,
      viewports,
      mode: real ? 'real' : 'rehearsal',
      baseUrl: args['base-url'] ?? null,
      buildDir: resolve(REPO, args['build-dir'] ?? 'build/web'),
      outDir: resolve(REPO, args.out ?? 'build/video/capture'),
      port,
      allowAi: Boolean(args['allow-ai']),
      headed: Boolean(args.headed),
      cursor: !args['no-cursor'],
      keepRaw: Boolean(args['keep-raw']),
    },
  };
}

/// ffmpeg arguments that cut [start, start+duration) out of a raw recording
/// and normalise it to a 1080p30 H.264 clip. Phone clips are scaled into
/// PHONE_SCREEN on a cream canvas under [framePng].
export function clipFfmpegArgs({ raw, start, duration, viewport, framePng, out }) {
  if (!(duration > 0)) throw new Error(`clip duration must be positive (got ${duration})`);
  const common = ['-hide_banner', '-loglevel', 'error', '-y', '-ss', start.toFixed(3), '-i', raw];
  const encode = ['-t', duration.toFixed(3), '-an', '-c:v', 'libx264', '-preset', 'medium', '-crf', '18',
    '-pix_fmt', 'yuv420p', '-r', '30', '-movflags', '+faststart', out];
  if (viewport === 'desktop') {
    const vf = `fps=30,scale=${CANVAS.width}:${CANVAS.height}:flags=lanczos,setsar=1,format=yuv420p`;
    return [...common, '-vf', vf, ...encode];
  }
  if (viewport === 'phone') {
    if (!framePng) throw new Error('phone clips need the frame PNG');
    const s = PHONE_SCREEN;
    const graph = [
      `[0:v]fps=30,scale=${s.width}:${s.height}:flags=lanczos,setsar=1[screen]`,
      `color=c=0xf5f1e8:s=${CANVAS.width}x${CANVAS.height}:r=30[bg]`,
      `[bg][screen]overlay=${s.x}:${s.y}:shortest=1[placed]`,
      `[placed][1:v]overlay=0:0:shortest=1,format=yuv420p[v]`,
    ].join(';');
    return [...common, '-loop', '1', '-i', framePng, '-filter_complex', graph, '-map', '[v]', ...encode];
  }
  throw new Error(`unknown viewport: ${viewport}`);
}

/// Deterministic per-key typing delays (ms) that look human: 55-140 ms,
/// longer after spaces and commas.
export function typingDelays(text, seed = 7) {
  let state = seed >>> 0;
  return [...text].map((ch) => {
    state = (state * 1664525 + 1013904223) >>> 0;
    const base = 55 + (state % 70);
    return ch === ' ' || ch === ',' ? base + 70 : base;
  });
}

/// A visible pointer for the recording (headless Chrome draws none). It is
/// a DOM overlay that follows real pointer events; it never intercepts them.
function cursorInitScript() {
  const install = () => {
    if (document.getElementById('__video_cursor')) return;
    const dot = document.createElement('div');
    dot.id = '__video_cursor';
    Object.assign(dot.style, {
      position: 'fixed', left: '-100px', top: '-100px', width: '28px', height: '28px',
      borderRadius: '50%', background: 'rgba(191,91,50,0.38)', border: '3px solid rgba(255,253,248,0.95)',
      boxShadow: '0 0 0 2px rgba(20,58,43,0.55), 0 4px 10px rgba(0,0,0,0.25)',
      transform: 'translate(-50%,-50%)', zIndex: '2147483647', pointerEvents: 'none',
      transition: 'width 120ms, height 120ms, background 120ms',
    });
    document.documentElement.appendChild(dot);
    const move = (e) => { dot.style.left = `${e.clientX}px`; dot.style.top = `${e.clientY}px`; };
    addEventListener('pointermove', move, true);
    addEventListener('pointerdown', (e) => { move(e); dot.style.width = dot.style.height = '20px'; dot.style.background = 'rgba(191,91,50,0.75)'; }, true);
    addEventListener('pointerup', () => { dot.style.width = dot.style.height = '28px'; dot.style.background = 'rgba(191,91,50,0.38)'; }, true);
  };
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', install);
  else install();
}

class Pacer {
  constructor(page) {
    this.page = page;
    this.x = page.viewportSize().width / 2;
    this.y = page.viewportSize().height / 2;
  }

  wait(ms) {
    return this.page.waitForTimeout(ms);
  }

  async glideTo(x, y) {
    const distance = Math.hypot(x - this.x, y - this.y);
    const steps = Math.max(8, Math.min(45, Math.round(distance / 22)));
    const [sx, sy] = [this.x, this.y];
    for (let i = 1; i <= steps; i += 1) {
      const t = i / steps;
      const ease = t < 0.5 ? 2 * t * t : 1 - (-2 * t + 2) ** 2 / 2;
      await this.page.mouse.move(sx + (x - sx) * ease, sy + (y - sy) * ease);
      await this.page.waitForTimeout(14);
    }
    this.x = x;
    this.y = y;
  }

  async hover(locator) {
    const box = await locator.boundingBox();
    if (!box) throw new Error('element has no box to hover');
    await this.glideTo(box.x + box.width / 2, box.y + box.height / 2);
  }

  async click(locator, { before = 350 } = {}) {
    await this.hover(locator);
    await this.wait(before);
    await locator.click();
  }

  async type(locator, text, expect) {
    await this.click(locator);
    await expect(locator).toBeFocused();
    await this.wait(400);
    for (const [i, delay] of typingDelays(text).entries()) {
      await this.page.keyboard.type(text[i]);
      await this.wait(delay);
    }
    await expect(locator).toHaveValue(text);
  }

  /// Wheel-scrolls in small steps until [target]'s centre sits between
  /// [top] and [bottom] (fractions of the viewport height).
  async scrollIntoView(target, { top = 0.2, bottom = 0.65 } = {}) {
    const { height, width } = this.page.viewportSize();
    // The wheel scrolls whatever is under the pointer: move it off the bottom
    // control dock (and back into the page) onto the main scroll view first.
    if (this.x < 0 || this.x > width || this.y < height * 0.1 || this.y > height * 0.72) {
      await this.glideTo(width / 2, height * 0.42);
    }
    let last = null;
    let stalled = 0;
    for (let i = 0; i < 240; i += 1) {
      const box = await target.boundingBox();
      if (box) {
        const centre = box.y + box.height / 2;
        if (centre >= height * top && centre <= height * bottom) return;
        // Pinned or already at the scroll limit: stop instead of wheeling on.
        stalled = last !== null && Math.abs(centre - last) < 1 ? stalled + 1 : 0;
        if (stalled >= 4) return;
        last = centre;
        const delta = Math.sign(centre - height * ((top + bottom) / 2)) * 45;
        await this.page.mouse.wheel(0, delta);
      } else {
        await this.page.mouse.wheel(0, 45);
      }
      await this.page.waitForTimeout(22);
    }
  }

  /// Holds on the current screen for [ms] while the pointer drifts a little,
  /// so a held shot does not look frozen and editors have room to trim.
  async linger(ms) {
    const { width, height } = this.page.viewportSize();
    const [cx, cy] = [Math.min(Math.max(this.x, 40), width - 40), Math.min(Math.max(this.y, 40), height - 40)];
    const end = Date.now() + ms;
    for (let t = 0; Date.now() < end; t += 1) {
      await this.page.mouse.move(cx + 18 * Math.sin(t / 9), cy + 10 * Math.sin(t / 13));
      await this.page.waitForTimeout(40);
    }
    this.x = cx;
    this.y = cy;
  }

  async scrollBy(total, { stepPx = 40, everyMs = 24 } = {}) {
    for (let done = 0; done < Math.abs(total); done += stepPx) {
      await this.page.mouse.wheel(0, Math.sign(total) * stepPx);
      await this.page.waitForTimeout(everyMs);
    }
  }
}

function startServer(buildDir, port) {
  const child = spawn(process.execPath, [join(E2E_DIR, 'serve.mjs'), buildDir, String(port)], {
    stdio: ['ignore', 'pipe', 'inherit'],
  });
  return new Promise((resolveReady, reject) => {
    const timer = setTimeout(() => reject(new Error('local server did not start')), 10_000);
    child.stdout.on('data', (chunk) => {
      if (String(chunk).includes('serving')) {
        clearTimeout(timer);
        resolveReady(child);
      }
    });
    child.on('exit', (code) => reject(new Error(`local server exited (${code})`)));
  });
}

/// Runs the journey on [page], timing each step against the recording. Returns
/// per-step results: { step, status: 'recorded' | 'absent', start, end, shows }.
async function runJourney(page, { pw, mode, pacer, now, cfg, lingerMs = 4000 }) {
  const { pantry, recipe, question } = cfg;
  const { expect } = pw;
  const { enableSemantics, seen } = await import(pathToFileURL(join(E2E_DIR, 'flutter.mjs')).href);
  const results = [];
  const record = async (step, body) => {
    const start = now();
    const outcome = (await body()) ?? {};
    if ((outcome.status ?? 'recorded') === 'recorded') await pacer.linger(lingerMs);
    results.push({ step, status: outcome.status ?? 'recorded', start, end: now(), shows: outcome.shows ?? '' });
  };

  const findMeal = page.getByRole('button', { name: 'Find my meal' });
  await page.goto('/');
  await enableSemantics(page);
  await expect(findMeal).toBeVisible({ timeout: 60_000 });
  const banner = await seen(page, /^Rehearsal mode ·/).isVisible();
  if (mode === 'rehearsal' && !banner) throw new Error('rehearsal banner missing: this is not a rehearsal build');
  if (mode === 'real' && banner) throw new Error('--real-services was given but the build is a rehearsal');
  await pacer.wait(800);

  await record('home', async () => {
    for (const name of ['Scan', 'Say it', 'Type it']) {
      const b = page.getByRole('button', { name });
      if (await b.count()) {
        await pacer.hover(b.first());
        await pacer.wait(550);
      }
    }
    await pacer.wait(900);
    return { shows: `Pantry home screen${banner ? ' with the "Rehearsal mode" banner' : ''}; pointer passes Scan, Say it, Type it.` };
  });

  await record('type-list', async () => {
    await pacer.click(page.getByRole('button', { name: 'Type it' }));
    await pacer.wait(700);
    const field = page.getByRole('textbox', { name: /canned black beans/ });
    await expect(field).toBeVisible();
    await pacer.type(field, pantry, expect);
    await pacer.wait(1000);
    return { shows: `"Type it" opened; "${pantry}" typed key by key.` };
  });

  let findOutcome = 'none';
  const unavailable = seen(page, /Ingredient matching is unavailable|could not read that answer/);
  await record('find-meal', async () => {
    await pacer.click(findMeal);
    findOutcome = await Promise.race([
      seen(page, 'Your pantry haul').waitFor({ timeout: 60_000 }).then(() => 'result'),
      unavailable.waitFor({ timeout: 60_000 }).then(() => 'unavailable'),
    ]).catch(() => 'none');
    await pacer.wait(2200);
    if (findOutcome === 'none') throw new Error('Find my meal produced neither a result nor a reason');
    if (mode === 'rehearsal' && findOutcome !== 'result') throw new Error(`rehearsal Find my meal: ${findOutcome}`);
    return {
      shows:
        findOutcome === 'result'
          ? `"Find my meal" tapped; "Your pantry haul" result appears${mode === 'rehearsal' ? ' (fixed simulated result)' : ''}.`
          : '"Find my meal" tapped; "Ingredient matching is unavailable right now" (no on-device or approved cloud model).',
    };
  });

  let cook;
  await record('result-badge', async () => {
    if (findOutcome !== 'result') {
      await pacer.scrollIntoView(unavailable);
      await pacer.wait(2500);
      cook = page.getByRole('button', { name: new RegExp(`^${escapeRegExp(recipe)}`) });
      return { status: 'absent', shows: 'No result, so no source badge (matching unavailable in this build).' };
    }
    const badge = page.getByRole('button', { name: /^Where this ran:/ }).first();
    await expect(badge).toBeVisible();
    const label = (await badge.getAttribute('aria-label')) ?? (await badge.textContent()) ?? '';
    await pacer.scrollIntoView(badge, { top: 0.25, bottom: 0.5 });
    await pacer.hover(badge);
    await pacer.wait(1800);
    // The result's own "Cook <recipe>" button, else the recipe list below it.
    cook = page.getByRole('button', { name: new RegExp(`^Cook ${escapeRegExp(recipe)}`) }).first();
    if ((await cook.count()) === 0) cook = page.getByRole('button', { name: new RegExp(`^${escapeRegExp(recipe)}`) }).first();
    return { shows: `Source badge in view: "${label.trim()}".` };
  });

  await record('open-recipe', async () => {
    await pacer.scrollIntoView(cook, { top: 0.3, bottom: 0.6 });
    await pacer.hover(cook);
    await pacer.wait(1200);
    await cook.click();
    await expect(seen(page, 'Your cooking space')).toBeVisible({ timeout: 60_000 });
    await pacer.wait(900);
    return { shows: `Recipe "${recipe}" opened; cooking screen appears.` };
  });

  await record('cooking-screen', async () => {
    await expect(seen(page, recipe)).toBeVisible();
    const next = seen(page, 'Your next move');
    if (await next.count()) await pacer.hover(next);
    await pacer.wait(1800);
    const watch = page.getByRole('button', { name: /Watch my food/ });
    if (await watch.count()) await pacer.hover(watch);
    await pacer.wait(1600);
    return { shows: 'Cooking screen: camera card ("Your counter is the canvas"), ingredients, first step, allergen chip.' };
  });

  const composer = page.getByRole('textbox', { name: /Ask the coach|Ask Coach Lite|Your answer/ });
  const ledgerButton = page.getByRole('button', { name: 'What was sent' });
  const onDeviceButton = page.getByRole('button', { name: 'On-device AI' });
  const hasHybrid = (await ledgerButton.count()) > 0;

  await record('coach-lite-question', async () => {
    await expect(composer).toBeVisible();
    await pacer.type(composer, question, expect);
    await pacer.wait(700);
    await pacer.click(page.getByRole('button', { name: 'Send message' }));
    return { shows: `Question typed into the composer and sent: "${question}"` };
  });

  await record('coach-lite-answer', async () => {
    const badge = page.getByRole('button', { name: /^Where this ran:/ }).first();
    const liveAlert = seen(page, /Connect the live coach to talk or type a question/);
    const consent = page.getByRole('button', { name: "Don't send" });
    const blocked = seen(page, /on-device coach (is still downloading|can't|isn't ready|is not available|could not answer)|can't run the on-device coach|Nothing was sent\./);
    const outcome = await Promise.race([
      liveAlert.waitFor({ timeout: 45_000 }).then(() => 'live-alert'),
      consent.waitFor({ timeout: 45_000 }).then(() => 'consent'),
      badge.waitFor({ timeout: 45_000 }).then(() => 'answered'),
      blocked.waitFor({ timeout: 45_000 }).then(() => 'blocked'),
    ]).catch(() => 'none');
    const target = { 'live-alert': liveAlert, answered: badge, blocked, consent }[outcome];
    if (target) await pacer.scrollIntoView(target, { top: 0.2, bottom: 0.75 });
    await pacer.wait(3800);
    if (outcome === 'consent') {
      await pacer.click(consent);
      await pacer.wait(1200);
    }
    const shows = {
      'live-alert': 'No Coach Lite in this build: the app says "Connect the live coach to talk or type a question."',
      answered: 'Coach Lite answer with a source badge.',
      blocked: 'Coach Lite unavailable on this device: the recipe step text plus the reason.',
      consent: 'Coach Lite asked to send the question to the cloud; the run declined ("Don\'t send").',
      none: 'No visible reply within 45 s.',
    }[outcome];
    return { status: outcome === 'none' ? 'absent' : 'recorded', shows };
  });

  let watchOutcome = 'none';
  await record('watch-start', async () => {
    const watch = page.getByRole('button', { name: /Watch my food/ });
    await pacer.scrollIntoView(watch, { top: 0.4, bottom: 0.75 });
    const placeholder = seen(page, 'Your counter is the canvas');
    const refused = seen(page, /Watch needs a real camera connection|can't look at photos|watch could not start|camera could not start|so I can't watch|isn't ready yet|still downloading|could not start a watch/);
    await pacer.click(watch);
    watchOutcome = await Promise.race([
      placeholder.waitFor({ state: 'hidden', timeout: 30_000 }).then(() => 'preview'),
      refused.waitFor({ timeout: 30_000 }).then(() => 'refused'),
    ]).catch(() => 'none');
    if (watchOutcome === 'refused') await pacer.scrollIntoView(refused, { top: 0.2, bottom: 0.75 });
    await pacer.wait(3500);
    const reason = watchOutcome === 'refused' ? ((await refused.textContent()) ?? '').trim() : '';
    return {
      status: watchOutcome === 'none' ? 'absent' : 'recorded',
      shows: {
        preview: 'Watch started: the camera card shows frames (Chrome fake camera or simulated frames).',
        refused: `Watch did not start; the app explains why${reason && reason !== 'Dismiss' ? `: "${reason.slice(0, 160)}"` : ' ("Watch needs a real camera connection…")'}.`,
        none: 'No preview and no reason within 30 s.',
      }[watchOutcome],
    };
  });

  await record('watch-unsure', async () => {
    if (watchOutcome !== 'preview') {
      return { status: 'absent', shows: 'Not shown: the watch never started in this build, so there is no verdict.' };
    }
    const unsure = seen(page, /unsure|not sure|better view|can't see|cannot see/i);
    const got = await unsure.waitFor({ timeout: 25_000 }).then(() => true).catch(() => false);
    if (!got) return { status: 'absent', shows: 'No "unsure" verdict within 25 s (a synthetic camera cannot cover a bowl).' };
    await pacer.scrollIntoView(unsure, { top: 0.2, bottom: 0.75 });
    await pacer.wait(3500);
    return { shows: 'Watch verdict: unsure, asks for a better view.' };
  });

  await record('ledger', async () => {
    if (!hasHybrid) return { status: 'absent', shows: 'Not shown: "What was sent" does not exist without a hybrid runtime (rehearsal before SS-089).' };
    await pacer.scrollIntoView(ledgerButton.first(), { top: 0, bottom: 0.6 });
    await pacer.click(ledgerButton.first());
    await expect(seen(page, 'What left this device')).toBeVisible();
    await pacer.wait(4500);
    await page.keyboard.press('Escape');
    await pacer.wait(700);
    return { shows: '"What was sent" sheet ("What left this device").' };
  });

  await record('on-device-sheet', async () => {
    if (!hasHybrid) return { status: 'absent', shows: 'Not shown: "On-device AI" does not exist without a hybrid runtime (rehearsal before SS-089).' };
    await pacer.scrollIntoView(onDeviceButton.first(), { top: 0, bottom: 0.6 });
    await pacer.click(onDeviceButton.first());
    await expect(page.getByRole('heading', { name: 'On-device AI' }).first()).toBeVisible();
    await pacer.wait(4500);
    await page.keyboard.press('Escape');
    await pacer.wait(700);
    return { shows: '"On-device AI" sheet (readiness and keep-on-device switches).' };
  });

  await record('how-it-works', async () => {
    const info = page.getByRole('button', { name: 'How it works' }).first();
    await pacer.scrollIntoView(info, { top: 0, bottom: 0.5 });
    await pacer.click(info);
    await expect(seen(page, 'From pantry to plate')).toBeVisible();
    await pacer.wait(1800);
    const { width, height } = page.viewportSize();
    await pacer.glideTo(width / 2, height * 0.6);
    await pacer.scrollBy(700);
    await pacer.wait(2000);
    await pacer.scrollBy(700);
    await pacer.wait(1800);
    await page.keyboard.press('Escape');
    await pacer.wait(600);
    return { shows: '"How it works" sheet: From pantry to plate, Built with, Your privacy (scrolled).' };
  });

  return results;
}

async function captureViewport(pw, cfg, viewportName, baseURL) {
  const spec = VIEWPORT_SPECS[viewportName];
  const dir = join(cfg.outDir, viewportName);
  const rawDir = join(dir, 'raw');
  rmSync(dir, { recursive: true, force: true });
  mkdirSync(rawDir, { recursive: true });

  const { Evidence } = await import(pathToFileURL(join(E2E_DIR, 'flutter.mjs')).href);
  const browser = await pw.chromium.launch({
    channel: 'chrome',
    headless: !cfg.headed,
    args: ['--use-fake-device-for-media-stream', '--use-fake-ui-for-media-stream'],
  });
  const manifest = { viewport: viewportName, mode: cfg.mode, target: cfg.baseUrl ? 'hosted' : 'local build', steps: [] };
  let failure = null;
  let raw;
  try {
    const context = await browser.newContext({
      baseURL,
      viewport: spec.viewport,
      deviceScaleFactor: spec.deviceScaleFactor,
      permissions: ['camera', 'microphone'],
      recordVideo: { dir: rawDir, size: spec.video },
    });
    const page = await context.newPage();
    const t0 = Date.now();
    const now = () => (Date.now() - t0) / 1000;
    const ev = new Evidence(page, {
      outDir: dir,
      project: 'evidence',
      // The mode is explicit (--real-services), so the run starts under that
      // mode's request policy from the first request (tool/e2e/policy.mjs).
      policy: cfg.mode,
      allowAi: cfg.allowAi,
    });
    await ev.install();
    if (cfg.cursor) await page.addInitScript(cursorInitScript);
    const pacer = new Pacer(page);
    let results = [];
    try {
      results = await runJourney(page, { pw, mode: cfg.mode, pacer, now, cfg });
    } catch (error) {
      failure = error;
      await page.screenshot({ path: join(dir, 'failure-state.png') }).catch(() => {});
    }
    const media = await ev.mediaCalls().catch(() => []);
    const report = ev.write({ mode: cfg.mode, getUserMedia: media });
    await page.close();
    raw = await page.video().path();
    await context.close();
    manifest.steps = results;
    manifest.pageErrors = report.pageErrors;
    manifest.forbiddenRequests = report.forbiddenRequests;
    manifest.externalHosts = report.externalHosts;
    if (!failure && cfg.mode === 'rehearsal') {
      if (report.forbiddenRequests.length) failure = new Error(`rehearsal contacted forbidden endpoints: ${report.forbiddenRequests.join(', ')}`);
      else if (media.length) failure = new Error('rehearsal opened the camera or microphone');
    }
  } finally {
    await browser.close();
  }

  let framePng;
  if (viewportName === 'phone') {
    framePng = join(cfg.outDir, 'phone-frame.png');
    const label = cfg.mode === 'rehearsal' ? 'Rehearsal build · AI, camera and messages simulated' : '';
    await renderJobs([{ out: framePng, html: phoneFrameHtml({ label }), transparent: true }]);
  }
  const reached = new Set(manifest.steps.map((s) => s.step));
  for (const step of JOURNEY_STEPS) {
    if (!reached.has(step)) manifest.steps.push({ step, status: failure ? 'not-reached' : 'absent', shows: '' });
  }
  if (!failure) {
    for (const s of manifest.steps.filter((x) => x.status === 'recorded')) {
      const out = join(dir, `${s.step}.mp4`);
      const ff = spawnSync(cfg.ffmpeg, clipFfmpegArgs({ raw, start: s.start, duration: s.end - s.start, viewport: viewportName, framePng, out }), { stdio: 'inherit' });
      if (ff.status !== 0) throw new Error(`ffmpeg failed cutting ${s.step}`);
      s.file = `${viewportName}/${s.step}.mp4`;
    }
  }
  manifest.ok = !failure;
  manifest.error = failure ? String(failure.message ?? failure) : null;
  writeFileSync(join(dir, 'manifest.json'), JSON.stringify(manifest, null, 2));
  if (!cfg.keepRaw && !failure) rmSync(rawDir, { recursive: true, force: true });
  return manifest;
}

async function main(argv) {
  let args;
  try {
    args = parseArgs(argv, {
      values: ['build-dir', 'base-url', 'out', 'viewports', 'port', 'pantry', 'recipe', 'question'],
      booleans: ['real-services', 'allow-ai', 'headed', 'no-cursor', 'keep-raw', 'help'],
    });
  } catch (error) {
    console.error(`${error.message}\n${USAGE}`);
    return 2;
  }
  if (args.help) {
    console.log(USAGE);
    return 0;
  }
  const { problems, config: cfg } = captureConfig(args);
  if (problems.length) {
    console.error(`capture.mjs:\n  ${problems.join('\n  ')}\n${USAGE}`);
    return 2;
  }
  cfg.ffmpeg = process.env.FFMPEG ?? 'ffmpeg';
  if (spawnSync(cfg.ffmpeg, ['-version'], { stdio: 'ignore' }).status !== 0) {
    console.error('ffmpeg not found (brew install ffmpeg, or set FFMPEG)');
    return 127;
  }
  if (!cfg.baseUrl && !existsSync(join(cfg.buildDir, 'index.html'))) {
    console.error(`No Flutter web build at ${cfg.buildDir}. Build one first:\n  ./tool/build_web.sh --dart-define=FAKE_BACKEND=true --no-web-resources-cdn`);
    return 2;
  }
  const pw = await loadPlaywright();
  let server;
  const baseURL = cfg.baseUrl ?? `http://localhost:${cfg.port}`;
  if (!cfg.baseUrl) server = await startServer(cfg.buildDir, cfg.port);
  let ok = true;
  try {
    for (const v of cfg.viewports) {
      console.log(`capturing ${v} (${cfg.mode}) from ${cfg.baseUrl ? 'the hosted build' : cfg.buildDir}`);
      const m = await captureViewport(pw, cfg, v, baseURL);
      for (const s of m.steps) console.log(`  ${s.status.padEnd(11)} ${s.step.padEnd(20)} ${s.shows}`);
      if (!m.ok) {
        ok = false;
        console.error(`  FAILED: ${m.error}`);
      }
    }
  } finally {
    server?.kill();
  }
  console.log(`clips and manifests: ${cfg.outDir}`);
  return ok ? 0 : 1;
}

if (import.meta.url === pathToFileURL(process.argv[1] ?? '').href) {
  main(process.argv.slice(2)).then(
    (code) => process.exit(code),
    (error) => {
      console.error(`capture.mjs: ${error.stack ?? error}`);
      process.exit(1);
    },
  );
}
