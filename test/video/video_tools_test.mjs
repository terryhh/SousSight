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
  VIEWPORT_SPECS,
  captureConfig,
  clipFfmpegArgs,
  escapeRegExp,
  typingDelays,
} from '../../tool/video/capture.mjs';

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
