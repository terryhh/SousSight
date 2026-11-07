import { allowedOrigins } from './firebase-app.js';
import { getAppCheck } from 'firebase-admin/app-check';
import { getAuth } from 'firebase-admin/auth';
import { getFirestore } from 'firebase-admin/firestore';
import { defineSecret, defineString } from 'firebase-functions/params';
import { onRequest } from 'firebase-functions/v2/https';
import { createDinnerLedger, createDinnerReadyHandler, createDinnerService, sendVonageDinner } from './dinner-ready.js';

const vonageApiKey = defineSecret('VONAGE_API_KEY');
const vonageApiSecret = defineSecret('VONAGE_API_SECRET');
const vonageFrom = defineSecret('VONAGE_FROM');
const vonageAllowedTo = defineSecret('VONAGE_ALLOWED_TO');
const dinnerChannel = defineString('DINNER_CHANNEL', { default: 'whatsapp' });
const enableDinnerMessages = defineString('ENABLE_DINNER_MESSAGES', { default: 'false' });

export const dinnerReady = onRequest({
  region: 'us-central1',
  secrets: [vonageApiKey, vonageApiSecret, vonageFrom, vonageAllowedTo],
  cors: false, maxInstances: 2, timeoutSeconds: 30, memory: '256MiB',
}, async (req, res) => {
  const service = createDinnerService({
    ledger: createDinnerLedger(getFirestore()),
    settings: {
      channel: dinnerChannel.value(),
      enabled: enableDinnerMessages.value() === 'true',
      allowedRecipients: vonageAllowedTo.value().split(',').map((s) => s.trim()).filter(Boolean),
    },
    sendMessage: ({ request, channel }) => sendVonageDinner({ request, channel,
      credentials: { apiKey: vonageApiKey.value(), apiSecret: vonageApiSecret.value(), from: vonageFrom.value() },
    }),
  });
  return createDinnerReadyHandler({
    verifyAuth: (token) => getAuth().verifyIdToken(token, true),
    verifyAppCheck: (token) => getAppCheck().verifyToken(token),
    service,
    allowedOrigins: new Set(allowedOrigins.value().split(',').map((s) => s.trim()).filter(Boolean)),
  })(req, res);
});
