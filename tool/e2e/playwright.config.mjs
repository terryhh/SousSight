// Playwright config for the SousSight hero journey. Uses the INSTALLED Google
// Chrome (channel: 'chrome'); never downloads a browser. See README.md.
import { defineConfig } from '@playwright/test';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const repo = resolve(here, '..', '..');

// One output folder per run. run.sh sets E2E_OUT; when Playwright is run
// directly, the runner process sets it here once and workers inherit it.
if (!process.env.E2E_OUT) {
  const stamp = new Date().toISOString().replace(/[:.]/g, '-');
  process.env.E2E_OUT = join(here, 'out', stamp);
}

const port = Number(process.env.E2E_PORT ?? 8787);
// E2E_BASE_URL points at an already running build (e.g. a hosted URL); then
// no local server starts. Otherwise serve E2E_BUILD_DIR (default build/web).
const externalBase = process.env.E2E_BASE_URL;
const buildDir = resolve(repo, process.env.E2E_BUILD_DIR ?? 'build/web');
// localhost (not 127.0.0.1): Firebase Auth authorizes "localhost" by default.
const baseURL = externalBase ?? `http://localhost:${port}`;

const chromeArgs = [
  '--use-fake-device-for-media-stream',
  '--use-fake-ui-for-media-stream',
];

export default defineConfig({
  testDir: here,
  testMatch: /.*\.spec\.mjs/,
  outputDir: join(process.env.E2E_OUT, 'playwright'),
  timeout: 180_000,
  expect: { timeout: 20_000 },
  fullyParallel: false,
  workers: 1,
  retries: 0,
  reporter: [['list']],
  use: {
    baseURL,
    channel: 'chrome',
    headless: process.env.E2E_HEADED ? false : true,
    permissions: ['camera', 'microphone'],
    launchOptions: { args: chromeArgs },
    trace: 'retain-on-failure',
    screenshot: 'off',
  },
  projects: [
    {
      name: 'phone-412x915',
      use: { viewport: { width: 412, height: 915 }, hasTouch: false },
    },
    {
      name: 'desktop-1280x800',
      use: { viewport: { width: 1280, height: 800 } },
    },
  ],
  webServer: externalBase
    ? undefined
    : {
        command: `node "${join(here, 'serve.mjs')}" "${buildDir}" ${port}`,
        url: `http://localhost:${port}/index.html`,
        reuseExistingServer: false,
        timeout: 15_000,
        stdout: 'ignore',
        stderr: 'pipe',
      },
});
