// Helpers for driving a Flutter web (CanvasKit) app through its semantics
// tree, plus the journey's evidence recorder (screenshots, console, network).
import { expect } from '@playwright/test';
import { mkdirSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { decideRequest, pixelStats, refinePolicy } from './policy.mjs';

/// Turns Flutter's semantics tree on. Flutter web renders to a canvas and
/// only builds the accessible DOM after its hidden "Enable accessibility"
/// placeholder is activated.
export async function enableSemantics(page) {
  const placeholder = page.locator('flt-semantics-placeholder');
  await placeholder.waitFor({ state: 'attached', timeout: 60_000 });
  await placeholder.dispatchEvent('click');
  await expect(page.locator('flt-semantics').first()).toBeAttached();
}

/// Text as Flutter exposes it: either a text node or, when Flutter merges a
/// widget's text into its container, that container's aria-label.
export function seen(page, text) {
  return page.getByText(text).or(page.getByLabel(text)).first();
}

/// Scrolls Flutter's scroll view with the mouse wheel until [target] sits
/// in the upper part of the viewport (clear of the bottom control dock).
export async function bringIntoView(page, target, { top = 0.15, bottom = 0.6 } = {}) {
  const { height, width } = page.viewportSize();
  await page.mouse.move(width / 2, height / 3);
  for (let i = 0; i < 30; i += 1) {
    const box = await target.boundingBox();
    if (box) {
      const centre = box.y + box.height / 2;
      if (centre >= height * top && centre <= height * bottom) return;
      const delta = centre - height * ((top + bottom) / 2);
      await page.mouse.wheel(0, Math.max(-400, Math.min(400, delta)));
    } else {
      await page.mouse.wheel(0, 300);
    }
    await page.waitForTimeout(150);
  }
}

/// Whether [target] is fully inside the viewport.
export async function inViewport(page, target) {
  const box = await target.boundingBox();
  if (!box) return false;
  const { height, width } = page.viewportSize();
  return box.y >= 0 && box.x >= 0 && box.y + box.height <= height && box.x + box.width <= width;
}

/// Types into a Flutter text field with real key events. Flutter keeps its
/// own editing state, so a DOM-level fill() can be overwritten when the
/// field first takes focus; typing after focus settles is reliable.
export async function typeInto(page, field, text) {
  await field.click();
  await expect(field).toBeFocused();
  await page.waitForTimeout(300);
  await field.pressSequentially(text, { delay: 15 });
  await expect(field).toHaveValue(text);
}

/// Records everything the journey needs to report: per-step screenshots,
/// console messages, uncaught errors and every non-local request. Create it
/// and call [install] BEFORE the first navigation so the first load is
/// covered by the network policy and the evidence.
export class Evidence {
  constructor(page, { outDir, project, policy, allowAi }) {
    this.page = page;
    this.dir = join(outDir, project);
    this.project = project;
    this.policy = policy;
    this.allowAi = allowAi;
    this.step = 0;
    this.pageErrors = [];
    this.consoleErrors = [];
    this.provisionalConsoleErrors = [];
    this.console = [];
    this.external = new Map();
    this.abortedAi = [];
    this.provisionallyBlocked = [];
    this.forbidden = [];
    this.analytics = 0;
    this.notes = [];
    mkdirSync(this.dir, { recursive: true });

    page.on('pageerror', (error) =>
      this.pageErrors.push(`${error.name}: ${error.message}`),
    );
    page.on('console', (message) => {
      const line = `[${message.type()}] ${message.text()}`;
      this.console.push(line);
      if (message.type() === 'error') this.consoleErrors.push(message.text());
    });
    page.on('request', (request) => {
      const url = new URL(request.url());
      if (url.hostname === 'localhost' || url.hostname === '127.0.0.1') return;
      if (url.protocol === 'data:' || url.protocol === 'blob:') return;
      this.external.set(url.host, (this.external.get(url.host) ?? 0) + 1);
    });
  }

  /// Network guard and getUserMedia instrumentation. The guard reads
  /// [policy] on every request, so [refine] takes effect immediately.
  async install() {
    await this.page.route('**/*', async (route) => {
      const url = route.request().url();
      const decision = decideRequest(url, this.policy, { allowAi: this.allowAi });
      if (decision.action === 'allow') return route.continue();
      if (decision.kind === 'analytics') this.analytics += 1;
      else if (decision.forbidden) this.forbidden.push(url);
      else if (this.policy === 'provisional') this.provisionallyBlocked.push(url);
      else this.abortedAi.push(url);
      return route.abort('blockedbyclient');
    });
    await this.page.addInitScript(() => {
      const log = [];
      window.__e2eMedia = log;
      const md = navigator.mediaDevices;
      if (!md || !md.getUserMedia) return;
      const original = md.getUserMedia.bind(md);
      md.getUserMedia = async (constraints) => {
        const entry = {
          at: Math.round(performance.now()),
          video: Boolean(constraints && constraints.video),
          audio: Boolean(constraints && constraints.audio),
        };
        log.push(entry);
        try {
          const stream = await original(constraints);
          entry.tracks = stream.getTracks().map((t) => t.kind);
          return stream;
        } catch (error) {
          entry.error = String(error && error.name);
          throw error;
        }
      };
    });
  }

  /// Leaves the provisional policy for the detected [mode] (refinePolicy in
  /// policy.mjs). Returns whether the page must be reloaded.
  refine(mode) {
    const next = refinePolicy(this.policy, mode, this.provisionallyBlocked);
    this.forbidden.push(...next.forbidden);
    this.policy = next.policy;
    return next.reload;
  }

  /// Before reloading a real build that loaded under the provisional
  /// policy: the console errors so far were caused by that blocking, so they
  /// are kept in the report but no longer fail the run.
  setAsideProvisionalErrors() {
    this.provisionalConsoleErrors.push(...this.consoleErrors.splice(0));
  }

  async mediaCalls() {
    return this.page.evaluate(() => window.__e2eMedia ?? []);
  }

  note(text) {
    this.notes.push(text);
  }

  /// Screenshot named NN-<name>.png. Waits a beat so Flutter's implicit
  /// animations (sheets, ink splashes) settle first.
  async shot(name, { settleMs = 600 } = {}) {
    await this.page.waitForTimeout(settleMs);
    this.step += 1;
    const file = join(this.dir, `${String(this.step).padStart(2, '0')}-${name}.png`);
    await this.page.screenshot({ path: file });
    return file;
  }

  write(extra = {}) {
    const report = {
      project: this.project,
      policy: this.policy,
      pageErrors: this.pageErrors,
      consoleErrors: this.consoleErrors,
      provisionalConsoleErrors: this.provisionalConsoleErrors,
      externalHosts: Object.fromEntries(this.external),
      abortedAiRequests: this.abortedAi,
      provisionallyBlockedRequests: this.provisionallyBlocked,
      forbiddenRequests: this.forbidden,
      abortedAnalyticsRequests: this.analytics,
      notes: this.notes,
      ...extra,
    };
    writeFileSync(join(this.dir, 'report.json'), JSON.stringify(report, null, 2));
    writeFileSync(join(this.dir, 'console.log'), this.console.join('\n') + '\n');
    return report;
  }
}

/// pixelStats() (policy.mjs) for a region of the current page, decoded in
/// the browser so the e2e package needs no image library.
export async function regionStats(page, box) {
  const png = await page.screenshot({ clip: box });
  return page.evaluate(
    async ([b64, statsSource]) => {
      const stats = new Function(`return (${statsSource})`)();
      const blob = await (await fetch(`data:image/png;base64,${b64}`)).blob();
      const bitmap = await createImageBitmap(blob);
      const canvas = new OffscreenCanvas(bitmap.width, bitmap.height);
      const ctx = canvas.getContext('2d');
      ctx.drawImage(bitmap, 0, 0);
      return stats(ctx.getImageData(0, 0, bitmap.width, bitmap.height).data);
    },
    [png.toString('base64'), pixelStats.toString()],
  );
}
