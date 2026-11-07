// Current Gemini Live ephemeral-token REST contract, checked 2026-11-07:
// https://ai.google.dev/gemini-api/docs/live-api/ephemeral-tokens
// Only the constrained, short-lived token crosses into the browser.
export const LIVE_MODEL = 'gemini-3.8-live';
export const LIVE_API_VERSION = 'v1beta';
export const TOKEN_ENDPOINT =
  `https://generativelanguage.googleapis.com/${LIVE_API_VERSION}/auth_tokens`;

export class TokenRequestError extends Error {
  constructor(code, status, message, retryAfterSeconds) {
    super(message);
    this.code = code;
    this.status = status;
    this.retryAfterSeconds = retryAfterSeconds;
  }
}

function validateLiveSettings(model, apiVersion) {
  if (typeof model !== 'string' || !/^gemini-[a-zA-Z0-9._-]+$/.test(model) ||
      !['v1alpha', 'v1beta'].includes(apiVersion)) {
    throw new TokenRequestError('not-configured', 503, 'Live coaching configuration is invalid.');
  }
}

export function tokenConfiguration(nowMs, model = LIVE_MODEL) {
  return {
    uses: 1,
    expireTime: new Date(nowMs + 30 * 60_000).toISOString(),
    newSessionExpireTime: new Date(nowMs + 60_000).toISOString(),
    liveConnectConstraints: {
      model: `models/${model}`,
      config: { responseModalities: ['AUDIO'] },
    },
  };
}

export async function mintGoogleToken({
  apiKey, nowMs, model = LIVE_MODEL, apiVersion = LIVE_API_VERSION, fetchImpl = fetch,
}) {
  if (typeof apiKey !== 'string' || apiKey.length === 0) {
    throw new TokenRequestError('not-configured', 503, 'Live coaching is not configured yet.');
  }
  validateLiveSettings(model, apiVersion);
  const config = tokenConfiguration(nowMs, model);
  const endpoint = `https://generativelanguage.googleapis.com/${apiVersion}/auth_tokens`;
  const response = await fetchImpl(endpoint, {
    method: 'POST',
    headers: { 'x-goog-api-key': apiKey, 'Content-Type': 'application/json' },
    body: JSON.stringify(config),
    signal: AbortSignal.timeout(12_000),
    redirect: 'error',
  });
  if (!response.ok) {
    // Never return/log Google's raw response, which may echo sensitive inputs.
    throw new TokenRequestError('upstream-unavailable', 502, 'Live coaching could not connect. Try again.');
  }
  const data = await response.json();
  if (typeof data.name !== 'string' ||
      !data.name.startsWith('auth_tokens/') || data.name.length > 16_384) {
    throw new TokenRequestError('invalid-upstream-response', 502, 'Live coaching could not connect. Try again.');
  }
  return {
    token: data.name,
    model,
    apiVersion,
    expiresAt: config.expireTime,
    newSessionExpiresAt: config.newSessionExpireTime,
  };
}

/** Express-compatible handler with injectable boundaries for offline tests. */
export function createLiveTokenHandler({
  verifyAuth,
  verifyAppCheck,
  reserveQuota,
  createToken,
  allowedOrigins,
  now = Date.now,
  reportFailure = () => {},
}) {
  return async (req, res) => {
    res.set('Cache-Control', 'no-store, private');
    res.set('Vary', 'Origin');
    const origin = req.get('Origin');
    if (origin && !allowedOrigins.has(origin)) {
      return res.status(403).json({ error: { code: 'origin-denied', message: 'Origin is not allowed.' } });
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
      return res.status(405).json({ error: { code: 'method-not-allowed', message: 'Use POST.' } });
    }
    // The client cannot pick the model, lifetime, uses, or upstream endpoint.
    if (req.body != null && (typeof req.body !== 'object' ||
        Array.isArray(req.body) || Object.keys(req.body).length !== 0)) {
      return res.status(400).json({ error: { code: 'invalid-request', message: 'Send an empty JSON object.' } });
    }
    const authHeader = req.get('Authorization') ?? '';
    const match = /^Bearer ([^\s]+)$/.exec(authHeader);
    const appCheckToken = req.get('X-Firebase-AppCheck');
    if (!match || !appCheckToken || match[1].length > 16_384 || appCheckToken.length > 16_384) {
      return res.status(401).json({ error: { code: 'unauthenticated', message: 'Sign in and verify this app first.' } });
    }
    let uid;
    try {
      const [identity] = await Promise.all([
        verifyAuth(match[1]),
        verifyAppCheck(appCheckToken),
      ]);
      uid = identity.uid;
      if (typeof uid !== 'string' || uid.length === 0 || uid.length > 128) {
        throw new Error('Invalid authenticated identity');
      }
    } catch {
      return res.status(401).json({ error: { code: 'unauthenticated', message: 'Sign in and verify this app first.' } });
    }
    try {
      const nowMs = now();
      await reserveQuota(uid, nowMs);
      const token = await createToken(nowMs);
      return res.status(200).json(token);
    } catch (error) {
      const known = error instanceof TokenRequestError;
      const code = known ? error.code : 'temporarily-unavailable';
      // A fixed code is all we log: never a token, request body, or error object.
      reportFailure(code);
      if (known && error.retryAfterSeconds) {
        res.set('Retry-After', String(error.retryAfterSeconds));
      }
      return res.status(known ? error.status : 503).json({
        error: {
          code,
          message: known ? error.message : 'Live coaching is temporarily unavailable. Try again.',
          ...(known && error.retryAfterSeconds ? { retryAfterSeconds: error.retryAfterSeconds } : {}),
        },
      });
    }
  };
}
