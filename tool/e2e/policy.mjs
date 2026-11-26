// Pure rules for the hero journey: which requests a run may make, and what
// counts as a camera preview. No Playwright imports, so the unit tests in
// test/e2e/ run with plain `node --test`.

/// Model calls and paid or outbound actions.
export const AI_PATTERNS = [
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
export const ANALYTICS_PATTERNS = [
  /google-analytics\.com|googletagmanager\.com|analytics\.google\.com/,
];

/// Firebase backends a rehearsal build must never contact.
export const FIREBASE_PATTERNS = [
  /firestore\.googleapis\.com/,
  /identitytoolkit\.googleapis\.com/,
  /securetoken\.googleapis\.com/,
  /firebaseappcheck\.googleapis\.com/,
  /firebaseinstallations\.googleapis\.com/,
  /firebase\.googleapis\.com/,
  /recaptcha/,
];

export const POLICIES = ['provisional', 'rehearsal', 'real'];

/// What to do with one request.
///
/// - `provisional`: the build's mode is not known yet (first load in
///   `E2E_MODE=auto`). Everything a rehearsal may not touch is blocked, but
///   blocking is not yet a failure: if the build turns out to be real, those
///   requests were expected and the page is reloaded with the real policy.
/// - `rehearsal`: Firebase and AI requests are blocked AND fail the run.
/// - `real`: AI requests are blocked unless [allowAi]; Firebase goes through.
///
/// Analytics is aborted under every policy. Returns
/// `{ action: 'allow' | 'abort', kind: 'analytics' | 'ai' | 'firebase' | 'other', forbidden: boolean }`.
export function decideRequest(url, policy, { allowAi = false } = {}) {
  if (!POLICIES.includes(policy)) throw new Error(`unknown policy: ${policy}`);
  const kind = ANALYTICS_PATTERNS.some((p) => p.test(url))
    ? 'analytics'
    : AI_PATTERNS.some((p) => p.test(url))
      ? 'ai'
      : FIREBASE_PATTERNS.some((p) => p.test(url))
        ? 'firebase'
        : 'other';
  if (kind === 'analytics') return { action: 'abort', kind, forbidden: false };
  if (kind === 'other') return { action: 'allow', kind, forbidden: false };
  if (policy === 'rehearsal') return { action: 'abort', kind, forbidden: true };
  if (policy === 'provisional') return { action: 'abort', kind, forbidden: false };
  // real
  if (kind === 'ai' && !allowAi) return { action: 'abort', kind, forbidden: false };
  return { action: 'allow', kind, forbidden: false };
}

/// Validates the run's configuration before anything loads. Returns a list of
/// problems (empty when fine).
export function configProblems(env) {
  const problems = [];
  const mode = env.E2E_MODE ?? 'auto';
  if (!['auto', 'rehearsal', 'real'].includes(mode)) {
    problems.push(`E2E_MODE must be auto, rehearsal or real (got "${mode}")`);
  }
  for (const flag of ['E2E_ALLOW_AI', 'E2E_REQUIRE_PREVIEW', 'E2E_HEADED']) {
    const value = env[flag];
    if (value !== undefined && value !== '' && value !== '0' && value !== '1') {
      problems.push(`${flag} must be 0 or 1 (got "${value}")`);
    }
  }
  if (mode === 'rehearsal' && env.E2E_ALLOW_AI === '1') {
    problems.push('E2E_ALLOW_AI=1 makes no sense with E2E_MODE=rehearsal');
  }
  return problems;
}

/// The policy to start the first load with.
export function initialPolicy(mode) {
  return mode === 'auto' ? 'provisional' : mode;
}

/// Whether a camera-card region shows an image rather than the empty
/// dark-green placeholder gradient. [stats] comes from regionStats().
export function looksLikePreview(stats) {
  if (!stats || typeof stats.gradientShare !== 'number') return false;
  if (Number.isNaN(stats.gradientShare)) return false;
  return stats.gradientShare < 0.5;
}

/// Pixel statistics for RGBA bytes: mean colour and the share of pixels that
/// look like the placeholder gradient (#214937 -> #102d24: dark and
/// green-dominant).
export function pixelStats(data) {
  const n = Math.floor(data.length / 4);
  if (n === 0) return { mean: [0, 0, 0], gradientShare: Number.NaN };
  let r = 0;
  let g = 0;
  let b = 0;
  let gradientLike = 0;
  for (let i = 0; i < n * 4; i += 4) {
    const [pr, pg, pb] = [data[i], data[i + 1], data[i + 2]];
    r += pr;
    g += pg;
    b += pb;
    const dark = pr < 60 && pg < 90 && pb < 70;
    if (dark && pg >= pr && pg >= pb) gradientLike += 1;
  }
  return {
    mean: [r / n, g / n, b / n].map(Math.round),
    gradientShare: gradientLike / n,
  };
}

/// Leaving the provisional policy once the build's mode is known. Requests it
/// blocked become failures for a rehearsal (a rehearsal may never make them)
/// and a reason to reload for a real build (it needed them). Returns
/// `{ policy, forbidden: [...urls], reload: boolean }`.
export function refinePolicy(current, mode, provisionallyBlocked) {
  if (!['rehearsal', 'real'].includes(mode)) throw new Error(`unknown mode: ${mode}`);
  if (current !== 'provisional') {
    return { policy: current, forbidden: [], reload: false };
  }
  return {
    policy: mode,
    forbidden: mode === 'rehearsal' ? [...provisionallyBlocked] : [],
    reload: mode === 'real' && provisionallyBlocked.length > 0,
  };
}

/// Chrome's console line for a request the run itself aborted.
const BLOCKED_RESOURCE = /^Failed to load resource: net::ERR_BLOCKED_BY_CLIENT(\.Inspector)?$/;

/// Firebase JS SDK modules (served from www.gstatic.com/firebasejs/<ver>/)
/// and the backend host each one fetches from. A "Failed to fetch" thrown
/// inside one of these modules is attributable to the provisional policy
/// only when a request to that module's host was actually blocked.
const FIREBASE_MODULE_HOSTS = {
  'firebase-analytics': [/firebaseinstallations\.googleapis\.com/, /firebase\.googleapis\.com\/v1alpha\/projects\/[^/]+\/apps\/[^/]+\/webConfig/],
  'firebase-installations': [/firebaseinstallations\.googleapis\.com/],
  'firebase-app-check': [/firebaseappcheck\.googleapis\.com/, /recaptcha/],
  'firebase-auth': [/identitytoolkit\.googleapis\.com/, /securetoken\.googleapis\.com/],
  'firebase-firestore': [/firestore\.googleapis\.com/],
};
const FETCH_FAILED_IN_FIREBASE =
  /^TypeError: Failed to fetch\n\s+at https:\/\/www\.gstatic\.com\/firebasejs\/\d+\.\d+\.\d+\/(firebase-[a-z-]+)\.js:\d+:\d+(\n|$)/;

/// Whether one console error is a known consequence of the provisional
/// policy, matched by exact signature against what was actually blocked.
/// Anything else (an app error, a fetch failure in app code, an SDK failure
/// whose host was not blocked) is not.
export function isProvisionalBlockError(text, blockedUrls) {
  if (!blockedUrls.length) return false;
  if (BLOCKED_RESOURCE.test(text)) return true;
  const match = FETCH_FAILED_IN_FIREBASE.exec(text);
  if (!match) return false;
  const hosts = FIREBASE_MODULE_HOSTS[match[1]];
  return Boolean(hosts) && blockedUrls.some((url) => hosts.some((h) => h.test(url)));
}

/// Splits first-load console errors before a real build is reloaded:
/// `setAside` holds only errors caused by the provisional blocking; every
/// other error stays in `fatal` and still fails the run.
export function partitionProvisionalErrors(errors, blockedUrls) {
  const setAside = [];
  const fatal = [];
  for (const text of errors) {
    (isProvisionalBlockError(text, blockedUrls) ? setAside : fatal).push(text);
  }
  return { setAside, fatal };
}

/// The console errors that fail a run: everything except Chrome's line for
/// a request this run aborted on purpose (analytics, AI in a real build).
export function fatalConsoleErrors(errors) {
  return errors.filter((text) => !BLOCKED_RESOURCE.test(text));
}
