import { onRequest } from 'firebase-functions/v2/https';

// Interim `vonageStatus` deployed while VONAGE_SIGNATURE_SECRET does not exist
// (DINNER_SERVICE_READY=true, DINNER_STATUS_READY!=true). It binds no secret and
// never reads, parses or accepts an event: every POST gets 503 so Vonage retries
// later, and the retries succeed once the real signed handler (status-index.js)
// replaces this function under the same name.
export function rejectUnconfiguredStatus(req, res) {
  res.set('Cache-Control', 'no-store');
  if (req.method !== 'POST') {
    res.set('Allow', 'POST');
    res.status(405).json({ error: 'method-not-allowed' });
    return;
  }
  res.status(503).json({ error: 'status-webhook-not-configured' });
}

export const vonageStatus = onRequest({
  region: 'us-central1',
  cors: false, maxInstances: 1, timeoutSeconds: 10, memory: '128MiB',
}, rejectUnconfiguredStatus);
