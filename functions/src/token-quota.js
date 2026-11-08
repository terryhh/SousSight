import { createHash } from 'node:crypto';
import { TokenRequestError } from './live-token.js';

// Short enough for a stage Stop/Start; the window cap still bounds abuse.
export const MIN_INTERVAL_MS = 3_000;
const WINDOW_MS = 10 * 60_000;
const MAX_TOKENS_PER_WINDOW = 8;
// Cost guardrails for the $10 demo budget (SS-043). Each token opens one Live
// session, which the client caps at 8 minutes (+5 once); these bound the
// number of sessions per cook per UTC day and across the whole project.
export const MAX_TOKENS_PER_DAY = 30;
const DAY_MS = 24 * 60 * 60_000;
export const GLOBAL_WINDOW_MS = 60_000;
export const MAX_GLOBAL_TOKENS_PER_MINUTE = 20;
// Server-only collection; firestore.rules denies all client access.
export const GLOBAL_LIMIT_COLLECTION = '_liveTokenGlobalLimits';
const GLOBAL_LIMIT_DOC = 'project';

function retryAfter(ms) {
  return Math.max(1, Math.ceil(ms / 1000));
}

function utcDay(nowMs) {
  return Math.floor(nowMs / DAY_MS);
}

export function nextQuota(previous, requestMs) {
  const validPrevious = previous && Number.isFinite(previous.lastIssuedAt) &&
    Number.isFinite(previous.windowStartedAt) && Number.isInteger(previous.count);
  // Request timestamps are captured before the transaction and kept across
  // retries, so they can arrive out of order. Use a monotonic effective time:
  // an earlier request counts inside the newer active window/day and can
  // never reset it.
  const nowMs = validPrevious
    ? Math.max(requestMs, previous.windowStartedAt, previous.lastIssuedAt)
    : requestMs;
  const inWindow = validPrevious && nowMs - previous.windowStartedAt < WINDOW_MS;
  const previousDay = validPrevious && Number.isInteger(previous.day) ? previous.day : -1;
  const day = Math.max(utcDay(nowMs), previousDay);
  const sameDay = validPrevious && previous.day === day && Number.isInteger(previous.dayCount);
  if (validPrevious && requestMs - previous.lastIssuedAt < MIN_INTERVAL_MS) {
    throw new TokenRequestError('rate-limited', 429, 'Please wait before reconnecting.',
      retryAfter(MIN_INTERVAL_MS - Math.max(0, requestMs - previous.lastIssuedAt)));
  }
  if (sameDay && previous.dayCount >= MAX_TOKENS_PER_DAY) {
    throw new TokenRequestError('rate-limited', 429,
      "Today's live coaching limit is reached. Try again tomorrow.",
      retryAfter((day + 1) * DAY_MS - nowMs));
  }
  if (inWindow && previous.count >= MAX_TOKENS_PER_WINDOW) {
    throw new TokenRequestError('rate-limited', 429, 'Please wait before reconnecting.',
      retryAfter(WINDOW_MS - (nowMs - previous.windowStartedAt)));
  }
  return {
    windowStartedAt: inWindow ? previous.windowStartedAt : nowMs,
    lastIssuedAt: nowMs,
    count: inWindow ? previous.count + 1 : 1,
    day,
    dayCount: sameDay ? previous.dayCount + 1 : 1,
  };
}

/** Project-wide fixed one-minute window across all cooks. */
export function nextGlobalQuota(previous, requestMs) {
  const valid = previous && Number.isFinite(previous.windowStartedAt) &&
    Number.isInteger(previous.count);
  // Monotonic: an earlier (delayed or retried) request joins the newer
  // active window instead of resetting a full shared quota.
  const nowMs = valid ? Math.max(requestMs, previous.windowStartedAt) : requestMs;
  const inWindow = valid && nowMs - previous.windowStartedAt < GLOBAL_WINDOW_MS;
  if (inWindow && previous.count >= MAX_GLOBAL_TOKENS_PER_MINUTE) {
    throw new TokenRequestError('rate-limited', 429,
      'Live coaching is busy right now. Try again in a minute.',
      retryAfter(GLOBAL_WINDOW_MS - (nowMs - previous.windowStartedAt)));
  }
  return {
    windowStartedAt: inWindow ? previous.windowStartedAt : nowMs,
    count: inWindow ? previous.count + 1 : 1,
  };
}

export function createQuotaReservation(db) {
  return (uid, nowMs) => {
    // Hash keeps auth IDs out of diagnostic document paths. Only Admin SDK may
    // access these collections; Firestore rules deny clients explicitly.
    const id = createHash('sha256').update(uid).digest('hex');
    const ref = db.collection('_liveTokenLimits').doc(id);
    const globalRef = db.collection(GLOBAL_LIMIT_COLLECTION).doc(GLOBAL_LIMIT_DOC);
    return db.runTransaction(async (transaction) => {
      // All reads precede writes, as Firestore transactions require.
      const [snapshot, globalSnapshot] = await Promise.all([
        transaction.get(ref), transaction.get(globalRef),
      ]);
      // A cook's own limit is checked first so their rejected attempts do not
      // consume the shared project-wide allowance.
      const user = nextQuota(snapshot.exists ? snapshot.data() : null, nowMs);
      const global = nextGlobalQuota(globalSnapshot.exists ? globalSnapshot.data() : null, nowMs);
      transaction.set(ref, user);
      transaction.set(globalRef, global);
    });
  };
}
