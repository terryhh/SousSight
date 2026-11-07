import { initializeApp } from 'firebase-admin/app';
import { getAppCheck } from 'firebase-admin/app-check';
import { getAuth } from 'firebase-admin/auth';
import { getFirestore } from 'firebase-admin/firestore';
import { defineSecret, defineString } from 'firebase-functions/params';
import { onRequest } from 'firebase-functions/v2/https';
import { warn } from 'firebase-functions/logger';
import { createLiveTokenHandler, mintGoogleToken } from './live-token.js';
import { createQuotaReservation } from './token-quota.js';

initializeApp();
const geminiApiKey = defineSecret('GEMINI_API_KEY');
const allowedOrigins = defineString('LIVE_ALLOWED_ORIGINS', {
  default: 'https://devfest-flutter-a59e8.web.app,https://devfest-flutter-a59e8.firebaseapp.com',
});

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
    createToken: (nowMs) => mintGoogleToken({ apiKey: geminiApiKey.value(), nowMs }),
    allowedOrigins: new Set(allowedOrigins.value().split(',').map((s) => s.trim()).filter(Boolean)),
    reportFailure: (code) => warn('live-token-request-failed', { code }),
  });
  return handler(req, res);
});
