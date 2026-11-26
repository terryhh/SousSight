// Live session reservation for the Firebase AI Logic Live path (DESIGN.md §6,
// SS-074). The client opens Gemini Live through Firebase AI Logic itself; this
// endpoint only admits the attempt: it requires a verified Firebase ID token AND
// a verified App Check token, then reserves the cook's quota with a server-side
// clock. No model call, credential or token is issued here.
//
// This is an app-level check: a modified client could skip it. Provider-side
// AI Logic rate limits remain the real ceiling (gate G1).
import { TokenRequestError } from './live-token.js';

const MODEL_PATTERN = /^gemini-[a-zA-Z0-9._-]+$/;

function deny(res, status, code, message, retryAfterSeconds) {
  if (retryAfterSeconds) res.set('Retry-After', String(retryAfterSeconds));
  return res.status(status).json({
    ok: false,
    error: { code, message, ...(retryAfterSeconds ? { retryAfterSeconds } : {}) },
  });
}

/** Express-compatible handler with injectable boundaries for offline tests. */
export function createLiveSessionHandler({
  verifyAuth,
  verifyAppCheck,
  reserveQuota,
  allowedOrigins,
  model,
  now = Date.now,
  reportFailure = () => {},
}) {
  return async (req, res) => {
    res.set('Cache-Control', 'no-store, private');
    res.set('Vary', 'Origin');
    const origin = req.get('Origin');
    // Native apps send no Origin; browsers must come from the Hosting domains.
    if (origin && !allowedOrigins.has(origin)) {
      return deny(res, 403, 'origin-denied', 'Origin is not allowed.');
    }
    if (origin) res.set('Access-Control-Allow-Origin', origin);
    if (req.method === 'OPTIONS') {
      res.set('Access-Control-Allow-Methods', 'POST');
      res.set('Access-Control-Allow-Headers', 'Authorization, X-Firebase-AppCheck, Content-Type');
      res.set('Access-Control-Max-Age', '300');
      return res.status(204).end();
    }
    if (req.method !== 'POST') {
      res.set('Allow', 'POST');
      return deny(res, 405, 'method-not-allowed', 'Use POST.');
    }
    // The client cannot choose the time, identity or quota bucket.
    if (req.body != null && (typeof req.body !== 'object' ||
        Array.isArray(req.body) || Object.keys(req.body).length !== 0)) {
      return deny(res, 400, 'invalid-request', 'Send an empty JSON object.');
    }
    const match = /^Bearer ([^\s]+)$/.exec(req.get('Authorization') ?? '');
    const appCheckToken = req.get('X-Firebase-AppCheck');
    if (!match || !appCheckToken || match[1].length > 16_384 || appCheckToken.length > 16_384) {
      return deny(res, 401, 'unauthenticated', 'Sign in and verify this app first.');
    }
    let uid;
    try {
      // Both must verify; either failing denies the reservation.
      const [identity] = await Promise.all([
        verifyAuth(match[1]),
        verifyAppCheck(appCheckToken),
      ]);
      uid = identity?.uid;
      if (typeof uid !== 'string' || uid.length === 0 || uid.length > 128) {
        throw new Error('Invalid authenticated identity');
      }
    } catch {
      return deny(res, 401, 'unauthenticated', 'Sign in and verify this app first.');
    }
    // A bad deployment setting fails before any quota is consumed.
    if (typeof model !== 'string' || !MODEL_PATTERN.test(model)) {
      reportFailure('not-configured');
      return deny(res, 503, 'not-configured', 'Live coaching configuration is invalid.');
    }
    try {
      // Server clock only; the request carries no time.
      const nowMs = now();
      await reserveQuota(uid, nowMs);
      return res.status(200).json({ ok: true, model, reservedAt: new Date(nowMs).toISOString() });
    } catch (error) {
      const known = error instanceof TokenRequestError;
      const code = known ? error.code : 'temporarily-unavailable';
      // A fixed code is all we log: never a token, uid, request body or error object.
      reportFailure(code);
      return deny(res, known ? error.status : 503, code,
        known ? error.message : 'Live coaching is temporarily unavailable. Try again.',
        known ? error.retryAfterSeconds : undefined);
    }
  };
}
