import test from 'node:test';
import assert from 'node:assert/strict';
import {
  createLiveTokenHandler,
  LIVE_API_VERSION,
  LIVE_MODEL,
  mintGoogleToken,
  TOKEN_ENDPOINT,
  TokenRequestError,
} from '../src/live-token.js';
import { MIN_INTERVAL_MS, createQuotaReservation, nextQuota } from '../src/token-quota.js';

const nowMs = Date.parse('2026-11-07T21:00:00Z');
const origin = 'https://devfest-flutter-a59e8.web.app';
function request(overrides = {}) {
  const headers = {
    origin,
    authorization: 'Bearer firebase-id',
    'x-firebase-appcheck': 'app-check-token',
    ...overrides.headers,
  };
  return { method: 'POST', body: {}, ...overrides,
    get: (key) => headers[key.toLowerCase()] };
}
function response() {
  return {
    statusCode: 200, headers: {}, body: null,
    status(code) { this.statusCode = code; return this; },
    set(key, value) { this.headers[key] = value; return this; },
    json(body) { this.body = body; return this; },
    end() { return this; },
  };
}
function harness(overrides = {}) {
  const calls = [];
  const token = { token: 'auth_tokens/ephemeral', model: LIVE_MODEL, apiVersion: LIVE_API_VERSION };
  const handler = createLiveTokenHandler({
    verifyAuth: async (value) => { calls.push(['auth', value]); return { uid: 'learner' }; },
    verifyAppCheck: async (value) => { calls.push(['appcheck', value]); return { appId: 'web-app' }; },
    reserveQuota: async (uid, time) => { calls.push(['quota', uid, time]); },
    createToken: async (time) => { calls.push(['mint', time]); return token; },
    allowedOrigins: new Set([origin]),
    now: () => nowMs,
    reportFailure: (code) => calls.push(['failure', code]),
    ...overrides,
  });
  return { calls, handler, token };
}

test('authenticated, attested request reserves quota before minting and disables caching', async () => {
  const { handler, calls, token } = harness();
  const res = response();
  await handler(request(), res);
  assert.equal(res.statusCode, 200);
  assert.deepEqual(res.body, token);
  assert.deepEqual(calls, [
    ['auth', 'firebase-id'], ['appcheck', 'app-check-token'],
    ['quota', 'learner', nowMs], ['mint', nowMs],
  ]);
  assert.equal(res.headers['Cache-Control'], 'no-store, private');
  assert.equal(res.headers['Access-Control-Allow-Origin'], origin);
});

test('missing credentials, failed auth or failed App Check cannot mint', async () => {
  for (const input of [
    request({ headers: { authorization: '' } }),
    request({ headers: { 'x-firebase-appcheck': '' } }),
  ]) {
    const { handler, calls } = harness();
    const res = response();
    await handler(input, res);
    assert.equal(res.statusCode, 401);
    assert.deepEqual(calls, []);
  }
  for (const dependency of ['verifyAuth', 'verifyAppCheck']) {
    const { handler, calls } = harness({ [dependency]: async () => { throw new Error('invalid'); } });
    const res = response();
    await handler(request(), res);
    assert.equal(res.statusCode, 401);
    assert.equal(calls.some(([kind]) => kind === 'mint' || kind === 'quota'), false);
  }
});

test('cross-origin requests and model/uses overrides are rejected before authentication', async () => {
  for (const [input, status] of [
    [request({ headers: { origin: 'https://untrusted.example' } }), 403],
    [request({ body: { uses: 0, model: 'other-model' } }), 400],
    [request({ body: [] }), 400],
    [request({ method: 'GET' }), 405],
  ]) {
    const { handler, calls } = harness();
    const res = response();
    await handler(input, res);
    assert.equal(res.statusCode, status);
    assert.deepEqual(calls, []);
  }
});

test('allowed preflight returns CORS policy without minting or exposing credentials', async () => {
  const { handler, calls } = harness();
  const res = response();
  await handler(request({ method: 'OPTIONS' }), res);
  assert.equal(res.statusCode, 204);
  assert.equal(res.headers['Access-Control-Allow-Methods'], 'POST');
  assert.deepEqual(calls, []);
});

test('rate limit returns retry timing and never calls provider', async () => {
  const { handler, calls } = harness({ reserveQuota: async () => {
    throw new TokenRequestError('rate-limited', 429, 'Please wait before reconnecting.', 10);
  } });
  const res = response();
  await handler(request(), res);
  assert.equal(res.statusCode, 429);
  assert.equal(res.headers['Retry-After'], '10');
  assert.equal(res.body.error.retryAfterSeconds, 10);
  assert.equal(calls.some(([kind]) => kind === 'mint'), false);
});

test('unexpected provider errors do not leak secrets into response or logs', async () => {
  const { handler, calls } = harness({ createToken: async () => {
    throw new Error('APIKEY=do-not-leak');
  } });
  const res = response();
  await handler(request(), res);
  assert.equal(res.statusCode, 503);
  assert.doesNotMatch(JSON.stringify({ res, calls }), /do-not-leak/);
  assert.deepEqual(calls.at(-1), ['failure', 'temporarily-unavailable']);
});

test('REST AuthToken wire payload locks only model and audio while preserving client setup', async () => {
  const token = await mintGoogleToken({
    apiKey: 'server-secret', nowMs,
    fetchImpl: async (url, options) => {
      assert.equal(url, TOKEN_ENDPOINT);
      assert.equal(url, 'https://generativelanguage.googleapis.com/v1beta/auth_tokens');
      assert.equal(options.headers['x-goog-api-key'], 'server-secret');
      assert.equal(options.redirect, 'error');
      assert.ok(options.signal instanceof AbortSignal);
      assert.deepEqual(JSON.parse(options.body), {
        uses: 1,
        expireTime: '2026-11-07T21:30:00.000Z',
        newSessionExpireTime: '2026-11-07T21:01:00.000Z',
        bidiGenerateContentSetup: {
          model: `models/${LIVE_MODEL}`,
          generationConfig: {
            responseModalities: ['AUDIO'],
            mediaResolution: 'MEDIA_RESOLUTION_LOW',
          },
        },
        fieldMask: 'model,generationConfig.responseModalities,generationConfig.mediaResolution',
      });
      return new Response(JSON.stringify({ name: 'auth_tokens/short-lived' }), { status: 200 });
    },
  });
  assert.equal(token.token, 'auth_tokens/short-lived');
  assert.equal(token.expiresAt, '2026-11-07T21:30:00.000Z');
  assert.equal(token.newSessionExpiresAt, '2026-11-07T21:01:00.000Z');
  assert.doesNotMatch(JSON.stringify(token), /server-secret/);
});

test('provider rejection, missing configuration and non-ephemeral response fail closed', async () => {
  await assert.rejects(mintGoogleToken({ apiKey: '', nowMs }), { code: 'not-configured' });
  await assert.rejects(mintGoogleToken({ apiKey: 'server-secret', nowMs,
    fetchImpl: async () => new Response('sensitive-provider-message', { status: 403 }),
  }), { code: 'upstream-unavailable' });
  for (const name of ['', 'server-secret', undefined]) {
    await assert.rejects(mintGoogleToken({ apiKey: 'server-secret', nowMs,
      fetchImpl: async () => new Response(JSON.stringify({ name }), { status: 200 }),
    }), { code: 'invalid-upstream-response' });
  }
});

test('quota requires 3 seconds between starts and permits only eight in ten minutes', () => {
  assert.equal(MIN_INTERVAL_MS, 3_000);
  let quota = nextQuota(null, nowMs);
  assert.throws(() => nextQuota(quota, nowMs + 2999), (error) =>
    error.code === 'rate-limited' && error.status === 429 && error.retryAfterSeconds === 1);
  // A quick stage Stop/Start succeeds after 3 seconds.
  quota = nextQuota(quota, nowMs + 3_000);
  assert.equal(quota.count, 2);
  for (let i = 2; i < 8; i++) quota = nextQuota(quota, nowMs + i * 10_000);
  assert.equal(quota.count, 8);
  assert.throws(() => nextQuota(quota, nowMs + 80_000), { code: 'rate-limited', status: 429 });
  quota = nextQuota(quota, nowMs + 600_000);
  assert.equal(quota.count, 1);
  assert.equal(quota.windowStartedAt, nowMs + 600_000);
});

test('quota reservation uses transaction serialization and hashed user IDs', async () => {
  const docs = new Map();
  let queue = Promise.resolve();
  const db = {
    collection(name) {
      assert.equal(name, '_liveTokenLimits');
      return { doc(id) { assert.match(id, /^[a-f0-9]{64}$/); return id; } };
    },
    runTransaction(callback) {
      const task = queue.then(() => callback({
        get: async (ref) => ({ exists: docs.has(ref), data: () => docs.get(ref) }),
        set: (ref, data) => docs.set(ref, data),
      }));
      queue = task.catch(() => {});
      return task;
    },
  };
  const reserve = createQuotaReservation(db);
  const results = await Promise.allSettled([
    reserve('learner', nowMs), reserve('learner', nowMs), reserve('learner', nowMs),
  ]);
  assert.equal(results.filter((r) => r.status === 'fulfilled').length, 1);
  assert.equal(docs.size, 1);
  assert.equal([...docs.values()][0].count, 1);
});


test('server-selected model and API version are reflected in constraints and client metadata', async () => {
  const token = await mintGoogleToken({
    apiKey: 'server-secret', nowMs, model: 'gemini-test-live', apiVersion: 'v1alpha',
    fetchImpl: async (url, options) => {
      assert.equal(url, 'https://generativelanguage.googleapis.com/v1alpha/auth_tokens');
      assert.equal(JSON.parse(options.body).bidiGenerateContentSetup.model, 'models/gemini-test-live');
      return new Response(JSON.stringify({ name: 'auth_tokens/configured' }));
    },
  });
  assert.equal(token.model, 'gemini-test-live');
  assert.equal(token.apiVersion, 'v1alpha');
});

test('invalid deployment settings fail before any provider request', async () => {
  for (const settings of [
    { model: '' }, { model: '../other' }, { model: 'models/gemini-live' },
    { apiVersion: '../v1beta' }, { apiVersion: 'v9' },
  ]) {
    await assert.rejects(mintGoogleToken({
      apiKey: 'server-secret', nowMs, ...settings,
      fetchImpl: async () => assert.fail('invalid settings must not reach provider'),
    }), { code: 'not-configured', status: 503 });
  }
});
