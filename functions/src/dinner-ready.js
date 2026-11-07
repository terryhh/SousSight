import { createHash } from 'node:crypto';
import { TokenRequestError as HttpError } from './live-token.js';

const sha256 = (text) => createHash('sha256').update(text).digest('hex');
const publicStatuses = new Set(['submitted', 'skipped', 'failed', 'unknown']);

export function normalizeRecipient(value) {
  if (typeof value !== 'string' || !/^\+?[1-9][0-9]{7,14}$/.test(value)) {
    throw new HttpError('invalid-recipient', 400, 'Use a phone number with its country code.');
  }
  return value.replace(/^\+/, '');
}

export function validateDinnerRequest(body, allowedRecipients) {
  if (!body || typeof body !== 'object' || Array.isArray(body) ||
      Object.keys(body).some((key) => !['sessionId', 'notificationId', 'recipient', 'message'].includes(key)) ||
      typeof body.sessionId !== 'string' || !/^[A-Za-z0-9_-]{1,128}$/.test(body.sessionId) ||
      typeof body.notificationId !== 'string' || !/^[A-Za-z0-9_-]{8,100}$/.test(body.notificationId) ||
      typeof body.message !== 'string' || body.message.trim().length === 0 ||
      body.message.length > 320 || /[\u0000-\u0008\u000b\u000c\u000e-\u001f]/.test(body.message)) {
    throw new HttpError('invalid-request', 400, 'Provide the session, notification ID, recipient, and a message of up to 320 characters.');
  }
  const recipient = normalizeRecipient(body.recipient);
  const allowed = new Set(allowedRecipients.map(normalizeRecipient));
  if (!allowed.has(recipient)) {
    throw new HttpError('recipient-not-allowed', 403, 'This recipient has not been enabled for the demo.');
  }
  return { sessionId: body.sessionId, notificationId: body.notificationId,
    recipient, message: body.message };
}

/** Firestore owns the claim. Once pending, an attempt can never be retried
 * automatically, including after a worker crash or an ambiguous provider reply. */
export function createDinnerLedger(db) {
  return {
    async claim({ uid, request, channel, nowMs }) {
      const key = sha256(`${uid}\n${request.notificationId}`);
      const fingerprint = sha256(JSON.stringify({ ...request, channel }));
      const ref = db.collection('_dinnerNotifications').doc(key);
      const sessionRef = db.collection('sessions').doc(request.sessionId);
      // One dinner announcement per session/recipient prevents a fresh ID from
      // accidentally bypassing an uncertain attempt. A new meal uses a new session.
      const mealRef = db.collection('_dinnerMealClaims').doc(
        sha256(`${uid}\n${request.sessionId}\n${request.recipient}`));
      return db.runTransaction(async (transaction) => {
        const [session, existing, meal] = await Promise.all([
          transaction.get(sessionRef), transaction.get(ref), transaction.get(mealRef),
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
          throw new HttpError('meal-already-notified', 409,
            'A dinner notification already exists for this meal. Check its status instead of sending again.');
        }
        const record = { fingerprint, status: 'pending', channel,
          notificationId: request.notificationId, createdAt: nowMs, updatedAt: nowMs };
        transaction.create(ref, record);
        transaction.create(mealRef, { notificationId: request.notificationId, createdAt: nowMs });
        return { key, claimed: true, record };
      });
    },
    async settle(key, result, nowMs) {
      const ref = db.collection('_dinnerNotifications').doc(key);
      await db.runTransaction(async (transaction) => {
        const snapshot = await transaction.get(ref);
        if (!snapshot.exists || snapshot.data().status !== 'pending') return;
        transaction.update(ref, { ...result, updatedAt: nowMs });
      });
    },
  };
}

export async function sendVonageDinner({ request, channel, credentials, fetchImpl = fetch }) {
  if (!['whatsapp', 'sms'].includes(channel)) {
    return { status: 'failed', reason: 'unsupported-channel' };
  }
  if (!credentials.apiKey || !credentials.apiSecret || !credentials.from) {
    return { status: 'failed', reason: 'not-configured' };
  }
  let from;
  try { from = normalizeRecipient(credentials.from); }
  catch { return { status: 'failed', reason: 'invalid-sender' }; }
  const endpoint = channel === 'whatsapp'
    ? 'https://messages-sandbox.nexmo.com/v1/messages'
    : 'https://api.nexmo.com/v1/messages';
  try {
    const response = await fetchImpl(endpoint, {
      method: 'POST',
      headers: {
        Authorization: `Basic ${Buffer.from(`${credentials.apiKey}:${credentials.apiSecret}`).toString('base64')}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({ channel, message_type: 'text', to: request.recipient,
        from, text: request.message, client_ref: request.notificationId }),
      signal: AbortSignal.timeout(12_000), redirect: 'error',
    });
    if (response.status === 202) {
      const data = await response.json();
      if (typeof data.message_uuid === 'string' &&
          /^[A-Za-z0-9-]{1,100}$/.test(data.message_uuid)) {
        // API acceptance is not delivery. Only verified status callbacks could
        // promote this state; this demo does not implement that promotion.
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

export function createDinnerService({ ledger, sendMessage, settings, now = Date.now }) {
  return async (uid, body) => {
    const request = validateDinnerRequest(body, settings.allowedRecipients);
    if (!['whatsapp', 'sms'].includes(settings.channel)) {
      throw new HttpError('not-configured', 503, 'Dinner messaging is not configured yet.');
    }
    const claim = await ledger.claim({ uid, request, channel: settings.channel, nowMs: now() });
    if (!claim.claimed) {
      return { notificationId: request.notificationId,
        status: publicStatuses.has(claim.record.status) ? claim.record.status : 'unknown',
        channel: claim.record.channel, duplicate: true,
        reason: claim.record.reason ?? (claim.record.status === 'pending' ? 'attempt-in-progress-or-unconfirmed' : null) };
    }
    let result;
    if (!settings.enabled) result = { status: 'skipped', reason: 'dry-run' };
    else {
      try { result = await sendMessage({ request, channel: settings.channel }); }
      catch { result = { status: 'unknown', reason: 'provider-response-unavailable' }; }
      if (!result || !publicStatuses.has(result.status)) {
        result = { status: 'unknown', reason: 'invalid-provider-result' };
      }
    }
    try { await ledger.settle(claim.key, result, now()); }
    catch {
      // The pending claim remains durable. Repeating it will NOT resend.
      return { notificationId: request.notificationId, status: 'unknown',
        channel: settings.channel, duplicate: false, reason: 'status-not-persisted' };
    }
    return { notificationId: request.notificationId, status: result.status,
      channel: settings.channel, duplicate: false, reason: result.reason ?? null };
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
      return res.status(known ? error.status : 503).json({ error: {
        code: known ? error.code : 'temporarily-unavailable',
        message: known ? error.message : 'Could not verify notification status. Retry with the same notification ID.',
      } });
    }
  };
}
