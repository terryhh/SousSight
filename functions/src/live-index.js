import { allowedOrigins } from './firebase-app.js';
import { getAppCheck } from 'firebase-admin/app-check';
import { getAuth } from 'firebase-admin/auth';
import { getFirestore } from 'firebase-admin/firestore';
import { defineSecret, defineString } from 'firebase-functions/params';
import { onRequest } from 'firebase-functions/v2/https';
import { warn } from 'firebase-functions/logger';
import { createLiveTokenHandler, mintGoogleToken, LIVE_MODEL, LIVE_API_VERSION } from './live-token.js';
import { createQuotaReservation } from './token-quota.js';
import { createLiveSessionHandler } from './live-session.js';

const geminiApiKey = defineSecret('GEMINI_API_KEY');
// One pinned Live model (DESIGN.md §7): the AI Logic client's GEMINI_LIVE_MODEL
// define must equal this; liveSession reports it so the client can check.
const liveModel = defineString('LIVE_MODEL', { default: LIVE_MODEL });
const liveApiVersion = defineString('LIVE_API_VERSION', { default: LIVE_API_VERSION });
export const liveToken = onRequest({
  region: 'us-central1',
  secrets: [geminiApiKey],
  cors: false,
  maxInstances: 4,
  timeoutSeconds: 30,
  memory: '256MiB',
}, async (req, res) => {
  const handler = createLiveTokenHandler({
    verifyAuth: (token) => getAuth().verifyIdToken(token, true),
    verifyAppCheck: (token) => getAppCheck().verifyToken(token),
    reserveQuota: createQuotaReservation(getFirestore()),
    createToken: (nowMs) => mintGoogleToken({
      apiKey: geminiApiKey.value(), nowMs,
      model: liveModel.value(), apiVersion: liveApiVersion.value(),
    }),
    allowedOrigins: new Set(allowedOrigins.value().split(',').map((s) => s.trim()).filter(Boolean)),
    reportFailure: (code) => warn('live-token-request-failed', { code }),
  });
  return handler(req, res);
});


// Session reservation for the Firebase AI Logic Live path (SS-074). Needs no
// secret: the client connects through AI Logic, so nothing is minted here.
export const liveSession = onRequest({
  region: 'us-central1',
  cors: false,
  maxInstances: 4,
  timeoutSeconds: 15,
  memory: '256MiB',
}, async (req, res) => createLiveSessionHandler({
  verifyAuth: (token) => getAuth().verifyIdToken(token, true),
  verifyAppCheck: (token) => getAppCheck().verifyToken(token),
  reserveQuota: createQuotaReservation(getFirestore()),
  model: liveModel.value(),
  allowedOrigins: new Set(allowedOrigins.value().split(',').map((s) => s.trim()).filter(Boolean)),
  reportFailure: (code) => warn('live-session-request-failed', { code }),
})(req, res));
