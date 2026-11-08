import { createHash, createHmac, timingSafeEqual } from 'node:crypto';

// Vonage Messages API status webhooks.
//
// Payload (Messages API v1 "Message Status"):
//   https://developer.vonage.com/en/api/messages (Webhooks > Message Status)
//   { message_uuid, to, from, timestamp, status, error?: {type, title, detail, instance},
//     channel, client_ref?, usage? }
//   status: submitted | delivered | rejected | undeliverable (all channels);
//   WhatsApp/RCS/Messenger/Viber may also report `read`.
// Signed webhooks:
//   https://developer.vonage.com/en/getting-started/concepts/webhooks#decoding-signed-webhooks
//   https://developer.vonage.com/en/messages/concepts/signed-webhooks
//   The Authorization header carries an HS256 JWT signed with the account
//   *signature secret* (Dashboard > Settings), with claims iat, jti, iss,
//   api_key, application_id? and payload_hash (SHA-256 of the request body).

const sha256Hex = (value) => createHash('sha256').update(value).digest('hex');
export const DELIVERY_STATUSES = new Set(['submitted', 'delivered', 'read', 'rejected', 'undeliverable']);
const FAILURES = new Set(['rejected', 'undeliverable']);
const RANK = { submitted: 1, delivered: 2, read: 3 };
export const MAX_JWT_AGE_SECONDS = 300;
const MAX_CLOCK_SKEW_SECONDS = 60;

export class WebhookAuthError extends Error {
  constructor(code) { super(code); this.code = code; }
}

function base64UrlJson(part) {
  if (!/^[A-Za-z0-9_-]+$/.test(part)) throw new WebhookAuthError('malformed-token');
  try { return JSON.parse(Buffer.from(part, 'base64url').toString('utf8')); }
  catch { throw new WebhookAuthError('malformed-token'); }
}

/** Verifies a Vonage signed-webhook JWT against the exact raw request body.
 * Throws WebhookAuthError on any failure; never returns partial trust. */
export function verifyVonageSignature({ authorization, rawBody, secret, nowMs }) {
  if (typeof secret !== 'string' || secret.length === 0) throw new WebhookAuthError('not-configured');
  if (typeof authorization !== 'string' || authorization.length === 0) throw new WebhookAuthError('unsigned');
  const token = authorization.replace(/^Bearer\s+/i, '').trim();
  const parts = token.split('.');
  if (token.length > 8192 || parts.length !== 3) throw new WebhookAuthError('malformed-token');
  const header = base64UrlJson(parts[0]);
  // Pin the algorithm. Never honour `none` or asymmetric algorithms here.
  if (!header || header.alg !== 'HS256') throw new WebhookAuthError('bad-algorithm');
  if (!/^[A-Za-z0-9_-]+$/.test(parts[2])) throw new WebhookAuthError('malformed-token');
  const expected = createHmac('sha256', secret).update(`${parts[0]}.${parts[1]}`).digest();
  const actual = Buffer.from(parts[2], 'base64url');
  if (actual.length !== expected.length || !timingSafeEqual(actual, expected)) {
    throw new WebhookAuthError('bad-signature');
  }
  const claims = base64UrlJson(parts[1]);
  const nowSeconds = Math.floor(nowMs / 1000);
  if (!claims || !Number.isFinite(claims.iat) ||
      claims.iat < nowSeconds - MAX_JWT_AGE_SECONDS || claims.iat > nowSeconds + MAX_CLOCK_SKEW_SECONDS) {
    throw new WebhookAuthError('stale-token');
  }
  if (claims.exp !== undefined && (!Number.isFinite(claims.exp) || claims.exp < nowSeconds - MAX_CLOCK_SKEW_SECONDS)) {
    throw new WebhookAuthError('stale-token');
  }
  // Docs describe payload_hash as "a SHA-256 hash of the request payload";
  // Vonage samples compare lowercase hex. Require it so the body is bound to the
  // signature. The docs do not say whether the raw bytes or a re-serialised JSON
  // body is hashed, so accept either form of the SAME received body.
  const body = Buffer.isBuffer(rawBody) ? rawBody : Buffer.from(rawBody ?? '', 'utf8');
  const candidates = [sha256Hex(body)];
  try { candidates.push(sha256Hex(JSON.stringify(JSON.parse(body.toString('utf8'))))); }
  catch { /* raw hash only */ }
  const claimed = Buffer.from(String(claims.payload_hash ?? '').toLowerCase(), 'utf8');
  const matches = candidates.some((hash) => {
    const expectedHash = Buffer.from(hash, 'utf8');
    return claimed.length === expectedHash.length && timingSafeEqual(claimed, expectedHash);
  });
  if (!matches) throw new WebhookAuthError('payload-hash-mismatch');
  return claims;
}

function cleanError(error) {
  if (!error || typeof error !== 'object') return { errorTitle: null, errorCode: null };
  const title = typeof error.title === 'string'
    ? error.title.replace(/[^\p{L}\p{N} .,'()-]/gu, ' ').replace(/\s+/g, ' ').trim().slice(0, 80) || null
    : null;
  // Error `type` is a documentation link ending in the numeric error code.
  const code = typeof error.type === 'string' ? /#?(\d{3,5})$/.exec(error.type)?.[1] ?? null : null;
  return { errorTitle: title, errorCode: code };
}

/** Parses an untrusted (but signature-verified) status body into a minimal event. */
export function parseStatusEvent(body) {
  if (!body || typeof body !== 'object' || Array.isArray(body)) return null;
  const uuid = body.message_uuid;
  if (typeof uuid !== 'string' || !/^[A-Za-z0-9-]{1,100}$/.test(uuid)) return null;
  if (!DELIVERY_STATUSES.has(body.status)) return null;
  return { messageUuid: uuid, status: body.status, ...cleanError(body.error) };
}

/** Monotonic: never downgrade delivered/read, and failures are terminal. */
export function shouldAdvance(current, next) {
  if (!DELIVERY_STATUSES.has(next)) return false;
  if (!current) return true;
  if (FAILURES.has(current)) return false;
  if (FAILURES.has(next)) return !['delivered', 'read'].includes(current);
  return RANK[next] > (RANK[current] ?? 0);
}

export const providerIndexId = (messageUuid) => sha256Hex(messageUuid);
export const notificationPath = (sessionId, notificationId) =>
  `sessions/${sessionId}/notifications/${notificationId}`;

export const pendingStatusPath = (messageUuid) => `_dinnerPendingStatus/${providerIndexId(messageUuid)}`;
export const MAX_BUFFERED_EVENTS = 20;
const BUFFER_TTL_MS = 7 * 24 * 60 * 60_000;

/** Folds one status event into a ledger record. Returns null when the event
 * must not change anything (monotonic, failures terminal). */
export function foldStatus(record, event, nowMs) {
  if (!shouldAdvance(record.deliveryStatus ?? null, event.status)) return null;
  const failure = FAILURES.has(event.status);
  return {
    deliveryStatus: event.status,
    statusHistory: [...(Array.isArray(record.statusHistory) ? record.statusHistory : []),
      { status: event.status, at: nowMs }].slice(-20),
    updatedAt: nowMs,
    errorTitle: failure ? event.errorTitle ?? 'Not delivered' : null,
    errorCode: failure ? event.errorCode ?? null : null,
  };
}

/** Cook-readable mirror fields for a folded ledger state. */
export const mirrorFor = (record, simulated, nowMs) => ({
  kind: record.kind ?? 'ready', status: record.deliveryStatus,
  errorTitle: record.errorTitle ?? null, errorCode: record.errorCode ?? null,
  simulated: simulated === true, updatedAt: nowMs,
});

/** Applies a delivery status to the server ledger and the cook-readable mirror.
 * Shared by the signed webhook and the server-side demo simulation.
 *
 * A verified callback can arrive before the send response returns and `settle`
 * writes the provider index. Such events are buffered under
 * `_dinnerPendingStatus/{sha256(uuid)}` and folded in by `settle`, so a fast
 * rejection is never discarded. */
export function createDeliveryStatusStore(db) {
  return async function applyStatus(event, nowMs) {
    const indexRef = db.collection('_dinnerProviderMessages').doc(providerIndexId(event.messageUuid));
    const pendingRef = db.doc(pendingStatusPath(event.messageUuid));
    return db.runTransaction(async (transaction) => {
      const index = await transaction.get(indexRef);
      if (!index.exists) {
        const pending = await transaction.get(pendingRef);
        const prior = pending.exists && Array.isArray(pending.data().events) ? pending.data().events : [];
        transaction.set(pendingRef, {
          events: [...prior, { status: event.status, errorTitle: event.errorTitle ?? null,
            errorCode: event.errorCode ?? null, at: nowMs }].slice(-MAX_BUFFERED_EVENTS),
          createdAt: pending.exists ? pending.data().createdAt ?? nowMs : nowMs,
          updatedAt: nowMs, expireAt: new Date(nowMs + BUFFER_TTL_MS),
        });
        return { matched: false, buffered: true };
      }
      const { ledgerKey, sessionId, notificationId } = index.data();
      const ledgerRef = db.collection('_dinnerNotifications').doc(ledgerKey);
      const ledger = await transaction.get(ledgerRef);
      if (!ledger.exists) return { matched: false };
      const record = ledger.data();
      const update = foldStatus(record, event, nowMs);
      if (!update) return { matched: true, applied: false, status: record.deliveryStatus ?? null };
      transaction.update(ledgerRef, update);
      transaction.set(db.doc(notificationPath(sessionId, notificationId)),
        mirrorFor({ ...record, ...update }, index.data().simulated, nowMs), { merge: true });
      return { matched: true, applied: true, status: event.status };
    });
  };
}

export function createVonageStatusHandler({ secret, applyStatus, now = Date.now, report = () => {} }) {
  return async (req, res) => {
    res.set('Cache-Control', 'no-store');
    if (req.method !== 'POST') {
      res.set('Allow', 'POST');
      return res.status(405).json({ ok: false });
    }
    const nowMs = now();
    const rawBody = req.rawBody ?? Buffer.from(JSON.stringify(req.body ?? {}));
    try {
      verifyVonageSignature({ authorization: req.get('Authorization'), rawBody, secret: secret(), nowMs });
    } catch (error) {
      const code = error instanceof WebhookAuthError ? error.code : 'verify-failed';
      report('vonage-status-rejected', { code });
      // Vonage docs: an unsigned callback can follow a Vonage-side error and a
      // 5xx response makes Vonage retry it signed. Everything else is 401.
      if (code === 'unsigned' || code === 'not-configured') return res.status(503).json({ ok: false });
      return res.status(401).json({ ok: false });
    }
    let body;
    try { body = JSON.parse(Buffer.from(rawBody).toString('utf8')); }
    catch { return res.status(200).json({ ok: true, ignored: 'malformed' }); }
    const event = parseStatusEvent(body);
    // Acknowledge unusable or unknown events with 200 so Vonage stops retrying.
    if (!event) return res.status(200).json({ ok: true, ignored: 'unsupported' });
    try {
      const result = await applyStatus(event, nowMs);
      if (result.buffered) report('vonage-status-buffered', { status: event.status });
      else if (!result.matched) report('vonage-status-unmatched', { status: event.status });
      return res.status(200).json({ ok: true });
    } catch {
      report('vonage-status-store-failed', { status: event.status });
      return res.status(500).json({ ok: false });
    }
  };
}
