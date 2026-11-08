import { createHash, randomUUID } from 'node:crypto';
import { TokenRequestError as HttpError } from './live-token.js';
import {
  foldStatus, mirrorFor, newStatusToken, notificationPath, pendingStatusPath, providerIndexId, statusTokenHash,
} from './vonage-status.js';

const sha256 = (text) => createHash('sha256').update(text).digest('hex');
const publicStatuses = new Set(['submitted', 'skipped', 'failed', 'unknown']);
const DELIVERY_FAILURES = new Set(['rejected', 'undeliverable']);
export const DINNER_KINDS = ['started', 'ready'];
export const SEND_LIMIT_PER_HOUR = 5;
const HOUR_MS = 60 * 60_000;
const REQUEST_KEYS = ['sessionId', 'notificationId', 'recipient', 'kind', 'recipeTitle',
  'minutes', 'cookName', 'simulateFailure', 'simulateOutcome'];
export const SIMULATED_OUTCOMES = ['delivered', 'rejected'];

// Simulated Vonage outcome for the demo. Error 1120 is the rejection this
// account actually recorded for a non-numeric sender (see README).
export const SIMULATED_FAILURE = Object.freeze({
  status: 'rejected',
  errorTitle: 'Illegal Sender Address',
  errorCode: '1120',
  detail: 'Simulated: Vonage error 1120',
});

/** Synthetic status callbacks for each demo outcome, applied in order through
 * the same status function a signed Vonage webhook uses. */
export const SIMULATED_EVENTS = Object.freeze({
  delivered: [{ status: 'submitted' }, { status: 'delivered' }],
  rejected: [{ status: SIMULATED_FAILURE.status, errorTitle: SIMULATED_FAILURE.errorTitle,
    errorCode: SIMULATED_FAILURE.errorCode }],
});

export function normalizeRecipient(value) {
  if (typeof value !== 'string' || !/^\+?[1-9][0-9]{7,14}$/.test(value)) {
    throw new HttpError('invalid-recipient', 400, 'Use a phone number with its country code.');
  }
  return value.replace(/^\+/, '');
}

/** Keeps letters, numbers, spaces and a little punctuation. No links, markup,
 * control characters or free-form sentences can reach the household. */
export function cleanTemplateText(value, maxLength) {
  if (typeof value !== 'string') return '';
  return value.replace(/[^\p{L}\p{N} '&,()!-]/gu, ' ').replace(/\s+/g, ' ').trim()
    .slice(0, maxLength).trim();
}

/** Server-owned templates. The client supplies only the slots. */
export function composeDinnerMessage({ kind, recipeTitle, minutes, cookName }) {
  if (kind === 'started') {
    return `SousSight: ${cookName || 'Your cook'} started ${recipeTitle}. Dinner in about ${minutes} min.`;
  }
  return `SousSight: Dinner is ready! ${recipeTitle} is on the table.`;
}

function invalid() {
  return new HttpError('invalid-request', 400,
    'Provide the session, notification ID, recipient, message kind, and recipe title.');
}

export function validateDinnerRequest(body, allowedRecipients) {
  if (!body || typeof body !== 'object' || Array.isArray(body) ||
      Object.keys(body).some((key) => !REQUEST_KEYS.includes(key)) ||
      typeof body.sessionId !== 'string' || !/^[A-Za-z0-9_-]{1,128}$/.test(body.sessionId) ||
      typeof body.notificationId !== 'string' || !/^[A-Za-z0-9_-]{8,100}$/.test(body.notificationId) ||
      !DINNER_KINDS.includes(body.kind) ||
      typeof body.recipeTitle !== 'string' || body.recipeTitle.length > 200 ||
      (body.cookName !== undefined && body.cookName !== null &&
        (typeof body.cookName !== 'string' || body.cookName.length > 80)) ||
      (body.simulateFailure !== undefined && typeof body.simulateFailure !== 'boolean') ||
      (body.simulateOutcome !== undefined && body.simulateOutcome !== null &&
        !SIMULATED_OUTCOMES.includes(body.simulateOutcome)) ||
      // The legacy alias means "rejected"; a contradictory pair is ambiguous.
      (body.simulateFailure === true && body.simulateOutcome && body.simulateOutcome !== 'rejected')) {
    throw invalid();
  }
  const simulateOutcome = body.simulateOutcome || (body.simulateFailure === true ? 'rejected' : null);
  const recipeTitle = cleanTemplateText(body.recipeTitle, 60);
  if (!recipeTitle) throw invalid();
  let minutes = null;
  if (body.kind === 'started') {
    if (!Number.isInteger(body.minutes) || body.minutes < 1 || body.minutes > 120) throw invalid();
    minutes = body.minutes;
  } else if (body.minutes !== undefined && body.minutes !== null) {
    throw invalid();
  }
  const cookName = body.kind === 'started' ? cleanTemplateText(body.cookName ?? '', 30) || null : null;
  const recipient = normalizeRecipient(body.recipient);
  const allowed = new Set(allowedRecipients.map(normalizeRecipient));
  if (!allowed.has(recipient)) {
    throw new HttpError('recipient-not-allowed', 403, 'This recipient has not been enabled for the demo.');
  }
  const slots = { kind: body.kind, recipeTitle, minutes, cookName };
  return { sessionId: body.sessionId, notificationId: body.notificationId, recipient,
    ...slots, simulateOutcome, message: composeDinnerMessage(slots) };
}

export function nextSendLimit(previous, nowMs, limit = SEND_LIMIT_PER_HOUR) {
  const valid = previous && Number.isFinite(previous.windowStartedAt) && Number.isInteger(previous.count);
  const inWindow = valid && nowMs >= previous.windowStartedAt && nowMs - previous.windowStartedAt < HOUR_MS;
  if (inWindow && previous.count >= limit) {
    throw new HttpError('rate-limited', 429, 'Too many household messages this hour.',
      Math.max(1, Math.ceil((HOUR_MS - (nowMs - previous.windowStartedAt)) / 1000)));
  }
  return { windowStartedAt: inWindow ? previous.windowStartedAt : nowMs, count: inWindow ? previous.count + 1 : 1 };
}

const isKnownFailure = (record) =>
  record?.status === 'failed' || DELIVERY_FAILURES.has(record?.deliveryStatus);

/** Firestore owns the claim. Once pending, an attempt can never be retried
 * automatically, including after a worker crash or an ambiguous provider reply. */
export function createDinnerLedger(db) {
  return {
    async claim({ uid, request, channel, nowMs }) {
      const key = sha256(`${uid}\n${request.notificationId}`);
      const fingerprint = sha256(JSON.stringify({ ...request, channel }));
      const ref = db.collection('_dinnerNotifications').doc(key);
      const sessionRef = db.collection('sessions').doc(request.sessionId);
      // One message of each kind per session/recipient prevents a fresh ID from
      // bypassing an uncertain attempt. Only a KNOWN failure frees the slot, and
      // only for a new, cook-confirmed notification ID.
      const mealRef = db.collection('_dinnerMealClaims').doc(
        sha256(`${uid}\n${request.sessionId}\n${request.recipient}\n${request.kind}`));
      const limitRef = db.collection('_dinnerSendLimits').doc(sha256(uid));
      const mirrorRef = db.doc(notificationPath(request.sessionId, request.notificationId));
      return db.runTransaction(async (transaction) => {
        const [session, existing, meal, limit] = await Promise.all([
          transaction.get(sessionRef), transaction.get(ref), transaction.get(mealRef), transaction.get(limitRef),
        ]);
        if (!session.exists || session.data().learnerId !== uid) {
          throw new HttpError('session-not-owned', 403, 'This cooking session does not belong to you.');
        }
        if (existing.exists) {
          const record = existing.data();
          if (record.fingerprint !== fingerprint) {
            throw new HttpError('idempotency-conflict', 409, 'This notification ID already belongs to a different message.');
          }
          return { key, claimed: false, record };
        }
        if (meal.exists) {
          const priorKey = meal.data().ledgerKey ?? sha256(`${uid}\n${meal.data().notificationId}`);
          const prior = await transaction.get(db.collection('_dinnerNotifications').doc(priorKey));
          if (!prior.exists || !isKnownFailure(prior.data())) {
            throw new HttpError('meal-already-notified', 409,
              'A message of this kind already exists for this meal. Check its status instead of sending again.');
          }
        }
        const nextLimit = nextSendLimit(limit.exists ? limit.data() : null, nowMs);
        const record = { fingerprint, status: 'pending', channel, kind: request.kind,
          sessionId: request.sessionId, notificationId: request.notificationId,
          simulated: Boolean(request.simulateOutcome), createdAt: nowMs, updatedAt: nowMs };
        transaction.create(ref, record);
        transaction.set(mealRef, { notificationId: request.notificationId, ledgerKey: key, createdAt: nowMs });
        transaction.set(limitRef, nextLimit);
        transaction.set(mirrorRef, { kind: request.kind, status: 'pending', errorTitle: null,
          errorCode: null, reason: null, simulated: Boolean(request.simulateOutcome), updatedAt: nowMs });
        return { key, claimed: true, record };
      });
    },
    async settle(key, result, nowMs) {
      const ref = db.collection('_dinnerNotifications').doc(key);
      await db.runTransaction(async (transaction) => {
        const snapshot = await transaction.get(ref);
        if (!snapshot.exists || snapshot.data().status !== 'pending') return;
        const record = snapshot.data();
        const { providerMessageId, statusTokenHash: tokenHash, ...stored } = result;
        // Status callbacks that arrived before this index existed were buffered;
        // fold them in now so a fast rejection/delivery is never lost. Only the
        // signed buffer and the buffer keyed by THIS message's token hash are
        // read, so a callback presenting any other token is never applied.
        const pendingRefs = providerMessageId
          ? [db.doc(pendingStatusPath(providerMessageId)),
            ...(tokenHash ? [db.doc(pendingStatusPath(providerMessageId, tokenHash))] : [])]
          : [];
        const pendings = [];
        for (const pendingRef of pendingRefs) pendings.push([pendingRef, await transaction.get(pendingRef)]);
        let folded = { ...record, ...stored };
        for (const [, pending] of pendings) {
          const data = pending.exists ? pending.data() : null;
          if (!data || !Array.isArray(data.events)) continue;
          // Defence in depth: the key already binds the hash; re-check it.
          if (data.tokenHash !== undefined && data.tokenHash !== tokenHash) continue;
          for (const event of data.events) folded = { ...folded, ...(foldStatus(folded, event, nowMs) ?? {}) };
        }
        const delivery = folded.deliveryStatus
          ? { deliveryStatus: folded.deliveryStatus, statusHistory: folded.statusHistory,
            errorTitle: folded.errorTitle ?? null, errorCode: folded.errorCode ?? null }
          : {};
        transaction.update(ref, { ...stored, ...delivery, updatedAt: nowMs,
          ...(tokenHash ? { statusTokenHash: tokenHash } : {}),
          ...(providerMessageId ? { providerMessageHash: providerIndexId(providerMessageId) } : {}) });
        for (const [pendingRef, pending] of pendings) if (pending.exists) transaction.delete(pendingRef);
        if (providerMessageId) {
          // Status webhooks carry only message_uuid; this index maps it back.
          transaction.set(db.collection('_dinnerProviderMessages').doc(providerIndexId(providerMessageId)), {
            ledgerKey: key, sessionId: record.sessionId, notificationId: record.notificationId,
            simulated: record.simulated === true, createdAt: nowMs,
            // sha256 of the per-message capability token; never the token.
            ...(tokenHash ? { statusTokenHash: tokenHash } : {}),
          });
        }
        if (record.sessionId) {
          transaction.set(db.doc(notificationPath(record.sessionId, record.notificationId)),
            folded.deliveryStatus
              ? { ...mirrorFor(folded, record.simulated, nowMs), reason: result.reason ?? null }
              : { kind: record.kind ?? 'ready', status: result.status, reason: result.reason ?? null,
                simulated: record.simulated === true, updatedAt: nowMs },
            { merge: true });
        }
      });
    },
  };
}

/** Returns a reason code when the provider cannot be used, else null. */
export function providerConfigProblem(credentials) {
  if (!credentials?.apiKey || !credentials?.apiSecret || !credentials?.from) return 'not-configured';
  try { normalizeRecipient(credentials.from); }
  catch { return 'invalid-sender'; }
  return null;
}

/** Per-message status URL for a capability token, or '' when the base URL is
 * unset/invalid. The base must be https with no path, query or fragment. */
export function statusWebhookUrl(baseUrl, statusToken) {
  const base = String(baseUrl ?? '').trim().replace(/\/+$/, '');
  if (!/^https:\/\/[A-Za-z0-9.-]+(:\d+)?$/.test(base)) return '';
  if (typeof statusToken !== 'string' || !/^[A-Za-z0-9_-]{43}$/.test(statusToken)) return '';
  return `${base}/api/vonage-status/${statusToken}`;
}

export async function sendVonageDinner({ request, channel, credentials, webhookUrl = '', fetchImpl = fetch }) {
  if (!['whatsapp', 'sms'].includes(channel)) {
    return { status: 'failed', reason: 'unsupported-channel' };
  }
  const problem = providerConfigProblem(credentials);
  if (problem) return { status: 'failed', reason: problem };
  // Use the numeric sender verified for this account; dashboard labels are not sender approval.
  const from = normalizeRecipient(credentials.from);
  const endpoint = channel === 'whatsapp'
    ? 'https://messages-sandbox.nexmo.com/v1/messages'
    : 'https://api.nexmo.com/v1/messages';
  const payload = { channel, message_type: 'text', to: request.recipient,
    from, text: request.message, client_ref: request.notificationId };
  // Per-message status URL overrides dashboard settings:
  // https://developer.vonage.com/en/api/messages (webhook_url, webhook_version)
  if (webhookUrl) Object.assign(payload, { webhook_url: webhookUrl, webhook_version: 'v1' });
  try {
    const response = await fetchImpl(endpoint, {
      method: 'POST',
      headers: {
        Authorization: `Basic ${Buffer.from(`${credentials.apiKey}:${credentials.apiSecret}`).toString('base64')}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify(payload),
      signal: AbortSignal.timeout(12_000), redirect: 'error',
    });
    if (response.status === 202) {
      const data = await response.json();
      if (typeof data.message_uuid === 'string' &&
          /^[A-Za-z0-9-]{1,100}$/.test(data.message_uuid)) {
        // API acceptance is not delivery. Only verified status callbacks
        // (vonageStatus) promote this to delivered/read/rejected.
        return { status: 'submitted', providerMessageId: data.message_uuid };
      }
      return { status: 'unknown', reason: 'accepted-without-message-id' };
    }
    // A 408/5xx/transport failure may occur after acceptance. Never blind retry.
    if (response.status >= 400 && response.status < 500 && response.status !== 408) {
      return { status: 'failed', reason: `provider-rejected-${response.status}` };
    }
    return { status: 'unknown', reason: 'ambiguous-provider-response' };
  } catch {
    return { status: 'unknown', reason: 'provider-response-unavailable' };
  }
}

export function createDinnerService({ ledger, sendMessage, applyStatus, settings, now = Date.now }) {
  return async (uid, body) => {
    const request = validateDinnerRequest(body, settings.allowedRecipients);
    if (!['whatsapp', 'sms'].includes(settings.channel)) {
      throw new HttpError('not-configured', 503, 'Dinner messaging is not configured yet.');
    }
    const simulation = request.simulateOutcome;
    if (simulation && settings.allowSimulation !== true) {
      throw new HttpError('simulation-disabled', 403, 'Delivery simulation is disabled.');
    }
    // Reject known configuration problems BEFORE claiming, so fixing them does
    // not leave the meal slot locked by an attempt that never reached Vonage.
    if (!simulation && settings.enabled && settings.checkProvider?.()) {
      throw new HttpError('not-configured', 503, 'Dinner messaging is not configured yet.');
    }
    const claim = await ledger.claim({ uid, request, channel: settings.channel, nowMs: now() });
    const base = { notificationId: request.notificationId, kind: request.kind, message: request.message,
      simulated: Boolean(simulation) };
    if (!claim.claimed) {
      return { ...base, status: publicStatuses.has(claim.record.status) ? claim.record.status : 'unknown',
        channel: claim.record.channel, duplicate: true,
        deliveryStatus: claim.record.deliveryStatus ?? null,
        reason: claim.record.reason ?? (claim.record.status === 'pending' ? 'attempt-in-progress-or-unconfirmed' : null) };
    }
    let result;
    if (simulation) {
      // Demo path: Vonage is never contacted. A synthetic message UUID flows
      // through the same ledger, index and status function as a real callback.
      result = { status: 'submitted', providerMessageId: `sim-${randomUUID()}` };
    } else if (!settings.enabled) result = { status: 'skipped', reason: 'dry-run' };
    else {
      // Per-message capability for the status webhook. Only its hash is kept.
      const statusToken = newStatusToken();
      try { result = await sendMessage({ request, channel: settings.channel, statusToken }); }
      catch { result = { status: 'unknown', reason: 'provider-response-unavailable' }; }
      if (!result || !publicStatuses.has(result.status)) {
        result = { status: 'unknown', reason: 'invalid-provider-result' };
      }
      result = { ...result, statusTokenHash: statusTokenHash(statusToken) };
    }
    try { await ledger.settle(claim.key, result, now()); }
    catch {
      // The pending claim remains durable. Repeating it will NOT resend.
      return { ...base, status: 'unknown', channel: settings.channel, duplicate: false,
        deliveryStatus: null, reason: 'status-not-persisted' };
    }
    let deliveryStatus = null;
    if (simulation) {
      try {
        for (const event of SIMULATED_EVENTS[simulation]) {
          const applied = await applyStatus({ messageUuid: result.providerMessageId, ...event }, now());
          deliveryStatus = applied?.status ?? deliveryStatus;
        }
      } catch { /* Mirror keeps its last applied status; the UI shows that honestly. */ }
    }
    return { ...base, status: result.status, channel: settings.channel, duplicate: false,
      deliveryStatus, reason: result.reason ?? null };
  };
}

export function createDinnerReadyHandler({ verifyAuth, verifyAppCheck, service, allowedOrigins }) {
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
      return res.status(204).end();
    }
    if (req.method !== 'POST') {
      res.set('Allow', 'POST');
      return res.status(405).json({ error: { code: 'method-not-allowed', message: 'Use POST.' } });
    }
    const match = /^Bearer ([^\s]{1,16384})$/.exec(req.get('Authorization') ?? '');
    const appToken = req.get('X-Firebase-AppCheck');
    let uid;
    try {
      if (!match || !appToken || appToken.length > 16_384) throw new Error('Missing credentials');
      const [identity] = await Promise.all([verifyAuth(match[1]), verifyAppCheck(appToken)]);
      uid = identity.uid;
      if (typeof uid !== 'string' || !uid || uid.length > 128) throw new Error('Invalid identity');
    } catch {
      return res.status(401).json({ error: { code: 'unauthenticated', message: 'Sign in and verify this app first.' } });
    }
    try { return res.status(200).json(await service(uid, req.body)); }
    catch (error) {
      const known = error instanceof HttpError;
      if (known && error.retryAfterSeconds) res.set('Retry-After', String(error.retryAfterSeconds));
      return res.status(known ? error.status : 503).json({ error: {
        code: known ? error.code : 'temporarily-unavailable',
        message: known ? error.message : 'Could not verify notification status. Retry with the same notification ID.',
      } });
    }
  };
}
