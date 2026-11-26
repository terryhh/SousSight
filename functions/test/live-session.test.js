import test from 'node:test';
import assert from 'node:assert/strict';
import { createLiveSessionHandler } from '../src/live-session.js';
import { LIVE_MODEL, TokenRequestError } from '../src/live-token.js';
import { GLOBAL_LIMIT_COLLECTION, MIN_INTERVAL_MS, createQuotaReservation } from '../src/token-quota.js';
import { fakeFirestore } from './fake-firestore.js';

const nowMs = Date.parse('2026-11-25T21:00:00Z');
const origin = 'https://devfest-flutter-a59e8.web.app';

function request(overrides = {}) {
  const headers = {
    origin,
    authorization: 'Bearer firebase-id',
    'x-firebase-appcheck': 'app-check-token',
    ...overrides.headers,
  };
  return { method: 'POST', body: {}, ...overrides, get: (key) => headers[key.toLowerCase()] };
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
  const handler = createLiveSessionHandler({
    verifyAuth: async (value) => { calls.push(['auth', value]); return { uid: 'cook-1' }; },
    verifyAppCheck: async (value) => { calls.push(['appcheck', value]); return { appId: 'web-app' }; },
    reserveQuota: async (uid, time) => { calls.push(['quota', uid, time]); },
    allowedOrigins: new Set([origin]),
    model: LIVE_MODEL,
    now: () => nowMs,
    reportFailure: (code) => calls.push(['failure', code]),
    ...overrides,
  });
  return { calls, handler };
}

test('the client and server pin the same Live model', () => {
  // lib/live/live_tools.dart defaults GEMINI_LIVE_MODEL to this id.
  assert.equal(LIVE_MODEL, 'gemini-3.1-flash-live-preview');
});

test('verified Auth and App Check reserve quota with the server clock and the verified uid', async () => {
  const { handler, calls } = harness();
  const res = response();
  await handler(request(), res);
  assert.equal(res.statusCode, 200);
  assert.deepEqual(res.body, { ok: true, model: LIVE_MODEL, reservedAt: '2026-11-25T21:00:00.000Z' });
  assert.deepEqual(calls, [
    ['auth', 'firebase-id'], ['appcheck', 'app-check-token'], ['quota', 'cook-1', nowMs],
  ]);
  assert.equal(res.headers['Cache-Control'], 'no-store, private');
  assert.equal(res.headers['Access-Control-Allow-Origin'], origin);
});

test('a native request (no Origin) is admitted on Auth and App Check alone', async () => {
  const { handler } = harness();
  const res = response();
  await handler(request({ headers: { origin: undefined } }), res);
  assert.equal(res.statusCode, 200);
  assert.equal(res.headers['Access-Control-Allow-Origin'], undefined);
});

test('missing Auth or App Check, or either failing verification, reserves nothing', async () => {
  const cases = [
    [request({ headers: { authorization: '' } }), {}],
    [request({ headers: { authorization: 'Basic abc' } }), {}],
    [request({ headers: { 'x-firebase-appcheck': '' } }), {}],
    [request(), { verifyAuth: async () => { throw new Error('revoked'); } }],
    [request(), { verifyAppCheck: async () => { throw new Error('bad attestation'); } }],
    [request(), { verifyAuth: async () => ({ uid: '' }) }],
  ];
  for (const [input, overrides] of cases) {
    const { handler, calls } = harness(overrides);
    const res = response();
    await handler(input, res);
    assert.equal(res.statusCode, 401);
    assert.equal(res.body.ok, false);
    assert.equal(res.body.error.code, 'unauthenticated');
    assert.equal(calls.some(([kind]) => kind === 'quota'), false);
  }
});

test('foreign origins, other methods and client-supplied fields are rejected before auth', async () => {
  for (const [input, status] of [
    [request({ headers: { origin: 'https://evil.example' } }), 403],
    [request({ method: 'GET' }), 405],
    [request({ body: { nowMs: 0 } }), 400],
    [request({ body: { uid: 'someone-else' } }), 400],
  ]) {
    const { handler, calls } = harness();
    const res = response();
    await handler(input, res);
    assert.equal(res.statusCode, status);
    assert.deepEqual(calls, []);
  }
});

test('preflight returns the CORS policy without reserving', async () => {
  const { handler, calls } = harness();
  const res = response();
  await handler(request({ method: 'OPTIONS' }), res);
  assert.equal(res.statusCode, 204);
  assert.match(res.headers['Access-Control-Allow-Headers'], /X-Firebase-AppCheck/);
  assert.deepEqual(calls, []);
});

test('a denied reservation returns 429 with Retry-After and retryAfterSeconds', async () => {
  const { handler, calls } = harness({
    reserveQuota: async () => {
      throw new TokenRequestError('rate-limited', 429, 'Please wait before reconnecting.', 2);
    },
  });
  const res = response();
  await handler(request(), res);
  assert.equal(res.statusCode, 429);
  assert.equal(res.headers['Retry-After'], '2');
  assert.deepEqual(res.body, {
    ok: false,
    error: { code: 'rate-limited', message: 'Please wait before reconnecting.', retryAfterSeconds: 2 },
  });
  assert.deepEqual(calls.at(-1), ['failure', 'rate-limited']);
});

test('unexpected storage errors fail closed without leaking details', async () => {
  const { handler, calls } = harness({
    reserveQuota: async () => { throw new Error('firestore secret detail'); },
  });
  const res = response();
  await handler(request(), res);
  assert.equal(res.statusCode, 503);
  assert.equal(res.body.ok, false);
  assert.equal(JSON.stringify(res.body).includes('secret'), false);
  assert.deepEqual(calls.at(-1), ['failure', 'temporarily-unavailable']);
});

test('an invalid deployed model fails before any quota is consumed', async () => {
  const { handler, calls } = harness({ model: 'models/../x' });
  const res = response();
  await handler(request(), res);
  assert.equal(res.statusCode, 503);
  assert.equal(res.body.error.code, 'not-configured');
  assert.equal(calls.some(([kind]) => kind === 'quota'), false);
});

test('with the real quota reservation: allowed, then denied on an immediate retry', async () => {
  const db = fakeFirestore([]);
  let clock = nowMs;
  const { handler } = harness({ reserveQuota: createQuotaReservation(db), now: () => clock });
  const first = response();
  await handler(request(), first);
  assert.equal(first.statusCode, 200);
  assert.equal(first.body.ok, true);
  // The user document is keyed by a hash, never the raw uid.
  assert.equal([...db.docs.keys()].some((key) => key.includes('cook-1')), false);
  assert.equal(db.docs.get(`${GLOBAL_LIMIT_COLLECTION}/project`).count, 1);

  clock = nowMs + 1_000;
  const second = response();
  await handler(request(), second);
  assert.equal(second.statusCode, 429);
  assert.equal(second.body.ok, false);
  assert.equal(second.headers['Retry-After'], String((MIN_INTERVAL_MS - 1_000) / 1000));

  clock = nowMs + MIN_INTERVAL_MS;
  const third = response();
  await handler(request(), third);
  assert.equal(third.statusCode, 200);
});
