import './firebase-app.js';
import { getFirestore } from 'firebase-admin/firestore';
import { onRequest } from 'firebase-functions/v2/https';
import { warn } from 'firebase-functions/logger';
import { createDeliveryStatusStore, createVonageStatusHandler } from './vonage-status.js';

// `vonageStatus` without VONAGE_SIGNATURE_SECRET (deployed whenever the dinner
// service is, see live-dinner-index.js). Binds no secret: each callback must
// present the per-message capability token in its path
// (/api/vonage-status/<token>), checked against the sha256 stored with that
// message. Tokenless requests get 401. No Firebase Auth/App Check: Vonage
// cannot present them.
export const vonageStatus = onRequest({
  region: 'us-central1',
  cors: false, maxInstances: 2, timeoutSeconds: 15, memory: '256MiB',
}, async (req, res) => createVonageStatusHandler({
  secret: () => '',
  applyStatus: createDeliveryStatusStore(getFirestore()),
  // Log codes only: never tokens, bodies, phone numbers or message UUIDs.
  report: (event, fields) => warn(event, fields),
})(req, res));
