// Shared constants and helpers for the demo-video tools (capture.mjs,
// titles.mjs). Pure except for loadPlaywright(), which imports the pinned
// Playwright that tool/e2e installs (the video tools add no dependency).
import { readFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

export const VIDEO_DIR = dirname(fileURLToPath(import.meta.url));
export const REPO = resolve(VIDEO_DIR, '..', '..');
export const E2E_DIR = join(REPO, 'tool', 'e2e');

const journey = JSON.parse(readFileSync(join(VIDEO_DIR, 'journey_steps.json'), 'utf8'));
export const JOURNEY_STEPS = Object.freeze([...journey.steps]);
export const VIEWPORTS = Object.freeze([...journey.viewports]);

/// Brand palette (matches the app's theme).
export const BRAND = Object.freeze({
  forest: '#285b43',
  forestDeep: '#143a2b',
  terracotta: '#bf5b32',
  cream: '#fffdf8',
  paper: '#f5f1e8',
  gold: '#e9a23b',
  ink: '#1d2a23',
});

export const FONT_STACK =
  "-apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, 'Helvetica Neue', Arial, sans-serif";

export const CANVAS = Object.freeze({ width: 1920, height: 1080 });

/// Where the phone screen sits on the 1080p canvas. The 412x915 viewport is
/// scaled to 960 px tall (432 px wide) and centred; the frame PNG from
/// titles.mjs draws a bezel around exactly this rectangle.
export const PHONE_SCREEN = Object.freeze({ x: 744, y: 60, width: 432, height: 960, radius: 34 });

/// The Playwright module that tool/e2e pins (resolved from tool/e2e so the
/// video tools reuse its install). Throws a helpful error when missing.
export async function loadPlaywright() {
  const require = createRequire(join(E2E_DIR, 'package.json'));
  let entry;
  try {
    // The ESM entry, so this is the same module instance tool/e2e's helpers import.
    entry = join(dirname(require.resolve('@playwright/test/package.json')), 'index.mjs');
  } catch {
    throw new Error(
      'Playwright is not installed for tool/e2e. Run: (cd tool/e2e && PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1 npm ci)',
    );
  }
  return import(pathToFileURL(entry).href);
}

/// Parses `--flag value` / `--flag=value` / `--switch` arguments. [booleans]
/// lists the switches that take no value. Unknown flags are errors.
export function parseArgs(argv, { values = [], booleans = [] } = {}) {
  const out = {};
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (!arg.startsWith('--')) throw new Error(`unexpected argument: ${arg}`);
    const [name, inline] = arg.slice(2).split(/=(.*)/s, 2);
    if (booleans.includes(name)) {
      if (inline !== undefined) throw new Error(`--${name} takes no value`);
      out[name] = true;
    } else if (values.includes(name)) {
      const value = inline ?? argv[(i += 1)];
      if (value === undefined || value.startsWith('--')) throw new Error(`--${name} needs a value`);
      out[name] = value;
    } else {
      throw new Error(`unknown option: --${name}`);
    }
  }
  return out;
}
