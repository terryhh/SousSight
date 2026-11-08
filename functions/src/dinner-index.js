import { allowedOrigins } from './firebase-app.js';
import { getAppCheck } from 'firebase-admin/app-check';
import { getAuth } from 'firebase-admin/auth';
import { getFirestore } from 'firebase-admin/firestore';
import { defineSecret, defineString } from 'firebase-functions/params';
import { onRequest } from 'firebase-functions/v2/https';
import {
  createDinnerLedger, createDinnerReadyHandler, createDinnerService, providerConfigProblem, sendVonageDinner,
} from './dinner-ready.js';
import { createDeliveryStatusStore } from './vonage-status.js';

const vonageApiKey = defineSecret('VONAGE_API_KEY');
const vonageApiSecret = defineSecret('VONAGE_API_SECRET');
const vonageFrom = defineSecret('VONAGE_FROM');
const vonageAllowedTo = defineSecret('VONAGE_ALLOWED_TO');
const dinnerChannel = defineString('DINNER_CHANNEL', { default: 'whatsapp' });
const enableDinnerMessages = defineString('ENABLE_DINNER_MESSAGES', { default: 'false' });
// Demo-only: lets the cook trigger a server-side simulated Vonage rejection.
const allowDeliverySimulation = defineString('ALLOW_DELIVERY_SIMULATION', { default: 'false' });
// Per-message status webhook, e.g. https://devfest-flutter-a59e8.web.app/api/vonage-status.
// A non-empty default keeps non-interactive deploys working when the status
// webhook is not configured; any non-HTTPS value (e.g. 'disabled') means unset.
const statusWebhookUrl = defineString('DINNER_STATUS_WEBHOOK_URL', { default: 'disabled' });

function webhookUrl() {
  const value = statusWebhookUrl.value().trim();
  return /^https:\/\/[A-Za-z0-9.-]+(:\d+)?\/[A-Za-z0-9/_-]*$/.test(value) ? value : '';
}

export const dinnerReady = onRequest({
  region: 'us-central1',
  secrets: [vonageApiKey, vonageApiSecret, vonageFrom, vonageAllowedTo],
  cors: false, maxInstances: 2, timeoutSeconds: 30, memory: '256MiB',
}, async (req, res) => {
  const db = getFirestore();
  const credentials = () => ({
    apiKey: vonageApiKey.value(), apiSecret: vonageApiSecret.value(), from: vonageFrom.value(),
  });
  const service = createDinnerService({
    ledger: createDinnerLedger(db),
    applyStatus: createDeliveryStatusStore(db),
    settings: {
      channel: dinnerChannel.value(),
      enabled: enableDinnerMessages.value() === 'true',
      allowSimulation: allowDeliverySimulation.value() === 'true',
      checkProvider: () => providerConfigProblem(credentials()),
      allowedRecipients: vonageAllowedTo.value().split(',').map((s) => s.trim()).filter(Boolean),
    },
    sendMessage: ({ request, channel }) => sendVonageDinner({ request, channel,
      credentials: credentials(), webhookUrl: webhookUrl(),
    }),
  });
  return createDinnerReadyHandler({
    verifyAuth: (token) => getAuth().verifyIdToken(token, true),
    verifyAppCheck: (token) => getAppCheck().verifyToken(token),
    service,
    allowedOrigins: new Set(allowedOrigins.value().split(',').map((s) => s.trim()).filter(Boolean)),
  })(req, res);
});
