// Unit tests for the demo-video tools' pure parts: title/caption/placeholder
// HTML (titles.mjs), capture options and ffmpeg arguments (capture.mjs) and
// the shared argument parser. No browser, ffmpeg or network:
//   node --test test/video/
import assert from 'node:assert/strict';
import { existsSync, mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { describe, test } from 'node:test';
import { fileURLToPath } from 'node:url';

import { BRAND, JOURNEY_STEPS, PHONE_SCREEN, VIEWPORTS, parseArgs } from '../../tool/video/common.mjs';
import {
  captionHtml,
  cardJobsForEdl,
  contactSheetHtml,
  escapeHtml,
  phoneFrameHtml,
  placeholderHtml,
  titleCardHtml,
} from '../../tool/video/titles.mjs';
import {
  PANTRY,
  QUESTION,
  RECIPE,
  VIDEO_COPY,
  VIEWPORT_SPECS,
  captureConfig,
  classifyCoachLiteReply,
  clipFfmpegArgs,
  coachLiteAnswerResult,
  coachLiteLocators,
  escapeRegExp,
  sourceBadgeFinished,
  typingDelays,
  watchUnsureResult,
} from '../../tool/video/capture.mjs';
import { COPY } from '../../tool/e2e/copy.mjs';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..', '..');
const sample = JSON.parse(readFileSync(join(root, 'tool/video/edl.json'), 'utf8'));

describe('titles.mjs HTML', () => {
  test('escapes markup', () => {
    assert.equal(escapeHtml(`<b a="1">'&'</b>`), '&lt;b a=&quot;1&quot;&gt;&#39;&amp;&#39;&lt;/b&gt;');
    assert.equal(escapeHtml(undefined), '');
  });

  test('title card: brand palette, 1920x1080, system sans, escaped text', () => {
    const html = titleCardHtml({ text: 'Wi-Fi off. <Still> cooking.', sub: 'On-device & calm' });
    assert.match(html, /width:1920px;height:1080px/);
    for (const colour of [BRAND.forest, BRAND.forestDeep, BRAND.terracotta, BRAND.cream, BRAND.paper, BRAND.gold]) {
      assert.ok(html.includes(colour), `uses ${colour}`);
    }
    assert.match(html, /-apple-system, BlinkMacSystemFont/);
    assert.ok(html.includes('Wi-Fi off. &lt;Still&gt; cooking.'));
    assert.ok(html.includes('On-device &amp; calm'));
    assert.ok(!html.includes('<Still>'));
    assert.match(html, /SousSight/);
  });

  test('title card without a sub line has no paragraph', () => {
    assert.ok(!titleCardHtml({ text: 'Hello' }).includes('<p>'));
  });

  test('title card and caption need text', () => {
    assert.throws(() => titleCardHtml({ text: '  ' }), /needs text/);
    assert.throws(() => titleCardHtml({}), /needs text/);
    assert.throws(() => captionHtml(''), /needs text/);
  });

  test('caption is a transparent lower-third overlay', () => {
    const html = captionHtml('The badge says where it ran');
    assert.match(html, /background:transparent/);
    assert.match(html, /bottom:56px/);
    assert.ok(html.includes('The badge says where it ran'));
  });

  test('terry placeholder names the slot and the instructions, and says it is not footage', () => {
    const html = placeholderHtml({ kind: 'terry', slot: 'T04-watch-unsure', instructions: 'Hand over the bowl', durationS: 14 });
    assert.ok(html.includes('Terry clip: T04-watch-unsure'));
    assert.ok(html.includes('— Hand over the bowl'));
    assert.ok(html.includes('Placeholder — not app footage'));
    assert.ok(html.includes('14.0 s'));
  });

  test('capture placeholder explains why it is there', () => {
    const html = placeholderHtml({ kind: 'capture', slot: 'ledger (desktop)' });
    assert.ok(html.includes('Capture missing: ledger (desktop)'));
    assert.match(html, /did not show this step/);
    assert.ok(!html.includes(' s</div>'));
  });

  test('placeholder rejects unknown kinds and empty slots', () => {
    assert.throws(() => placeholderHtml({ kind: 'ai', slot: 'x' }), /unknown placeholder kind/);
    assert.throws(() => placeholderHtml({ kind: 'terry', slot: '' }), /needs a slot/);
  });

  test('phone frame cuts a hole exactly where capture.mjs places the screen', () => {
    const html = phoneFrameHtml({ label: 'Rehearsal build' });
    const s = PHONE_SCREEN;
    assert.ok(html.includes(`left:${s.x}px;top:${s.y}px;width:${s.width}px;height:${s.height}px`));
    assert.match(html, /background:transparent/);
    assert.ok(html.includes('Rehearsal build'));
    assert.ok(!phoneFrameHtml().includes('class="label"'));
    // 412x915 scaled to the screen keeps the aspect ratio within a pixel.
    assert.ok(Math.abs((412 / 915) * s.height - s.width) < 1);
    assert.equal(s.x * 2 + s.width, 1920);
  });

  test('contact sheet lists every frame with its label', () => {
    const html = contactSheetHtml([
      { src: 'data:image/png;base64,AAA', label: 's01 · 0:00.0', detail: 'terry <clip>' },
      { src: 'data:image/png;base64,BBB', label: 's02', detail: '' },
    ], { columns: 3, title: 'Draft' });
    assert.equal((html.match(/<figure>/g) ?? []).length, 2);
    assert.match(html, /repeat\(3,1fr\)/);
    assert.ok(html.includes('terry &lt;clip&gt;'));
    assert.ok(html.includes('<h1>Draft</h1>'));
  });

  test('card jobs for the shipped EDL: one per title, terry/capture placeholder and caption', () => {
    const jobs = cardJobsForEdl(sample, '/cards');
    const names = jobs.map((j) => j.out.replace('/cards/', ''));
    assert.ok(names.includes('phone-frame.png'));
    assert.ok(names.includes('phone-frame-rehearsal.png'));
    for (const seg of sample) {
      if (seg.source === 'title') assert.ok(names.includes(`title-${seg.id}.png`), seg.id);
      else assert.ok(names.includes(`placeholder-${seg.id}.png`), seg.id);
      assert.equal(names.includes(`caption-${seg.id}.png`), Boolean(seg.caption), seg.id);
    }
    for (const j of jobs.filter((x) => /caption-|phone-frame/.test(x.out))) assert.equal(j.transparent, true);
    assert.equal(new Set(names).size, names.length);
  });

  test('card jobs refuse unsafe ids and non-arrays', () => {
    assert.throws(() => cardJobsForEdl([{ id: '../x', source: 'title', title: { text: 'a' } }], '/c'), /bad segment id/);
    assert.throws(() => cardJobsForEdl({}, '/c'), /array/);
  });
});

describe('capture.mjs', () => {
  test('journey steps and viewports are the card\'s', () => {
    assert.deepEqual(JOURNEY_STEPS, ['home', 'type-list', 'find-meal', 'result-badge', 'open-recipe', 'cooking-screen',
      'coach-lite-question', 'coach-lite-answer', 'watch-start', 'watch-unsure', 'ledger', 'on-device-sheet', 'how-it-works']);
    assert.deepEqual(VIEWPORTS, ['desktop', 'phone']);
    assert.deepEqual(VIEWPORT_SPECS.desktop.video, { width: 1920, height: 1080 });
    assert.deepEqual(VIEWPORT_SPECS.phone.viewport, { width: 412, height: 915 });
  });

  test('defaults to a local rehearsal build, both viewports', () => {
    const { problems, config } = captureConfig({});
    assert.deepEqual(problems, []);
    assert.equal(config.mode, 'rehearsal');
    assert.equal(config.baseUrl, null);
    assert.deepEqual(config.viewports, ['desktop', 'phone']);
    assert.ok(config.buildDir.endsWith(join('build', 'web')));
    assert.ok(config.outDir.endsWith(join('build', 'video', 'capture')));
    assert.equal(config.allowAi, false);
    assert.equal(config.cursor, true);
  });

  test('a hosted build needs the explicit --real-services flag', () => {
    const { problems } = captureConfig({ 'base-url': 'https://example.web.app' });
    assert.ok(problems.some((p) => p.includes('--real-services')));
    const ok = captureConfig({ 'base-url': 'https://example.web.app', 'real-services': true });
    assert.deepEqual(ok.problems, []);
    assert.equal(ok.config.mode, 'real');
  });

  test('--allow-ai only with real services; URLs must be clean https', () => {
    assert.ok(captureConfig({ 'allow-ai': true }).problems.some((p) => p.includes('--allow-ai')));
    const bad = [
      'http://example.com',
      'https://user:pw@example.web.app',
      'https://example.web.app/?token=abc',
      'not a url',
    ];
    for (const url of bad) {
      assert.ok(captureConfig({ 'base-url': url, 'real-services': true }).problems.length > 0, url);
    }
    assert.deepEqual(captureConfig({ 'base-url': 'http://localhost:5000', 'real-services': true }).problems, []);
    assert.ok(captureConfig({ 'base-url': 'https://a.app', 'real-services': true, 'build-dir': 'x' }).problems.length);
  });

  test('journey text defaults match the rehearsal result and can follow the script', () => {
    const { config } = captureConfig({});
    assert.deepEqual([config.pantry, config.recipe, config.question], [PANTRY, RECIPE, QUESTION]);
    assert.equal(RECIPE, 'Peanut Butter Sandwich');
    const custom = captureConfig({ pantry: 'canned chickpeas, lemon', recipe: 'Smashed Chickpea Salad Wrap', question: 'How smooth?' });
    assert.deepEqual(custom.problems, []);
    assert.equal(custom.config.recipe, 'Smashed Chickpea Salad Wrap');
    assert.ok(captureConfig({ recipe: '  ' }).problems.some((p) => p.includes('--recipe')));
    assert.ok(captureConfig({ question: 'x'.repeat(201) }).problems.some((p) => p.includes('too long')));
  });

  test('recipe names are matched literally', () => {
    const re = new RegExp(`^Cook ${escapeRegExp('Mac (and) cheese?')}`);
    assert.ok(re.test('Cook Mac (and) cheese? now'));
    assert.ok(!re.test('Cook Mac and cheese'));
  });

  test('viewport and port checks', () => {
    assert.ok(captureConfig({ viewports: 'tablet' }).problems.some((p) => p.includes('tablet')));
    assert.ok(captureConfig({ viewports: ',' }).problems.some((p) => p.includes('no viewports')));
    assert.deepEqual(captureConfig({ viewports: 'phone' }).config.viewports, ['phone']);
    assert.ok(captureConfig({ port: '80' }).problems.length);
    assert.ok(captureConfig({ port: 'abc' }).problems.length);
  });

  test('desktop clip: cut, 1080p30 H.264, no audio', () => {
    const args = clipFfmpegArgs({ raw: 'r.webm', start: 1.23456, duration: 4.5, viewport: 'desktop', out: 'o.mp4' });
    assert.deepEqual(args.slice(args.indexOf('-ss'), args.indexOf('-ss') + 4), ['-ss', '1.235', '-i', 'r.webm']);
    assert.match(args[args.indexOf('-vf') + 1], /scale=1920:1080/);
    assert.equal(args[args.indexOf('-t') + 1], '4.500');
    for (const flag of ['-an', 'libx264', 'yuv420p']) assert.ok(args.includes(flag), flag);
    assert.equal(args.at(-1), 'o.mp4');
  });

  test('phone clip: screen scaled into the frame on a 1080p canvas', () => {
    const args = clipFfmpegArgs({ raw: 'r.webm', start: 0, duration: 2, viewport: 'phone', framePng: 'f.png', out: 'o.mp4' });
    const graph = args[args.indexOf('-filter_complex') + 1];
    assert.ok(graph.includes(`scale=${PHONE_SCREEN.width}:${PHONE_SCREEN.height}`));
    assert.ok(graph.includes(`overlay=${PHONE_SCREEN.x}:${PHONE_SCREEN.y}`));
    assert.ok(graph.includes('s=1920x1080'));
    assert.deepEqual(args.slice(args.indexOf('-loop'), args.indexOf('-loop') + 4), ['-loop', '1', '-i', 'f.png']);
    assert.throws(() => clipFfmpegArgs({ raw: 'r', start: 0, duration: 2, viewport: 'phone', out: 'o' }), /frame PNG/);
  });

  test('clip arguments reject bad durations and viewports', () => {
    assert.throws(() => clipFfmpegArgs({ raw: 'r', start: 0, duration: 0, viewport: 'desktop', out: 'o' }), /positive/);
    assert.throws(() => clipFfmpegArgs({ raw: 'r', start: 0, duration: 1, viewport: 'tv', out: 'o' }), /unknown viewport/);
  });

  test('typing delays are human-paced and deterministic', () => {
    const delays = typingDelays('bread, peanut butter');
    assert.equal(delays.length, 20);
    assert.ok(delays.every((d) => d >= 55 && d <= 195));
    assert.deepEqual(delays, typingDelays('bread, peanut butter'));
    assert.ok(delays[5] >= 125, 'pause after a comma');
    assert.ok(new Set(delays).size > 5, 'not robotic');
  });
});

// An inert stand-in for a Playwright page: a fixed list of semantics nodes
// ({ role, name, text }) that locators match the way Playwright does
// (regex test, or case-insensitive substring). Nodes can be added later to
// model a reply arriving.
class FakePage {
  constructor(nodes = []) {
    this.nodes = [...nodes];
  }
  add(node, afterMs = 0) {
    setTimeout(() => this.nodes.push(node), afterMs);
  }
  getByText(pattern) {
    return new FakeLocator(this, (n) => matches(pattern, n.text));
  }
  getByLabel(pattern) {
    return new FakeLocator(this, (n) => matches(pattern, n.name));
  }
  getByRole(role, { name } = {}) {
    return new FakeLocator(this, (n) => n.role === role && (name === undefined || matches(name, n.name)));
  }
}

function matches(pattern, value) {
  if (value == null) return false;
  return pattern instanceof RegExp ? pattern.test(value) : value.toLowerCase().includes(String(pattern).toLowerCase());
}

class FakeLocator {
  constructor(page, match, index = null) {
    Object.assign(this, { page, match, index });
  }
  node() {
    return this.page.nodes.filter(this.match)[this.index ?? 0];
  }
  first() {
    return new FakeLocator(this.page, this.match, 0);
  }
  nth(i) {
    return new FakeLocator(this.page, this.match, i);
  }
  or(other) {
    return new FakeLocator(this.page, (n) => this.match(n) || other.match(n));
  }
  async count() {
    return this.page.nodes.filter(this.match).length;
  }
  async isVisible() {
    return Boolean(this.node());
  }
  async getAttribute(attr) {
    return attr === 'aria-label' ? (this.node()?.name ?? null) : null;
  }
  async textContent() {
    return this.node()?.text ?? null;
  }
  async waitFor({ timeout = 30_000 } = {}) {
    const end = Date.now() + timeout;
    while (!this.node()) {
      if (Date.now() > end) throw new Error(`timeout ${timeout} ms`);
      await new Promise((r) => setTimeout(r, 2));
    }
  }
}

// Same shape as tool/e2e/flutter.mjs seen().
const seen = (page, text) => page.getByText(text).or(page.getByLabel(text)).first();
const badge = (legs) => ({ role: 'button', name: `Where this ran: ${legs}. Tap for details.` });
// The cooking screen's always-present controls, including the cook's own
// prediction chips ("Not sure" is not a watch verdict).
const cookingScreen = () => [
  { text: 'Your cooking space' },
  { text: 'Peanut Butter Sandwich' },
  { text: 'How does your food look?' },
  ...['Ready', 'Not yet', 'Not sure'].map((p) => ({ role: 'button', name: p, text: p })),
];

describe('capture.mjs evidence: a step counts only when its own UI state is asserted', () => {
  const classify = (page, badgesBefore = 0, timeout = 40) =>
    classifyCoachLiteReply(coachLiteLocators(page, seen), { badgesBefore, timeout });

  test('uses the shared app copy from tool/e2e/copy.mjs', () => {
    const source = readFileSync(join(root, 'tool/video/capture.mjs'), 'utf8');
    assert.match(source, /from '\.\.\/e2e\/copy\.mjs'/);
    assert.doesNotMatch(source, /Rehearsal mode ·|'What was sent'|'On-device AI'|'Find my meal'/);
    assert.ok(COPY.rehearsalBanner.test('Practice mode (pretend answers) · nothing is sent'));
  });

  test('source badge: only a finished last leg is an answer', () => {
    assert.equal(sourceBadgeFinished(badge('Simulated').name), true);
    assert.equal(sourceBadgeFinished(badge('On this device · Gemini Nano').name), true);
    assert.equal(sourceBadgeFinished(badge('Cloud · Gemini').name), true);
    assert.equal(sourceBadgeFinished(badge('On this device (model not available); Cloud · Gemini').name), true);
    assert.equal(sourceBadgeFinished(badge("Didn't finish · nothing left this device").name), false);
    assert.equal(sourceBadgeFinished(badge('May have been sent').name), false);
    assert.equal(sourceBadgeFinished(badge('On this device (took too long)').name), false);
    assert.equal(sourceBadgeFinished(badge('Cloud · Gemini; Cloud (connection problem)').name), false);
    assert.equal(sourceBadgeFinished('Where this ran: Simulated'), false);
    assert.equal(sourceBadgeFinished(null), false);
  });

  test('regression: a failed-call badge is not an answer', async () => {
    // CoachLite keeps a failed attempt's legs, so the footer badge renders
    // even though no model answered (PR #225 review).
    const page = new FakePage([...cookingScreen(), badge("Didn't finish · nothing left this device")]);
    const reply = await classify(page);
    assert.equal(reply.outcome, 'failed');
    const result = coachLiteAnswerResult(reply);
    assert.equal(result.status, 'recorded');
    assert.equal(result.outcome, 'failed');
    assert.doesNotMatch(result.shows, /answer with/);
    assert.match(result.shows, /did not answer/);
  });

  test('a badge beside a fallback note is a failure or refusal, not an answer', async () => {
    const failed = new FakePage([...cookingScreen(), badge('On this device (model not available)'),
      { text: 'The on-device coach could not answer.\nSpread the peanut butter.' }]);
    assert.equal((await classify(failed)).outcome, 'failed');
    const invalid = new FakePage([...cookingScreen(), badge('On this device'),
      { text: "The on-device coach's answer could not be shown.\nSpread the peanut butter." }]);
    assert.equal((await classify(invalid)).outcome, 'failed');
    const blocked = new FakePage([...cookingScreen(), badge("Didn't finish · nothing left this device"),
      { text: "This device can't run the on-device coach right now.\nSpread the peanut butter." }]);
    const reply = await classify(blocked);
    assert.equal(reply.outcome, 'blocked');
    assert.match(coachLiteAnswerResult(reply).shows, /unavailable on this device: .*can't run the on-device coach/);
  });

  test('an unknown cloud outcome is not an answer', async () => {
    assert.equal((await classify(new FakePage([badge('May have been sent')]))).outcome, 'failed');
  });

  test('a finished answer arriving after the question is recorded with its badge', async () => {
    const page = new FakePage(cookingScreen());
    page.add(badge('Simulated'), 10);
    const reply = await classify(page, 0, 500);
    assert.equal(reply.outcome, 'answered');
    const result = coachLiteAnswerResult(reply);
    assert.deepEqual([result.status, result.outcome], ['recorded', 'answered']);
    assert.match(result.shows, /Simulated/);
  });

  test('a badge already on screen before the question is never the answer', async () => {
    // e.g. a watch verdict's badge: unrelated to the question.
    const page = new FakePage([...cookingScreen(), badge('On this device')]);
    const reply = await classify(page, 1);
    assert.equal(reply.outcome, 'none');
    const result = coachLiteAnswerResult(reply, { badgesBefore: 1 });
    assert.equal(result.status, 'absent');
    assert.match(result.shows, /already on screen/);
  });

  test('consent, live alert and silence keep their own classification', async () => {
    const consent = new FakePage([{ role: 'button', name: "Don't send", text: "Don't send" }]);
    assert.equal((await classify(consent)).outcome, 'consent');
    const live = new FakePage([{ text: 'Connect the live coach to talk or type a question.' }]);
    assert.equal((await classify(live)).outcome, 'live-alert');
    const silent = await classify(new FakePage(cookingScreen()));
    assert.equal(silent.outcome, 'none');
    assert.equal(coachLiteAnswerResult(silent).status, 'absent');
    assert.throws(() => coachLiteAnswerResult({ outcome: 'bogus' }), /unknown Coach Lite outcome/);
  });

  test('regression: the cook\'s "Not sure" chip is not an unsure watch verdict', async () => {
    // Inert-locator probe from the PR #225 review: only the prediction
    // choices and a running watch are on screen.
    const page = new FakePage([...cookingScreen(), { text: 'Watching for the cue' }]);
    const result = await watchUnsureResult('preview', seen(page, VIDEO_COPY.watchUnsure), { timeout: 40 });
    assert.deepEqual([result.status, result.outcome], ['absent', 'no-verdict']);
    for (const chip of ['Ready', 'Not yet', 'Not sure', 'How does your food look?']) {
      assert.doesNotMatch(chip, VIDEO_COPY.watchUnsure);
    }
  });

  test('the watch\'s own unsure verdict is recorded; no watch means no verdict', async () => {
    const overlay = new FakePage([...cookingScreen(),
      { name: 'Move the pan or bowl into view\nClear steam or hands, or add some light.' }]);
    const result = await watchUnsureResult('preview', seen(overlay, VIDEO_COPY.watchUnsure), { timeout: 40 });
    assert.deepEqual([result.status, result.outcome], ['recorded', 'unsure']);
    assert.match(result.shows, /Move the pan or bowl into view/);
    const notice = new FakePage([{ text: "I can't see it clearly. Move the camera closer, clear steam or hands from view, or add light." }]);
    assert.equal((await watchUnsureResult('preview', seen(notice, VIDEO_COPY.watchUnsure), { timeout: 40 })).status, 'recorded');
    const refused = await watchUnsureResult('refused', seen(overlay, VIDEO_COPY.watchUnsure), { timeout: 40 });
    assert.deepEqual([refused.status, refused.outcome], ['absent', 'no-watch']);
  });
});

describe('parseArgs', () => {
  test('values, inline values and switches', () => {
    assert.deepEqual(parseArgs(['--out', 'x', '--edl=e.json', '--headed'], { values: ['out', 'edl'], booleans: ['headed'] }), {
      out: 'x',
      edl: 'e.json',
      headed: true,
    });
  });

  test('errors', () => {
    assert.throws(() => parseArgs(['--nope'], {}), /unknown option/);
    assert.throws(() => parseArgs(['stray'], {}), /unexpected argument/);
    assert.throws(() => parseArgs(['--out'], { values: ['out'] }), /needs a value/);
    assert.throws(() => parseArgs(['--out', '--x'], { values: ['out'] }), /needs a value/);
    assert.throws(() => parseArgs(['--headed=1'], { booleans: ['headed'] }), /takes no value/);
  });
});

// Renders real PNGs with the installed Chrome when tool/e2e's Playwright is
// installed; skipped otherwise (CI without a browser).
const havePlaywright = existsSync(join(root, 'tool/e2e/node_modules/@playwright/test/package.json'));

function pngSize(path) {
  const b = readFileSync(path);
  assert.equal(b.toString('latin1', 1, 4), 'PNG', `${path} is a PNG`);
  return [b.readUInt32BE(16), b.readUInt32BE(20)];
}

describe('titles.mjs rendering (installed Chrome)', { skip: !havePlaywright && 'tool/e2e Playwright not installed' }, () => {
  test('renders every card for an EDL at 1920x1080, and a contact sheet', () => {
    const dir = mkdtempSync(join(tmpdir(), 'ss-titles-'));
    try {
      const edl = join(dir, 'edl.json');
      writeFileSync(edl, JSON.stringify([
        { id: 'a', source: 'title', duration_s: 3, title: { text: 'SousSight', sub: 'Counter Intelligence' }, caption: 'Hi' },
        { id: 'b', source: 'terry', duration_s: 3, terry_clip: 'T01-x', terry_instructions: 'Film the counter.' },
      ]));
      const cards = join(dir, 'cards');
      const run = spawnSync(process.execPath, [join(root, 'tool/video/titles.mjs'), '--edl', edl, '--out', cards], { encoding: 'utf8' });
      assert.equal(run.status, 0, run.stderr);
      assert.deepEqual(readdirSync(cards).sort(), ['caption-a.png', 'phone-frame-rehearsal.png', 'phone-frame.png', 'placeholder-b.png', 'title-a.png']);
      for (const name of readdirSync(cards)) assert.deepEqual(pngSize(join(cards, name)), [1920, 1080], name);

      const frames = join(dir, 'frames.json');
      writeFileSync(frames, JSON.stringify([{ image: join(cards, 'title-a.png'), label: 'a', detail: 'title' }]));
      const sheet = join(dir, 'sheet.png');
      const run2 = spawnSync(process.execPath, [join(root, 'tool/video/titles.mjs'), '--contact-sheet', frames, '--out', sheet, '--title', 'T'], { encoding: 'utf8' });
      assert.equal(run2.status, 0, run2.stderr);
      assert.equal(pngSize(sheet)[0], 1920);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test('CLI errors are reported, not thrown', () => {
    const run = spawnSync(process.execPath, [join(root, 'tool/video/titles.mjs'), '--out', '/tmp/x'], { encoding: 'utf8' });
    assert.equal(run.status, 1);
    assert.match(run.stderr, /--edl or --contact-sheet is required/);
    const run2 = spawnSync(process.execPath, [join(root, 'tool/video/titles.mjs')], { encoding: 'utf8' });
    assert.match(run2.stderr, /--out is required/);
  });
});

describe('capture.mjs CLI (no browser)', () => {
  const cli = (args) => spawnSync(process.execPath, [join(root, 'tool/video/capture.mjs'), ...args], { encoding: 'utf8' });

  test('refuses a hosted build without --real-services before launching anything', () => {
    const run = cli(['--base-url', 'https://example.web.app']);
    assert.equal(run.status, 2);
    assert.match(run.stderr, /add --real-services to confirm/);
  });

  test('bad options exit 2 with usage; --help exits 0', () => {
    assert.equal(cli(['--bogus']).status, 2);
    const help = cli(['--help']);
    assert.equal(help.status, 0);
    assert.match(help.stdout, /usage: node tool\/video\/capture.mjs/);
  });

  test('a missing build directory is explained', () => {
    const run = cli(['--build-dir', 'build/does-not-exist']);
    assert.ok([2, 127].includes(run.status), run.stderr);
    assert.match(run.stderr, /No Flutter web build|ffmpeg not found/);
  });
});
