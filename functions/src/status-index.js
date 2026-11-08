import './firebase-app.js';
import { getFirestore } from 'firebase-admin/firestore';
import { defineSecret } from 'firebase-functions/params';
import { onRequest } from 'firebase-functions/v2/https';
import { warn } from 'firebase-functions/logger';
import { createDeliveryStatusStore, createVonageStatusHandler } from './vonage-status.js';

// Vonage Dashboard > Settings > "Signature secret" (signs Messages API webhooks).
const vonageSignatureSecret = defineSecret('VONAGE_SIGNATURE_SECRET');

// Public endpoint for Vonage only. Trust comes from the signed JWT when an
// Authorization header is present, otherwise from the per-message capability
// token in the path. No Firebase Auth/App Check: Vonage cannot present them.
export const vonageStatus = onRequest({
  region: 'us-central1',
  secrets: [vonageSignatureSecret],
  cors: false, maxInstances: 2, timeoutSeconds: 15, memory: '256MiB',
}, async (req, res) => createVonageStatusHandler({
  secret: () => vonageSignatureSecret.value(),
  applyStatus: createDeliveryStatusStore(getFirestore()),
  // Log codes only: never tokens, bodies, phone numbers or message UUIDs.
  report: (event, fields) => warn(event, fields),
})(req, res));
