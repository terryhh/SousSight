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

`LIVE_MODEL` and `LIVE_API_VERSION` are server-side Firebase string parameters.
Their defaults are `gemini-3.8-live` and `v1beta`, verified against the current
Google ephemeral-token guide. Change these at deployment when switching supported
models; the response passes the same settings to the browser. API versions are
limited to `v1alpha` and `v1beta`; model names must be unprefixed `gemini-*` IDs.
The endpoint rejects invalid deployment settings before calling Google. Browser
requests cannot override these parameters.

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

Run `npm ci` on Node 22 to install the pinned Firebase dependencies from the
committed lockfile. `functions/.gitignore` excludes dependency folders and local
Firebase environment/secret files from Git. Unit checks have no installed
dependencies: `node --test test/*.test.js` and `npm run check`. These cover auth,
quota, provider payloads, and errors through injected boundaries; they do not
verify an actual Gemini WebSocket connection or deployed IAM/Firestore rules.

## Dinner-ready notifications

`dinnerReady` is a second HTTPS function in `us-central1`; rewrite Hosting
`/api/dinner-ready` to it. It sends only after the cook reviews and confirms the
recipient and exact message in the app. A model/tool call must only open that
review; it must not submit this endpoint automatically.

Request: `POST` with the same Auth/App Check headers as the token endpoint:

```json
{
  "sessionId": "SESSION_ID",
  "notificationId": "STABLE_UUID_FOR_THIS_ATTEMPT",
  "recipient": "+14075550100",
  "message": "Dinner is ready! Chickpea wraps are on the table."
}
```

Success returns `{notificationId, status, channel, duplicate, reason}`. Status is
`submitted` (provider accepted, **delivery unconfirmed**), `skipped` (dry-run),
`failed` (known rejection/configuration problem), or `unknown` (ambiguous outcome).
Never label `submitted` as delivered. This demo does not accept delivery callbacks;
adding that later requires signature verification and correlation with the stored
provider UUID. The [Vonage status guide](https://developer.vonage.com/en/messages/concepts/messages-status-callbacks)
describes the distinction between submission, delivery and rejection.

Configuration:

- Secret Manager: `VONAGE_API_KEY`, `VONAGE_API_SECRET`, `VONAGE_FROM`, and
  `VONAGE_ALLOWED_TO` (comma-separated allowed phone numbers with country codes).
- `DINNER_CHANNEL=whatsapp` by default uses the Messages Sandbox. `sms` uses the
  production Messages API; SMS is not a Sandbox channel. Configure the appropriate
  sender and US messaging registration before choosing SMS.
- `ENABLE_DINNER_MESSAGES=false` by default. Only the exact value `true` enables
  a provider request. Deploying code does not itself opt into sending messages.
- Allowed origins reuse `LIVE_ALLOWED_ORIGINS`.

The [Vonage Sandbox guide](https://developer.vonage.com/en/messages/concepts/messages-api-sandbox)
requires the recipient to join the Sandbox allowlist under the same API key and
an active WhatsApp 24-hour messaging window. It has a one-message-per-second rate
limit and a 100-message monthly allowance. The server allowlist is an additional
restriction; it does not enroll a number in Vonage. Account-level Basic auth is
supported for this demo; [Vonage recommends JWT for most production uses](https://developer.vonage.com/en/messages/technical-details).

The service checks session ownership inside the Firestore claim transaction.
It creates `_dinnerNotifications/{hashedUidAndNotificationId}` before calling the
provider, and `_dinnerMealClaims/{hashedUidSessionRecipient}` prevents a fresh ID
from bypassing an existing meal announcement. Keep both collections denied to
client SDKs. Only hashes, IDs, channel, status and timestamps are stored; message
content and recipient numbers are not written to the ledger.

Retain the notification ID across network retries. Changed content with the same
ID returns 409. A second ID for the same meal/recipient also returns 409. Pending
or unknown attempts never resend, even after a worker crash; inspect the Vonage
dashboard before taking any manual action. Dry-run attempts are terminal too:
start a fresh cooking session for the real-send rehearsal after enabling messages.
No network retry loop is built into this integration, and tests inject the provider
transport so they never send a message.


## Deploy Live before dinner credentials are ready

Firebase CLI analyzes the complete package entrypoint before applying `--only`
function filters. A full entrypoint therefore requires Vonage secret parameters
even when only `liveToken` is selected.

The production workflow selects `functions/package.json` `main` as
`src/live-index.js` when `DINNER_SERVICE_READY=false`. That package entrypoint
exports only `liveToken`, declares only Gemini/Live parameters, and remains in the
uploaded source so runtime loading matches discovery. The workflow also omits the
dinner Hosting rewrite and dinner deployment target. No placeholder Vonage secrets
are needed and dinner sending stays disabled.

When all real Vonage secrets are configured, set `DINNER_SERVICE_READY=true` to use
`src/index.js`, which exports both functions. `ENABLE_DINNER_MESSAGES=false` remains
the independent default until sending is explicitly enabled. A full local deployment
uses the committed full entrypoint by default; do not assume `--only liveToken`
removes dinner configuration requirements.

`npm test` includes isolated packaged-entrypoint tests using the installed Firebase
Functions discovery loader. They check Live-only secret isolation and full dinner
secret bindings. These are local discovery tests, not a successful cloud deployment.


## Ephemeral token wire format

The backend sends the REST `AuthToken` resource, with
`bidiGenerateContentSetup.model` and
`bidiGenerateContentSetup.generationConfig.responseModalities`. The SDK option
`liveConnectConstraints` is not a REST field and causes an upstream HTTP 400.
The explicit `fieldMask` is `model,generationConfig.responseModalities`: it locks
those server choices while permitting the browser's recipe instructions, tools,
transcription and session resumption. Without this mask, the API replaces the
entire browser setup with the token's setup.

Sources: [AuthToken reference](https://ai.google.dev/api/live#AuthToken) and
[official SDK wire conversion](https://github.com/googleapis/js-genai/blob/main/src/tokens.ts).
A direct server-side diagnostic accepted this corrected request on November 7,
2026. That verifies token minting only; a deployed backend and actual Live WebSocket
session still need their own checks. The token was not persisted or logged.
