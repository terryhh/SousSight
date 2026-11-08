import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash, createHmac } from 'node:crypto';
import {
  createDeliveryStatusStore, createVonageStatusHandler, newStatusToken, parseStatusEvent, pendingStatusPath,
  providerIndexId, sameTokenHash, shouldAdvance, statusTokenFromPath, statusTokenHash, verifyVonageSignature,
  WebhookAuthError,
} from '../src/vonage-status.js';
import { fakeFirestore } from './fake-firestore.js';

const secret = 'test-signature-secret-not-real-0123456789';
const nowMs = Date.parse('2026-11-08T18:00:00Z');
const nowSeconds = nowMs / 1000;
const b64 = (value) => Buffer.from(JSON.stringify(value)).toString('base64url');
const sha = (text) => createHash('sha256').update(text).digest('hex');

function sign(claims, { key = secret, header = { alg: 'HS256', typ: 'JWT' } } = {}) {
  const unsigned = `${b64(header)}.${b64(claims)}`;
  return `${unsigned}.${createHmac('sha256', key).update(unsigned).digest('base64url')}`;
}
function statusBody(overrides = {}) {
  return JSON.stringify({ message_uuid: 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee', to: '14075550100',
    from: '14075550999', timestamp: '2026-11-08T18:00:00Z', status: 'delivered', channel: 'sms',
    client_ref: 'notice-123', ...overrides });
}
const claimsFor = (raw, overrides = {}) => ({ iat: nowSeconds, jti: 'jti-1', iss: 'Vonage',
  api_key: 'key', payload_hash: sha(raw), ...overrides });

test('valid HS256 JWT bound to the body verifies, with or without Bearer prefix', () => {
  const raw = statusBody();
  const token = sign(claimsFor(raw));
  for (const authorization of [`Bearer ${token}`, token]) {
    const claims = verifyVonageSignature({ authorization, rawBody: Buffer.from(raw), secret, nowMs });
    assert.equal(claims.jti, 'jti-1');
  }
  // Pretty-printed body with the hash of its compact JSON form is also bound.
  const pretty = JSON.stringify(JSON.parse(raw), null, 2);
  verifyVonageSignature({ authorization: sign(claimsFor(raw)), rawBody: pretty, secret, nowMs });
});

test('bad signature, wrong secret, alg none and malformed tokens are rejected', () => {
  const raw = statusBody();
  const good = sign(claimsFor(raw));
  const cases = [
    [sign(claimsFor(raw), { key: 'other-secret' }), 'bad-signature'],
    [`${good.slice(0, -2)}xx`, 'bad-signature'],
    [`${b64({ alg: 'none' })}.${b64(claimsFor(raw))}.`, 'bad-algorithm'],
    [sign(claimsFor(raw), { header: { alg: 'HS512' } }), 'bad-algorithm'],
    ['not-a-jwt', 'malformed-token'],
    ['a.b', 'malformed-token'],
    ['', 'unsigned'],
  ];
  for (const [authorization, code] of cases) {
    assert.throws(() => verifyVonageSignature({ authorization, rawBody: raw, secret, nowMs }),
      (error) => error instanceof WebhookAuthError && error.code === code, code);
  }
  assert.throws(() => verifyVonageSignature({ authorization: good, rawBody: raw, secret: '', nowMs }),
    { code: 'not-configured' });
});

test('stale or future iat is rejected', () => {
  const raw = statusBody();
  for (const iat of [nowSeconds - 301, nowSeconds + 120, undefined, 'now']) {
    assert.throws(() => verifyVonageSignature({ authorization: sign(claimsFor(raw, { iat })),
      rawBody: raw, secret, nowMs }), { code: 'stale-token' });
  }
  verifyVonageSignature({ authorization: sign(claimsFor(raw, { iat: nowSeconds - 299 })), rawBody: raw, secret, nowMs });
});

test('payload hash mismatch or absence is rejected', () => {
  const raw = statusBody();
  const tampered = statusBody({ status: 'read' });
  for (const claims of [claimsFor(raw), claimsFor(raw, { payload_hash: undefined }), claimsFor(raw, { payload_hash: 'abc' })]) {
    assert.throws(() => verifyVonageSignature({ authorization: sign(claims), rawBody: tampered, secret, nowMs }),
      { code: 'payload-hash-mismatch' });
  }
});

test('status parsing keeps only documented statuses and a sanitised error', () => {
  assert.deepEqual(parseStatusEvent(JSON.parse(statusBody({ status: 'rejected',
    error: { type: 'https://developer.vonage.com/api-errors/messages#1120', title: 'Illegal Sender Address',
      detail: 'Sender 14075550999 invalid', instance: 'trace' } }))), {
    messageUuid: 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee', status: 'rejected',
    errorTitle: 'Illegal Sender Address', errorCode: '1120' });
  for (const body of [null, [], {}, { message_uuid: 'x', status: 'exploded' },
    { message_uuid: '../x', status: 'delivered' }]) {
    assert.equal(parseStatusEvent(body), null);
  }
});

test('status transitions are monotonic and failures are terminal', () => {
  assert.equal(shouldAdvance(null, 'submitted'), true);
  assert.equal(shouldAdvance('submitted', 'delivered'), true);
  assert.equal(shouldAdvance('delivered', 'read'), true);
  assert.equal(shouldAdvance('delivered', 'submitted'), false);
  assert.equal(shouldAdvance('read', 'delivered'), false);
  assert.equal(shouldAdvance('submitted', 'rejected'), true);
  assert.equal(shouldAdvance('delivered', 'undeliverable'), false);
  assert.equal(shouldAdvance('rejected', 'delivered'), false);
  assert.equal(shouldAdvance('submitted', 'mystery'), false);
});

const capToken = 'A'.repeat(20) + 'b_-' + 'c'.repeat(20); // 43 chars, test-only
function seeded() {
  const uuid = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee';
  const db = fakeFirestore([
    ['_dinnerNotifications/ledger-1', { status: 'submitted', kind: 'started', sessionId: 'meal-1',
      notificationId: 'notice-123', simulated: false }],
    [`_dinnerProviderMessages/${providerIndexId(uuid)}`, { ledgerKey: 'ledger-1', sessionId: 'meal-1',
      notificationId: 'notice-123', simulated: false, statusTokenHash: statusTokenHash(capToken) }],
  ]);
  return { db, uuid };
}

test('ledger history and cook mirror update without downgrading', async () => {
  const { db, uuid } = seeded();
  const apply = createDeliveryStatusStore(db);
  assert.deepEqual(await apply({ messageUuid: uuid, status: 'delivered' }, nowMs), { matched: true, applied: true, status: 'delivered' });
  assert.equal((await apply({ messageUuid: uuid, status: 'submitted' }, nowMs + 1)).applied, false);
  await apply({ messageUuid: uuid, status: 'read' }, nowMs + 2);
  const ledger = db.docs.get('_dinnerNotifications/ledger-1');
  assert.equal(ledger.deliveryStatus, 'read');
  assert.deepEqual(ledger.statusHistory.map((entry) => entry.status), ['delivered', 'read']);
  assert.deepEqual(db.docs.get('sessions/meal-1/notifications/notice-123'), { kind: 'started', status: 'read',
    errorTitle: null, errorCode: null, simulated: false, updatedAt: nowMs + 2 });
  assert.deepEqual(await apply({ messageUuid: 'unknown-uuid', status: 'delivered' }, nowMs),
    { matched: false, buffered: true });
  assert.deepEqual(db.docs.get(`_dinnerPendingStatus/${providerIndexId('unknown-uuid')}`).events,
    [{ status: 'delivered', errorTitle: null, errorCode: null, at: nowMs }]);
});

function harness(applyStatus, { signatureSecret = secret } = {}) {
  const reports = [];
  const handler = createVonageStatusHandler({ secret: () => signatureSecret, applyStatus, now: () => nowMs,
    report: (event, fields) => reports.push([event, fields]) });
  const call = async ({ raw = statusBody(), authorization, method = 'POST', path = '/api/vonage-status' } = {}) => {
    const res = { code: null, body: null, headers: {},
      set(key, value) { this.headers[key] = value; return this; },
      status(code) { this.code = code; return this; }, json(body) { this.body = body; return this; } };
    let parsed = {};
    try { parsed = JSON.parse(raw); } catch { /* malformed on purpose */ }
    await handler({ method, path, originalUrl: path, rawBody: Buffer.from(raw), body: parsed,
      get: (key) => (key === 'Authorization' ? authorization : undefined) }, res);
    return res;
  };
  return { call, reports };
}

test('webhook handler: 401 invalid or unsigned+tokenless, 200 for unknown uuid, applies verified status', async () => {
  const { db, uuid } = seeded();
  const { call, reports } = harness(createDeliveryStatusStore(db));
  const raw = statusBody();
  assert.equal((await call({ raw, authorization: `Bearer ${sign(claimsFor(raw), { key: 'wrong' })}` })).code, 401);
  assert.equal((await call({ raw, authorization: undefined })).code, 401);
  assert.equal((await call({ raw, method: 'GET' })).code, 405);
  assert.equal(db.docs.get('sessions/meal-1/notifications/notice-123'), undefined);

  const unknown = statusBody({ message_uuid: '11111111-2222-3333-4444-555555555555' });
  assert.equal((await call({ raw: unknown, authorization: `Bearer ${sign(claimsFor(unknown))}` })).code, 200);

  const rejected = statusBody({ status: 'rejected',
    error: { type: 'https://developer.vonage.com/api-errors/messages#1120', title: 'Illegal Sender Address' } });
  const res = await call({ raw: rejected, authorization: `Bearer ${sign(claimsFor(rejected))}` });
  assert.equal(res.code, 200);
  assert.deepEqual(db.docs.get('sessions/meal-1/notifications/notice-123'), { kind: 'started', status: 'rejected',
    errorTitle: 'Illegal Sender Address', errorCode: '1120', simulated: false, updatedAt: nowMs });
  // Logs carry only codes and statuses, never tokens, bodies, numbers or UUIDs.
  const logged = JSON.stringify(reports);
  assert.doesNotMatch(logged, new RegExp(`${uuid}|4075550|${secret}|eyJ`));
  assert.ok(reports.some(([event, fields]) => event === 'vonage-status-rejected' && fields.code === 'bad-signature'));
});

test('webhook handler returns 500 on storage failure so Vonage retries', async () => {
  const { call } = harness(async () => { throw new Error('Firestore unavailable'); });
  const raw = statusBody();
  assert.equal((await call({ raw, authorization: `Bearer ${sign(claimsFor(raw))}` })).code, 500);
});

test('capability tokens: random 43-char base64url, hash compare, path extraction', () => {
  const a = newStatusToken();
  assert.match(a, /^[A-Za-z0-9_-]{43}$/);
  assert.notEqual(a, newStatusToken());
  assert.equal(sameTokenHash(statusTokenHash(a), statusTokenHash(a)), true);
  assert.equal(sameTokenHash(statusTokenHash(a), statusTokenHash(capToken)), false);
  assert.equal(sameTokenHash(statusTokenHash(a), undefined), false);
  assert.equal(sameTokenHash('zz', 'zz'), false);
  assert.equal(statusTokenFromPath({ path: `/api/vonage-status/${capToken}` }), capToken);
  assert.equal(statusTokenFromPath({ path: `/api/vonage-status/${capToken}/` }), capToken);
  assert.equal(statusTokenFromPath({ path: `/${capToken}` }), capToken);
  assert.equal(statusTokenFromPath({ originalUrl: `/api/vonage-status/${capToken}?x=1` }), capToken);
  for (const path of ['/api/vonage-status', '/api/vonage-status/short', `/api/other/${capToken}`,
    `/api/vonage-status/${capToken}/extra`, `/api/vonage-status/${capToken}x`, '/']) {
    assert.equal(statusTokenFromPath({ path }), null, path);
  }
});

for (const [label, signatureSecret] of [['without a signature secret', ''], ['with a signature secret', secret]]) {
  test(`capability URL ${label}: right token applies, wrong or missing token is 401`, async () => {
    const { db, uuid } = seeded();
    const { call, reports } = harness(createDeliveryStatusStore(db), { signatureSecret });
    const raw = statusBody();
    const wrong = newStatusToken();
    assert.equal((await call({ raw, path: `/api/vonage-status/${wrong}` })).code, 401);
    assert.equal((await call({ raw, path: '/api/vonage-status' })).code, 401);
    assert.equal((await call({ raw, path: '/api/vonage-status/not-a-token' })).code, 401);
    assert.equal(db.docs.get('sessions/meal-1/notifications/notice-123'), undefined);
    assert.equal(db.docs.get('_dinnerNotifications/ledger-1').deliveryStatus, undefined);

    const res = await call({ raw, path: `/api/vonage-status/${capToken}` });
    assert.equal(res.code, 200);
    assert.deepEqual(db.docs.get('sessions/meal-1/notifications/notice-123'), { kind: 'started', status: 'delivered',
      errorTitle: null, errorCode: null, simulated: false, updatedAt: nowMs });
    assert.equal(db.docs.get('_dinnerNotifications/ledger-1').deliveryStatus, 'delivered');
    // The token is a valid capability for THIS message only.
    const other = statusBody({ message_uuid: '99999999-2222-3333-4444-555555555555' });
    db.docs.set(`_dinnerProviderMessages/${providerIndexId('99999999-2222-3333-4444-555555555555')}`,
      { ledgerKey: 'ledger-1', sessionId: 'meal-1', notificationId: 'notice-123', simulated: false,
        statusTokenHash: statusTokenHash(wrong) });
    assert.equal((await call({ raw: other, path: `/api/vonage-status/${capToken}` })).code, 401);
    // A legacy index without a stored hash never accepts a capability.
    db.docs.set(`_dinnerProviderMessages/${providerIndexId(uuid)}`, { ledgerKey: 'ledger-1', sessionId: 'meal-1',
      notificationId: 'notice-123', simulated: false });
    assert.equal((await call({ raw, path: `/api/vonage-status/${capToken}` })).code, 401);
    assert.equal((await call({ raw: '{nope', path: `/api/vonage-status/${capToken}` })).code, 400);

    const logged = JSON.stringify(reports);
    for (const secretValue of [capToken, wrong, statusTokenHash(capToken), statusTokenHash(wrong), uuid]) {
      assert.equal(logged.includes(secretValue), false);
    }
    assert.ok(reports.some(([event, fields]) => event === 'vonage-status-rejected' && fields.code === 'capability-mismatch'));
    assert.ok(reports.some(([event, fields]) => event === 'vonage-status-rejected' && fields.code === 'unauthenticated'));
  });
}

test('a signed JWT without a configured secret falls back to the capability check', async () => {
  const { db } = seeded();
  const { call } = harness(createDeliveryStatusStore(db), { signatureSecret: '' });
  const raw = statusBody();
  const authorization = `Bearer ${sign(claimsFor(raw))}`;
  assert.equal((await call({ raw, authorization })).code, 401);
  assert.equal((await call({ raw, authorization, path: `/api/vonage-status/${capToken}` })).code, 200);
});

test('capability callbacks for an unknown uuid are buffered under the token hash', async () => {
  const db = fakeFirestore();
  const { call } = harness(createDeliveryStatusStore(db), { signatureSecret: '' });
  const uuid = '11111111-2222-3333-4444-555555555555';
  const raw = statusBody({ message_uuid: uuid });
  assert.equal((await call({ raw, path: `/api/vonage-status/${capToken}` })).code, 200);
  const buffered = db.docs.get(pendingStatusPath(uuid, statusTokenHash(capToken)));
  assert.equal(buffered.tokenHash, statusTokenHash(capToken));
  assert.deepEqual(buffered.events.map((e) => e.status), ['delivered']);
  assert.equal(db.docs.has(pendingStatusPath(uuid)), false);
  assert.equal(JSON.stringify([...db.docs.values()]).includes(capToken), false);
});
