import { allowedOrigins } from './firebase-app.js';
import { getAppCheck } from 'firebase-admin/app-check';
import { getAuth } from 'firebase-admin/auth';
import { getFirestore } from 'firebase-admin/firestore';
import { defineSecret, defineString } from 'firebase-functions/params';
import { onRequest } from 'firebase-functions/v2/https';
import {
  createDinnerLedger, createDinnerReadyHandler, createDinnerService, providerConfigProblem, sendVonageDinner,
  statusWebhookUrl,
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
// Origin for per-message capability status URLs:
// `${DINNER_STATUS_BASE_URL}/api/vonage-status/<per-message token>`.
// Must be https://host[:port] with no path; any other value (e.g. 'disabled')
// sends no webhook_url, so status falls back to dashboard settings.
const statusBaseUrl = defineString('DINNER_STATUS_BASE_URL', { default: 'https://devfest-flutter-a59e8.web.app' });

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
    sendMessage: ({ request, channel, statusToken }) => sendVonageDinner({ request, channel,
      credentials: credentials(), webhookUrl: statusWebhookUrl(statusBaseUrl.value(), statusToken),
    }),
  });
  return createDinnerReadyHandler({
    verifyAuth: (token) => getAuth().verifyIdToken(token, true),
    verifyAppCheck: (token) => getAppCheck().verifyToken(token),
    service,
    allowedOrigins: new Set(allowedOrigins.value().split(',').map((s) => s.trim()).filter(Boolean)),
  })(req, res);
});
