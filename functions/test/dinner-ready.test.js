import test from 'node:test';
import assert from 'node:assert/strict';
import {
  cleanTemplateText, composeDinnerMessage, createDinnerLedger, createDinnerReadyHandler,
  createDinnerService, nextSendLimit, providerConfigProblem, sendVonageDinner,
  SEND_LIMIT_PER_HOUR, validateDinnerRequest,
} from '../src/dinner-ready.js';
import { createDeliveryStatusStore, providerIndexId } from '../src/vonage-status.js';
import { fakeFirestore } from './fake-firestore.js';

const input = (overrides = {}) => ({ sessionId: 'meal-1', notificationId: 'notice-123',
  recipient: '+14075550100', kind: 'ready', recipeTitle: 'Chickpea wraps', ...overrides });
const started = (overrides = {}) => input({ kind: 'started', minutes: 25, notificationId: 'start-123', ...overrides });
const settings = { enabled: true, channel: 'whatsapp', allowedRecipients: ['14075550100'] };
const nowMs = Date.parse('2026-11-07T21:00:00Z');
const READY_TEXT = 'SousSight: Dinner is ready! Chickpea wraps is on the table.';

function harness(overrides = {}) {
  const db = fakeFirestore();
  const sent = [];
  const ledger = createDinnerLedger(db);
  const service = createDinnerService({
    ledger, settings, now: () => nowMs,
    applyStatus: createDeliveryStatusStore(db),
    sendMessage: async (request) => {
      sent.push(request);
      return { status: 'submitted', providerMessageId: `uuid-${sent.length}` };
    },
    ...overrides,
  });
  return { db, ledger, service, sent };
}
const mirror = (db, id = 'notice-123') => db.docs.get(`sessions/meal-1/notifications/${id}`);

test('server templates compose started and ready messages from validated slots only', () => {
  assert.equal(validateDinnerRequest(input(), settings.allowedRecipients).message, READY_TEXT);
  assert.equal(validateDinnerRequest(started(), settings.allowedRecipients).message,
    'SousSight: Your cook started Chickpea wraps. Dinner in about 25 min.');
  assert.equal(validateDinnerRequest(started({ cookName: 'Terry' }), settings.allowedRecipients).message,
    'SousSight: Terry started Chickpea wraps. Dinner in about 25 min.');
  assert.equal(composeDinnerMessage({ kind: 'ready', recipeTitle: 'Soup' }),
    'SousSight: Dinner is ready! Soup is on the table.');
  // Links, markup and control characters cannot pass through the slots.
  assert.equal(cleanTemplateText(' <b>Pad\u0007 Thai</b> http://x.co/y ', 60), 'b Pad Thai b http x co y');
  assert.equal(cleanTemplateText('x'.repeat(100), 60).length, 60);
  const request = validateDinnerRequest(input({ recipeTitle: 'Mac & cheese!\nvisit evil.example' }),
    settings.allowedRecipients);
  assert.equal(request.recipeTitle, 'Mac & cheese! visit evil example');
});

test('rejects free-form messages, bad kinds, minutes and recipients', () => {
  assert.throws(() => validateDinnerRequest(input({ recipient: '+14075550200' }), settings.allowedRecipients),
    { code: 'recipient-not-allowed', status: 403 });
  for (const change of [
    { message: 'Free-form text' }, { kind: 'reminder' }, { kind: undefined }, { recipeTitle: '' },
    { recipeTitle: '<>' }, { recipeTitle: 'x'.repeat(201) }, { recipeTitle: 7 }, { minutes: 10 },
    { notificationId: '../bad/key' }, { sessionId: '../../other' }, { channel: 'sms' },
    { simulateFailure: 'yes' }, { simulateOutcome: 'read' }, { simulateOutcome: true },
    { simulateFailure: true, simulateOutcome: 'delivered' }, { cookName: 3 },
  ]) {
    assert.throws(() => validateDinnerRequest(input(change), settings.allowedRecipients), { code: 'invalid-request' }, JSON.stringify(change));
  }
  for (const minutes of [undefined, 0, 121, 2.5, '20']) {
    assert.throws(() => validateDinnerRequest(started({ minutes }), settings.allowedRecipients), { code: 'invalid-request' });
  }
  assert.throws(() => validateDinnerRequest(input({ recipient: '4075550100 ext123' }), settings.allowedRecipients),
    { code: 'invalid-recipient' });
});

test('session ownership is verified in claim transaction before any provider call', async () => {
  const { service, sent, db } = harness();
  await assert.rejects(service('another-cook', input()), { code: 'session-not-owned', status: 403 });
  await assert.rejects(service('cook-1', { ...input(), sessionId: 'missing' }), { code: 'session-not-owned' });
  assert.equal(sent.length, 0);
  assert.equal(db.docs.size, 1);
});

test('concurrent duplicate requests call Vonage once and do not claim delivery', async () => {
  const { service, sent, db } = harness();
  const results = await Promise.all([
    service('cook-1', input()), service('cook-1', input()), service('cook-1', input()),
  ]);
  assert.equal(sent.length, 1);
  assert.equal(sent[0].request.message, READY_TEXT);
  assert.equal(results.filter((r) => !r.duplicate).length, 1);
  assert.ok(results.every((r) => ['submitted', 'unknown'].includes(r.status)));
  assert.equal(results[0].message, READY_TEXT);
  const duplicate = await service('cook-1', input());
  assert.equal(duplicate.duplicate, true);
  assert.equal(duplicate.status, 'submitted');
  assert.equal(sent.length, 1);
  // Cook-readable mirror and webhook index are written; no phone number or text.
  assert.deepEqual(mirror(db), { kind: 'ready', status: 'submitted', errorTitle: null, errorCode: null,
    reason: null, simulated: false, updatedAt: nowMs });
  const index = db.docs.get(`_dinnerProviderMessages/${providerIndexId('uuid-1')}`);
  assert.equal(index.notificationId, 'notice-123');
  assert.equal(index.sessionId, 'meal-1');
  assert.doesNotMatch(JSON.stringify([...db.docs.values()]), /4075550100|Chickpea/);
});

test('same ID with changed content and fresh ID for same meal and kind cannot bypass a claim', async () => {
  const { service, sent } = harness();
  await service('cook-1', input());
  await assert.rejects(service('cook-1', input({ recipeTitle: 'Changed' })),
    { code: 'idempotency-conflict', status: 409 });
  await assert.rejects(service('cook-1', input({ notificationId: 'new-notice-123' })),
    { code: 'meal-already-notified', status: 409 });
  assert.equal(sent.length, 1);
  // Started and ready are separate lifecycle messages for the same meal.
  assert.equal((await service('cook-1', started())).status, 'submitted');
  assert.equal(sent.length, 2);
});

test('a known delivery failure frees the slot only for a new cook-confirmed ID', async () => {
  const { service, sent, db } = harness();
  await service('cook-1', input());
  await createDeliveryStatusStore(db)({ messageUuid: 'uuid-1', status: 'rejected',
    errorTitle: 'Illegal Sender Address', errorCode: '1120' }, nowMs + 1);
  // Repeating the failed ID returns its state; it never resends.
  const repeat = await service('cook-1', input());
  assert.equal(repeat.duplicate, true);
  assert.equal(repeat.deliveryStatus, 'rejected');
  assert.equal(sent.length, 1);
  const retry = await service('cook-1', input({ notificationId: 'retry-notice-1' }));
  assert.equal(retry.status, 'submitted');
  assert.equal(sent.length, 2);
  assert.equal(mirror(db, 'retry-notice-1').status, 'submitted');
  assert.equal(mirror(db).status, 'rejected');
});

test('send limit window allows five per hour then resets', () => {
  assert.deepEqual(nextSendLimit(null, nowMs), { windowStartedAt: nowMs, count: 1 });
  assert.throws(() => nextSendLimit({ windowStartedAt: nowMs, count: SEND_LIMIT_PER_HOUR }, nowMs + 1000),
    { code: 'rate-limited', status: 429 });
  assert.deepEqual(nextSendLimit({ windowStartedAt: nowMs, count: 5 }, nowMs + 3_600_000),
    { windowStartedAt: nowMs + 3_600_000, count: 1 });
});

test('rate limit blocks the sixth new claim within an hour without calling Vonage', async () => {
  const db = fakeFirestore([['sessions/meal-1', { learnerId: 'cook-1' }],
    ['sessions/meal-2', { learnerId: 'cook-1' }], ['sessions/meal-3', { learnerId: 'cook-1' }]]);
  let calls = 0;
  const service = createDinnerService({ ledger: createDinnerLedger(db), settings, now: () => nowMs,
    applyStatus: createDeliveryStatusStore(db),
    sendMessage: async () => { calls++; return { status: 'submitted', providerMessageId: `u-${calls}` }; } });
  const attempts = [];
  for (const sessionId of ['meal-1', 'meal-2', 'meal-3']) {
    attempts.push(input({ sessionId, notificationId: `ready-${sessionId}` }));
    attempts.push(started({ sessionId, notificationId: `start-${sessionId}` }));
  }
  for (const body of attempts.slice(0, 5)) await service('cook-1', body);
  await assert.rejects(service('cook-1', attempts[5]), { code: 'rate-limited', status: 429 });
  assert.equal(calls, 5);
  // Repeating an existing ID is a status read, not a new send, so it is allowed.
  assert.equal((await service('cook-1', attempts[0])).duplicate, true);
});

test('credential and sender problems are rejected before any ledger claim', async () => {
  const { service, sent, db } = harness({ settings: { ...settings, checkProvider: () => 'invalid-sender' } });
  await assert.rejects(service('cook-1', input()), { code: 'not-configured', status: 503 });
  assert.equal(sent.length, 0);
  assert.equal(db.docs.size, 1);
  assert.equal(providerConfigProblem({ apiKey: 'k', apiSecret: 's', from: 'Vonage APIs' }), 'invalid-sender');
  assert.equal(providerConfigProblem({ apiKey: 'k', apiSecret: '', from: '14075550999' }), 'not-configured');
  assert.equal(providerConfigProblem({ apiKey: 'k', apiSecret: 's', from: '+14075550999' }), null);
});

test('simulated failure skips Vonage and runs the shared status update', async () => {
  let calls = 0;
  const { service, db } = harness({
    settings: { ...settings, enabled: false, allowSimulation: true, checkProvider: () => 'not-configured' },
    sendMessage: async () => { calls++; throw new Error('Unexpected provider call'); },
  });
  const result = await service('cook-1', input({ simulateFailure: true }));
  assert.equal(calls, 0);
  assert.equal(result.status, 'submitted');
  assert.equal(result.deliveryStatus, 'rejected');
  assert.equal(result.simulated, true);
  assert.deepEqual(mirror(db), { kind: 'ready', status: 'rejected', errorTitle: 'Illegal Sender Address',
    errorCode: '1120', reason: null, simulated: true, updatedAt: nowMs });
  const ledger = [...db.docs.entries()].find(([key]) => key.startsWith('_dinnerNotifications/'))[1];
  assert.equal(ledger.deliveryStatus, 'rejected');
  assert.equal(ledger.simulated, true);
  assert.deepEqual(ledger.statusHistory.map((h) => h.status), ['rejected']);
  const index = [...db.docs.entries()].find(([key]) => key.startsWith('_dinnerProviderMessages/'))[1];
  assert.equal(index.simulated, true);
});

test('simulated delivery never contacts Vonage and mirrors submitted then delivered', async () => {
  const fetchCalls = [];
  const originalFetch = globalThis.fetch;
  globalThis.fetch = async (...args) => { fetchCalls.push(args); throw new Error('Unexpected network call'); };
  try {
    const { service, db } = harness({
      settings: { ...settings, enabled: false, allowSimulation: true, checkProvider: () => 'not-configured' },
      // The real transport with a spying fetch: any provider call would be recorded.
      sendMessage: ({ request, channel }) => sendVonageDinner({ request, channel,
        credentials: { apiKey: 'k', apiSecret: 's', from: '14075550999' },
        fetchImpl: async (...args) => { fetchCalls.push(args); throw new Error('Unexpected Vonage call'); } }),
    });
    for (const body of [input({ simulateOutcome: 'delivered' }),
      started({ simulateOutcome: 'delivered' })]) {
      const result = await service('cook-1', body);
      assert.equal(result.status, 'submitted');
      assert.equal(result.deliveryStatus, 'delivered');
      assert.equal(result.simulated, true);
      assert.deepEqual(mirror(db, body.notificationId), { kind: body.kind, status: 'delivered', errorTitle: null,
        errorCode: null, reason: null, simulated: true, updatedAt: nowMs });
    }
    assert.equal(fetchCalls.length, 0);
    const ledgers = [...db.docs.entries()].filter(([key]) => key.startsWith('_dinnerNotifications/'));
    for (const [, ledger] of ledgers) {
      assert.equal(ledger.simulated, true);
      assert.deepEqual(ledger.statusHistory.map((h) => h.status), ['submitted', 'delivered']);
    }
    const indexes = [...db.docs.keys()].filter((key) => key.startsWith('_dinnerProviderMessages/'));
    assert.equal(indexes.length, 2);
    // Simulations still count toward the hourly limit.
    const limit = [...db.docs.entries()].find(([key]) => key.startsWith('_dinnerSendLimits/'))[1];
    assert.equal(limit.count, 2);
  } finally {
    globalThis.fetch = originalFetch;
  }
});

test('simulateOutcome rejected and the simulateFailure alias produce the same rejection', async () => {
  for (const body of [{ simulateOutcome: 'rejected' }, { simulateFailure: true },
    { simulateFailure: true, simulateOutcome: 'rejected' }]) {
    const { service, db, sent } = harness({ settings: { ...settings, enabled: false, allowSimulation: true } });
    const result = await service('cook-1', input(body));
    assert.equal(result.deliveryStatus, 'rejected');
    assert.equal(mirror(db).errorCode, '1120');
    assert.equal(mirror(db).simulated, true);
    assert.equal(sent.length, 0);
  }
});

test('simulation is refused unless explicitly enabled', async () => {
  for (const body of [{ simulateFailure: true }, { simulateOutcome: 'delivered' }, { simulateOutcome: 'rejected' }]) {
    const { service, sent, db } = harness({ settings: { ...settings, enabled: false } });
    await assert.rejects(service('cook-1', input(body)), { code: 'simulation-disabled', status: 403 });
    assert.equal(sent.length, 0);
    assert.equal(db.docs.size, 1);
  }
});

test('simulations are rate limited like real sends', async () => {
  const { service } = harness({ settings: { ...settings, allowSimulation: true } });
  for (let i = 0; i < SEND_LIMIT_PER_HOUR; i++) {
    await service('cook-1', input({ notificationId: `sim-notice-${i}`, sessionId: 'meal-1',
      recipient: '+14075550100', simulateOutcome: 'rejected' }));
  }
  await assert.rejects(service('cook-1', input({ notificationId: 'sim-notice-x', simulateOutcome: 'delivered' })),
    { code: 'rate-limited', status: 429 });
});

for (const [label, event, expected] of [
  ['rejected', { status: 'rejected', errorTitle: 'Illegal Sender Address', errorCode: '1120' },
    { status: 'rejected', errorTitle: 'Illegal Sender Address', errorCode: '1120' }],
  ['delivered', { status: 'delivered' }, { status: 'delivered', errorTitle: null, errorCode: null }],
]) {
  test(`a verified ${label} callback arriving before the send response is applied at settle`, async () => {
    const db = fakeFirestore();
    const applyStatus = createDeliveryStatusStore(db);
    let sends = 0;
    const service = createDinnerService({ ledger: createDinnerLedger(db), settings, now: () => nowMs, applyStatus,
      sendMessage: async () => {
        sends++;
        if (sends > 1) return { status: 'submitted', providerMessageId: `later-uuid-${sends}` };
        // Vonage's callback lands while the send request is still in flight.
        assert.deepEqual(await applyStatus({ messageUuid: 'fast-uuid', ...event }, nowMs),
          { matched: false, buffered: true });
        return { status: 'submitted', providerMessageId: 'fast-uuid' };
      } });
    const result = await service('cook-1', input());
    assert.equal(result.status, 'submitted');
    assert.deepEqual(mirror(db), { kind: 'ready', ...expected, reason: null, simulated: false, updatedAt: nowMs });
    const ledger = [...db.docs.entries()].find(([key]) => key.startsWith('_dinnerNotifications/'))[1];
    assert.equal(ledger.deliveryStatus, label);
    assert.equal(ledger.status, 'submitted');
    assert.equal(db.docs.has(`_dinnerPendingStatus/${providerIndexId('fast-uuid')}`), false);
    // Later callbacks for the same UUID now match directly and stay monotonic.
    assert.equal((await applyStatus({ messageUuid: 'fast-uuid', status: 'submitted' }, nowMs + 1)).applied, false);
    if (label === 'rejected') {
      // Recovery: a known failure frees the slot for a NEW cook-confirmed ID.
      const retry = await service('cook-1', input({ notificationId: 'notice-456' }));
      assert.equal(retry.status, 'submitted');
      assert.equal(retry.duplicate, false);
    }
  });
}

test('dry-run skips provider and keeps a terminal, repeatable result', async () => {
  const { service, sent, db } = harness({ settings: { ...settings, enabled: false } });
  const result = await service('cook-1', input());
  assert.equal(result.status, 'skipped');
  assert.equal(result.reason, 'dry-run');
  assert.equal((await service('cook-1', input())).status, 'skipped');
  assert.equal(mirror(db).status, 'skipped');
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

test('provider payload uses sandbox or SMS endpoint, Basic auth and optional status webhook', async () => {
  for (const [channel, webhookUrl] of [['whatsapp', ''], ['sms', 'https://example.web.app/api/vonage-status']]) {
    const request = validateDinnerRequest(input(), settings.allowedRecipients);
    const result = await sendVonageDinner({ request, channel, webhookUrl,
      credentials: { apiKey: 'key', apiSecret: 'secret', from: '+14075550999' },
      fetchImpl: async (url, options) => {
        assert.equal(url, channel === 'whatsapp'
          ? 'https://messages-sandbox.nexmo.com/v1/messages' : 'https://api.nexmo.com/v1/messages');
        assert.equal(options.headers.Authorization, `Basic ${Buffer.from('key:secret').toString('base64')}`);
        assert.deepEqual(JSON.parse(options.body), {
          channel, message_type: 'text', to: '14075550100', from: '14075550999',
          text: READY_TEXT, client_ref: request.notificationId,
          ...(webhookUrl ? { webhook_url: webhookUrl, webhook_version: 'v1' } : {}),
        });
        assert.equal(options.redirect, 'error');
        return new Response(JSON.stringify({ message_uuid: 'abc-123' }), { status: 202 });
      },
    });
    assert.deepEqual(result, { status: 'submitted', providerMessageId: 'abc-123' });
  }
});

test('nonnumeric senders are rejected before transport for both channels', async () => {
  const request = validateDinnerRequest(input(), settings.allowedRecipients);
  let calls = 0;
  for (const channel of ['sms', 'whatsapp']) {
    for (const from of ['Vonage APIs', 'vonage apis', ' Vonage APIs', 'Vonage APIs ', 'SousSight']) {
      assert.deepEqual(await sendVonageDinner({ request, channel,
        credentials: { apiKey: 'key', apiSecret: 'secret', from },
        fetchImpl: async () => { calls++; throw new Error('Unexpected provider call'); },
      }), { status: 'failed', reason: 'invalid-sender' });
    }
  }
  assert.equal(calls, 0);
  assert.throws(() => validateDinnerRequest({ ...input(), from: 'Vonage APIs' }, settings.allowedRecipients),
    { code: 'invalid-request' });
});

test('disabled SMS trial service never contacts provider', async () => {
  let calls = 0;
  const { service } = harness({
    settings: { ...settings, channel: 'sms', enabled: false },
    sendMessage: ({ request, channel }) => sendVonageDinner({ request, channel,
      credentials: { apiKey: 'key', apiSecret: 'secret', from: '+14075550999' },
      fetchImpl: async () => { calls++; throw new Error('Unexpected provider call'); },
    }),
  });
  const result = await service('cook-1', input());
  assert.equal(result.status, 'skipped');
  assert.equal(calls, 0);
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
});

test('HTTP gate requires Auth and App Check and maps 429 Retry-After', async () => {
  let calls = 0;
  let fail = null;
  const handler = createDinnerReadyHandler({
    verifyAuth: async (token) => { assert.equal(token, 'id-token'); return { uid: 'cook-1' }; },
    verifyAppCheck: async (token) => { if (token !== 'valid-app') throw new Error('bad app'); },
    allowedOrigins: new Set(['https://example.com']),
    service: async (uid, body) => {
      calls++; assert.equal(uid, 'cook-1'); assert.deepEqual(body, input());
      if (fail) throw fail;
      return { status: 'skipped' };
    },
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
  assert.equal(result.headers['Cache-Control'], 'no-store, private');
  try { nextSendLimit({ windowStartedAt: nowMs, count: 5 }, nowMs + 60_000); }
  catch (error) { fail = error; }
  const limited = res();
  await handler(req(), limited);
  assert.equal(limited.code, 429);
  assert.equal(limited.body.error.code, 'rate-limited');
  assert.equal(limited.headers['Retry-After'], String(59 * 60));
});
