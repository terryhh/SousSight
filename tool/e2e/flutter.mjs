// Helpers for driving a Flutter web (CanvasKit) app through its semantics
// tree, plus the journey's evidence recorder (screenshots, console, network).
import { expect } from '@playwright/test';
import { mkdirSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';

/// Hosts that serve model calls or paid/outbound actions. In a rehearsal
/// build any request to these fails the run; in a real build they are
/// aborted unless E2E_ALLOW_AI=1, so a run never spends model quota.
export const AI_HOST_PATTERNS = [
  /firebasevertexai\.googleapis\.com/,
  /generativelanguage\.googleapis\.com/,
  /aiplatform\.googleapis\.com/,
  /firebaseml\.googleapis\.com/,
  /\/api\/live-token/,
  /\/api\/dinner-ready/,
  /\/api\/vonage-status/,
  /(api|rest)\.nexmo\.com|api[\w.-]*\.vonage\.com/,
];

/// Usage analytics: always aborted, so automated runs never count as usage.
export const ANALYTICS_HOST_PATTERNS = [
  /google-analytics\.com|googletagmanager\.com|analytics\.google\.com/,
];

/// Firebase/Google backends a rehearsal build must never contact.
export const FIREBASE_HOST_PATTERNS = [
  /firestore\.googleapis\.com/,
  /identitytoolkit\.googleapis\.com/,
  /securetoken\.googleapis\.com/,
  /firebaseappcheck\.googleapis\.com/,
  /firebaseinstallations\.googleapis\.com/,
  /recaptcha/,
];

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

/// Whether [target] is fully inside the viewport, above [dockPx] of bottom
/// chrome (the cooking screen's control dock is about 130 px tall).
export async function inViewport(page, target, { dockPx = 0 } = {}) {
  const box = await target.boundingBox();
  if (!box) return false;
  const { height, width } = page.viewportSize();
  return (
    box.y >= 0 &&
    box.x >= 0 &&
    box.y + box.height <= height - dockPx &&
    box.x + box.width <= width
  );
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
/// console messages, uncaught errors and every non-local request.
export class Evidence {
  constructor(page, { outDir, project, mode }) {
    this.page = page;
    this.dir = join(outDir, project);
    this.project = project;
    this.mode = mode;
    this.step = 0;
    this.pageErrors = [];
    this.consoleErrors = [];
    this.console = [];
    this.external = new Map();
    this.blocked = [];
    this.forbidden = [];
    this.analytics = [];
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
      const key = url.host;
      this.external.set(key, (this.external.get(key) ?? 0) + 1);
    });
  }

  /// Network policy. Analytics is always aborted. Rehearsal: any Firebase or
  /// AI request is a failure (and is aborted). Real: AI requests are aborted
  /// unless allowed; Firebase Auth and Firestore go through.
  async guardNetwork({ allowAi }) {
    await this.page.route('**/*', async (route) => {
      const url = route.request().url();
      if (ANALYTICS_HOST_PATTERNS.some((p) => p.test(url))) {
        this.analytics.push(url);
        return route.abort('blockedbyclient');
      }
      const ai = AI_HOST_PATTERNS.some((p) => p.test(url));
      const firebase = FIREBASE_HOST_PATTERNS.some((p) => p.test(url));
      if (this.mode === 'rehearsal' && (ai || firebase)) {
        this.forbidden.push(url);
        return route.abort('blockedbyclient');
      }
      if (ai && !allowAi) {
        this.blocked.push(url);
        return route.abort('blockedbyclient');
      }
      return route.continue();
    });
  }

  /// Counts getUserMedia calls and the tracks they returned, so the report
  /// can say whether the camera was actually opened (e.g. briefly) even when
  /// no preview is ever painted.
  async instrumentMedia() {
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

  async mediaCalls() {
    return this.page.evaluate(() => window.__e2eMedia ?? []);
  }

  note(text) {
    this.notes.push(text);
  }

  /// Full-page screenshot named NN-<name>.png. Waits a beat so Flutter's
  /// implicit animations (sheets, ink splashes) settle first.
  async shot(name, { settleMs = 600 } = {}) {
    await this.page.waitForTimeout(settleMs);
    this.step += 1;
    const file = join(
      this.dir,
      `${String(this.step).padStart(2, '0')}-${name}.png`,
    );
    await this.page.screenshot({ path: file });
    return file;
  }

  write(extra = {}) {
    const report = {
      project: this.project,
      mode: this.mode,
      pageErrors: this.pageErrors,
      consoleErrors: this.consoleErrors,
      externalHosts: Object.fromEntries(this.external),
      abortedAiRequests: this.blocked,
      forbiddenRequests: this.forbidden,
      abortedAnalyticsRequests: this.analytics.length,
      notes: this.notes,
      ...extra,
    };
    writeFileSync(join(this.dir, 'report.json'), JSON.stringify(report, null, 2));
    writeFileSync(join(this.dir, 'console.log'), this.console.join('\n') + '\n');
    return report;
  }
}

/// Mean colour and the share of pixels that look like the empty camera
/// card's dark-green gradient, for a region of the current page. Decoded in
/// the browser, so the e2e package needs no image library.
export async function regionStats(page, box) {
  const png = await page.screenshot({ clip: box });
  return page.evaluate(async (b64) => {
    const blob = await (await fetch(`data:image/png;base64,${b64}`)).blob();
    const bitmap = await createImageBitmap(blob);
    const canvas = new OffscreenCanvas(bitmap.width, bitmap.height);
    const ctx = canvas.getContext('2d');
    ctx.drawImage(bitmap, 0, 0);
    const { data } = ctx.getImageData(0, 0, bitmap.width, bitmap.height);
    let r = 0;
    let g = 0;
    let bl = 0;
    let gradientLike = 0;
    const n = data.length / 4;
    for (let i = 0; i < data.length; i += 4) {
      r += data[i];
      g += data[i + 1];
      bl += data[i + 2];
      // The placeholder runs #214937 -> #102d24: dark, green-dominant.
      const dark = data[i] < 60 && data[i + 1] < 90 && data[i + 2] < 70;
      if (dark && data[i + 1] >= data[i] && data[i + 1] >= data[i + 2]) {
        gradientLike += 1;
      }
    }
    return {
      mean: [r / n, g / n, bl / n].map(Math.round),
      gradientShare: gradientLike / n,
    };
  }, png.toString('base64'));
}
