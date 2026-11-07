import test from 'node:test';
import assert from 'node:assert/strict';
import {
  createDinnerLedger, createDinnerReadyHandler, createDinnerService,
  sendVonageDinner, validateDinnerRequest,
} from '../src/dinner-ready.js';

const input = () => ({ sessionId: 'meal-1', notificationId: 'notice-123',
  recipient: '+14075550100', message: 'Dinner is ready! Chickpea wraps are on the table.' });
const settings = { enabled: true, channel: 'whatsapp', allowedRecipients: ['14075550100'] };
const nowMs = Date.parse('2026-11-07T21:00:00Z');
function fakeFirestore() {
  const docs = new Map([['sessions/meal-1', { learnerId: 'cook-1' }]]);
  let queue = Promise.resolve();
  return {
    docs,
    collection: (name) => ({ doc: (id) => `${name}/${id}` }),
    runTransaction(callback) {
      const task = queue.then(async () => {
        const writes = [];
        const result = await callback({
          get: async (ref) => ({ exists: docs.has(ref), data: () => docs.get(ref) }),
          create(ref, data) {
            if (docs.has(ref)) throw new Error('Already exists');
            writes.push(() => docs.set(ref, data));
          },
          update(ref, data) { writes.push(() => docs.set(ref, { ...docs.get(ref), ...data })); },
        });
        writes.forEach((write) => write());
        return result;
      });
      queue = task.catch(() => {});
      return task;
    },
  };
}
function harness(overrides = {}) {
  const db = fakeFirestore();
  const sent = [];
  const ledger = createDinnerLedger(db);
  const service = createDinnerService({
    ledger, settings, now: () => nowMs,
    sendMessage: async (request) => {
      sent.push(request);
      return { status: 'submitted', providerMessageId: 'abc-123' };
    },
    ...overrides,
  });
  return { db, ledger, service, sent };
}

test('checks allowed recipient and preserves exact reviewed message', () => {
  const body = input();
  body.message = ' Dinner is ready!\nCome to the table. ';
  const request = validateDinnerRequest(body, settings.allowedRecipients);
  assert.equal(request.recipient, '14075550100');
  assert.equal(request.message, body.message);
  assert.throws(() => validateDinnerRequest({ ...body, recipient: '+14075550200' }, settings.allowedRecipients),
    { code: 'recipient-not-allowed', status: 403 });
  for (const change of [
    { message: ' ' }, { message: 'x'.repeat(321) }, { message: '\u0001bad' },
    { notificationId: '../bad/key' }, { sessionId: '../../other' },
    { channel: 'sms' }, { recipient: '4075550100 ext123' },
  ]) {
    assert.throws(() => validateDinnerRequest({ ...body, ...change }, settings.allowedRecipients));
  }
});

test('session ownership is verified in claim transaction before any provider call', async () => {
  const { service, sent, db } = harness();
  await assert.rejects(service('another-cook', input()), { code: 'session-not-owned', status: 403 });
  await assert.rejects(service('cook-1', { ...input(), sessionId: 'missing' }), { code: 'session-not-owned' });
  assert.equal(sent.length, 0);
  assert.equal(db.docs.size, 1);
});

test('concurrent duplicate requests call Vonage once and do not claim delivery', async () => {
  const { service, sent } = harness();
  const results = await Promise.all([
    service('cook-1', input()), service('cook-1', input()), service('cook-1', input()),
  ]);
  assert.equal(sent.length, 1);
  assert.equal(results.filter((r) => !r.duplicate).length, 1);
  assert.ok(results.every((r) => ['submitted', 'unknown'].includes(r.status)));
  assert.ok(results.every((r) => !('delivered' in r)));
  const duplicate = await service('cook-1', input());
  assert.equal(duplicate.duplicate, true);
  assert.equal(duplicate.status, 'submitted');
  assert.equal(sent.length, 1);
});

test('same ID with changed content and fresh ID for same meal cannot bypass a claim', async () => {
  const { service, sent } = harness();
  await service('cook-1', input());
  await assert.rejects(service('cook-1', { ...input(), message: 'Changed content' }),
    { code: 'idempotency-conflict', status: 409 });
  await assert.rejects(service('cook-1', { ...input(), notificationId: 'new-notice-123' }),
    { code: 'meal-already-notified', status: 409 });
  assert.equal(sent.length, 1);
});

test('dry-run skips provider and keeps a terminal, repeatable result', async () => {
  const { service, sent } = harness({ settings: { ...settings, enabled: false } });
  const result = await service('cook-1', input());
  assert.equal(result.status, 'skipped');
  assert.equal(result.reason, 'dry-run');
  assert.equal((await service('cook-1', input())).status, 'skipped');
  assert.equal(sent.length, 0);
});

test('ambiguous send and failure after acceptance are never automatically resent', async () => {
  let calls = 0;
  const { service } = harness({ sendMessage: async () => {
    calls++;
    throw new Error('network timeout after possible acceptance');
  } });
  assert.equal((await service('cook-1', input())).status, 'unknown');
  assert.equal((await service('cook-1', input())).status, 'unknown');
  assert.equal(calls, 1);

  const db = fakeFirestore();
  const realLedger = createDinnerLedger(db);
  const failedPersistence = createDinnerService({ settings,
    ledger: { ...realLedger, settle: async () => { throw new Error('Firestore unavailable'); } },
    sendMessage: async () => { calls++; return { status: 'submitted' }; },
  });
  assert.equal((await failedPersistence('cook-1', input())).reason, 'status-not-persisted');
  const retry = await failedPersistence('cook-1', input());
  assert.equal(retry.status, 'unknown');
  assert.equal(retry.duplicate, true);
  assert.equal(calls, 2);
});

test('provider payload uses WhatsApp sandbox or SMS endpoint with Basic auth', async () => {
  for (const channel of ['whatsapp', 'sms']) {
    const request = validateDinnerRequest(input(), settings.allowedRecipients);
    const result = await sendVonageDinner({ request, channel,
      credentials: { apiKey: 'key', apiSecret: 'secret', from: '+14075550999' },
      fetchImpl: async (url, options) => {
        assert.equal(url, channel === 'whatsapp'
          ? 'https://messages-sandbox.nexmo.com/v1/messages' : 'https://api.nexmo.com/v1/messages');
        assert.equal(options.headers.Authorization, `Basic ${Buffer.from('key:secret').toString('base64')}`);
        assert.deepEqual(JSON.parse(options.body), {
          channel, message_type: 'text', to: '14075550100', from: '14075550999',
          text: request.message, client_ref: request.notificationId,
        });
        assert.equal(options.redirect, 'error');
        return new Response(JSON.stringify({ message_uuid: 'abc-123' }), { status: 202 });
      },
    });
    assert.deepEqual(result, { status: 'submitted', providerMessageId: 'abc-123' });
  }
});

test('provider rejection differs from timeout, 5xx, malformed acceptance and delivery', async () => {
  const request = validateDinnerRequest(input(), settings.allowedRecipients);
  for (const [status, expected, body] of [
    [401, 'failed', 'bad credentials'], [422, 'failed', '{}'], [429, 'failed', '{}'],
    [408, 'unknown', '{}'], [500, 'unknown', '{}'], [202, 'unknown', '{}'],
    [202, 'unknown', 'invalid JSON'], [200, 'unknown', '{}'],
  ]) {
    const result = await sendVonageDinner({ request, channel: 'whatsapp',
      credentials: { apiKey: 'key', apiSecret: 'secret', from: '14075550999' },
      fetchImpl: async () => new Response(body, { status }),
    });
    assert.equal(result.status, expected);
  }
  const result = await sendVonageDinner({ request, channel: 'whatsapp',
    credentials: { apiKey: 'key', apiSecret: 'secret', from: '14075550999' },
    fetchImpl: async () => { throw new Error('timeout'); },
  });
  assert.equal(result.status, 'unknown');
});

test('HTTP gate requires Auth and App Check and only passes verified UID to service', async () => {
  let calls = 0;
  const handler = createDinnerReadyHandler({
    verifyAuth: async (token) => { assert.equal(token, 'id-token'); return { uid: 'cook-1' }; },
    verifyAppCheck: async (token) => { if (token !== 'valid-app') throw new Error('bad app'); },
    allowedOrigins: new Set(['https://example.com']),
    service: async (uid, body) => { calls++; assert.equal(uid, 'cook-1'); assert.deepEqual(body, input()); return { status: 'skipped' }; },
  });
  const req = (headers = {}) => ({ method: 'POST', body: input(),
    get: (key) => ({ Origin: 'https://example.com', Authorization: 'Bearer id-token',
      'X-Firebase-AppCheck': 'valid-app', ...headers })[key] });
  const res = () => ({ code: null, body: null, headers: {},
    set(key, value) { this.headers[key] = value; return this; },
    status(code) { this.code = code; return this; },
    json(body) { this.body = body; return this; }, end() { return this; } });
  for (const headers of [{ Authorization: '' }, { 'X-Firebase-AppCheck': '' }, { 'X-Firebase-AppCheck': 'invalid-app' }]) {
    const result = res();
    await handler(req(headers), result);
    assert.equal(result.code, 401);
  }
  assert.equal(calls, 0);
  const result = res();
  await handler(req(), result);
  assert.equal(result.code, 200);
  assert.equal(calls, 1);
  assert.equal(result.headers['Cache-Control'], 'no-store, private');
});
