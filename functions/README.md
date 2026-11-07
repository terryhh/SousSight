# SousSight Live token service

`liveToken` is an HTTPS Cloud Function (Node 22, `us-central1`) intended to be
rewritten from Hosting `/api/live-token`. It authenticates the learner with a
Firebase ID token and verifies Firebase App Check before minting a single-use
Gemini Live token. Anonymous Firebase users are supported.

Request: `POST` with an empty JSON object, `Authorization: Bearer <ID token>`, and
`X-Firebase-AppCheck: <App Check token>`. Response:

```json
{
  "token": "auth_tokens/SHORT_LIVED_VALUE",
  "model": "gemini-3.8-live",
  "apiVersion": "v1beta",
  "expiresAt": "2026-11-07T21:30:00.000Z",
  "newSessionExpiresAt": "2026-11-07T21:01:00.000Z"
}
```

The browser must start the connection within 60 seconds; the token expires after
30 minutes and may start one session. Model and AUDIO output are locked on the
server. The client supplies recipe-specific instructions, tools, transcription,
and session-resumption configuration. The current REST contract comes from the
[Gemini ephemeral token guide](https://ai.google.dev/gemini-api/docs/live-api/ephemeral-tokens).
This integration still needs a real service smoke test before the demo.

Set the `GEMINI_API_KEY` Secret Manager secret and enable the Gemini Developer API
for its project. Never add that key to Dart defines or web assets. Firebase Auth,
App Check, Firestore, Cloud Functions billing, and a Hosting rewrite must be ready.
`LIVE_ALLOWED_ORIGINS` defaults to the two project Hosting domains. Add a specific
localhost origin only for emulator testing. Origin filtering is in addition to
authentication and App Check; it is not a replacement for either.

A Firestore transaction reserves each attempt in `_liveTokenLimits/{hashedUid}`:
at most 8 attempts per 10 minutes with 10 seconds between attempts. Failed minting
still consumes an attempt. No token, API key, image, audio, or transcript is stored
in that document. Keep this collection denied to client SDKs. This per-user gate
does not replace project quotas and billing alerts; users can create new anonymous
identities.

Errors use `{ "error": { "code": "...", "message": "..." } }`. A 429 includes
`Retry-After` and `error.retryAfterSeconds`. Every response is `no-store`.

Run `npm install` to resolve the pinned Firebase dependencies and commit the
resulting lockfile when registry access is available. Unit checks have no installed
dependencies: `node --test test/*.test.js` and `npm run check`. These cover auth,
quota, provider payloads, and errors through injected boundaries; they do not
verify an actual Gemini WebSocket connection or deployed IAM/Firestore rules.
