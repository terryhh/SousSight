import { createHash } from 'node:crypto';
import { TokenRequestError } from './live-token.js';

const MIN_INTERVAL_MS = 10_000;
const WINDOW_MS = 10 * 60_000;
const MAX_TOKENS_PER_WINDOW = 8;

export function nextQuota(previous, nowMs) {
  const validPrevious = previous && Number.isFinite(previous.lastIssuedAt) &&
    Number.isFinite(previous.windowStartedAt) && Number.isInteger(previous.count);
  const inWindow = validPrevious && nowMs >= previous.windowStartedAt &&
    nowMs - previous.windowStartedAt < WINDOW_MS;
  if (validPrevious && nowMs - previous.lastIssuedAt < MIN_INTERVAL_MS) {
    throw new TokenRequestError('rate-limited', 429, 'Please wait before reconnecting.',
      Math.max(1, Math.ceil((MIN_INTERVAL_MS - (nowMs - previous.lastIssuedAt)) / 1000)));
  }
  if (inWindow && previous.count >= MAX_TOKENS_PER_WINDOW) {
    throw new TokenRequestError('rate-limited', 429, 'Please wait before reconnecting.',
      Math.max(1, Math.ceil((WINDOW_MS - (nowMs - previous.windowStartedAt)) / 1000)));
  }
  return {
    windowStartedAt: inWindow ? previous.windowStartedAt : nowMs,
    lastIssuedAt: nowMs,
    count: inWindow ? previous.count + 1 : 1,
  };
}

export function createQuotaReservation(db) {
  return (uid, nowMs) => {
    // Hash keeps auth IDs out of diagnostic document paths. Only Admin SDK may
    // access this collection; existing default-deny Firestore rules cover it.
    const id = createHash('sha256').update(uid).digest('hex');
    const ref = db.collection('_liveTokenLimits').doc(id);
    return db.runTransaction(async (transaction) => {
      const snapshot = await transaction.get(ref);
      transaction.set(ref, nextQuota(snapshot.exists ? snapshot.data() : null, nowMs));
    });
  };
}
