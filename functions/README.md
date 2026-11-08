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

Request: `POST` with the same Auth/App Check headers as the token endpoint.
The client sends template **slots only**; the server composes the text, so no
free-form client or model text reaches the household:

```json
{
  "sessionId": "SESSION_ID",
  "notificationId": "NEW_UUID_FOR_THIS_ATTEMPT",
  "recipient": "+14075550100",
  "kind": "ready",
  "recipeTitle": "Chickpea wraps",
  "minutes": 25,
  "cookName": "Optional, started only",
  "simulateOutcome": null
}
```

Templates (`kind`):

- `started`: `SousSight: {cookName or 'Your cook'} started {recipeTitle}. Dinner in about {minutes} min.`
  (`minutes` required, integer 1-120)
- `ready`: `SousSight: Dinner is ready! {recipeTitle} is on the table.` (no `minutes`)

`recipeTitle` (raw <= 200 chars) and `cookName` (raw <= 80) are reduced to
letters, numbers, spaces and `' & , ( ) ! -`, whitespace-collapsed and cut to
60/30 characters, so links and markup cannot pass. A `message` field is rejected.

Success returns `{notificationId, kind, message, status, deliveryStatus, simulated,
channel, duplicate, reason}`. `status` is the send outcome: `submitted` (provider
accepted, **delivery unconfirmed**), `skipped` (dry-run), `failed` (known
rejection/configuration problem), or `unknown` (ambiguous). Never label
`submitted` as delivered; only a verified status webhook sets `delivered`/`read`.

Errors: 400 `invalid-request`/`invalid-recipient`, 403 `recipient-not-allowed`,
`session-not-owned`, `simulation-disabled`, 409 `idempotency-conflict` (same ID,
different content) and `meal-already-notified` (another ID already holds this
meal/recipient/kind slot), 429 `rate-limited` (with `Retry-After`), 503
`not-configured`. Configuration and sender checks run **before** the ledger claim,
so a misconfiguration never locks the meal slot.

### Delivery status (Vonage status webhook)

`vonageStatus` (HTTPS, `us-central1`, Hosting rewrites `/api/vonage-status` and
`/api/vonage-status/**`) receives
[Message Status webhooks](https://developer.vonage.com/en/api/messages)
(`message_uuid`, `status` = `submitted|delivered|rejected|undeliverable`, plus
`read` on WhatsApp, `error {type,title,detail,instance}`, `timestamp`, `to`,
`from`, `channel`, `client_ref`). It trusts nothing until one of two checks passes.

**Security model.** The primary check is a **per-message capability URL**, which
needs no Vonage signature secret:

- For every real send the server draws 32 random bytes (`crypto.randomBytes`,
  base64url, 43 chars) and sets that message's `webhook_url` to
  `${DINNER_STATUS_BASE_URL}/api/vonage-status/<token>` with `webhook_version: "v1"`.
- Only `sha256(token)` is persisted, server-side only: on the ledger record
  (`_dinnerNotifications`, `statusTokenHash`) and the provider index
  (`_dinnerProviderMessages/{sha256(message_uuid)}`). The raw token exists only
  in the outbound request to Vonage and in Vonage's callback URL. It is never
  returned to the app, stored, or logged.
- A callback is applied only when `sha256(path token)` equals the hash stored for
  the body's `message_uuid` (constant-time `timingSafeEqual`). A token is valid
  for exactly one message, so a leaked token cannot touch any other notification,
  and it can only move that message's status monotonically.
- Requests with no token, a malformed token, a token for another message, or a
  message indexed before this change (no stored hash) get 401.

The **signed JWT** check is optional: when an `Authorization` header is present
and `VONAGE_SIGNATURE_SECRET` is bound (`DINNER_STATUS_READY=true`, `src/index.js`),
the [signed-webhook JWT](https://developer.vonage.com/en/getting-started/concepts/webhooks#decoding-signed-webhooks)
must verify (HS256 pinned, HMAC-SHA256 constant-time, `iat` within 5 minutes /
60 s future, `payload_hash` = SHA-256 of the body) or the request gets 401. Without
the secret (`src/live-dinner-index.js`, `src/status-capability-index.js`) the
header is ignored and the capability check applies.

Trade-off: a capability URL is a bearer secret in the URL. Hosting/Cloud Run
request logs may record request paths; the token grants only status updates for
its one message, and the 256-bit entropy rules out guessing. Unsigned, tokenless
requests now get 401 (previously 503), because callbacks for SousSight sends
always carry their token.

Unsupported statuses on a signed request get 200 (no retry storm); on a
capability request they get 400 because no usable `message_uuid` means the token
cannot be checked. An authenticated event whose `message_uuid` has no provider
index yet (the callback beat the send response) is buffered, not dropped:
capability events go to `_dinnerPendingStatus/{sha256(message_uuid + "\n" + tokenHash)}`
and signed events to `_dinnerPendingStatus/{sha256(message_uuid)}` (capped at 20
events, `expireAt` 7 days out for a Firestore TTL policy), answered 200. When
`settle` writes the provider index, it reads only the signed buffer and the
buffer keyed by **this message's** token hash, folds those events through the same
monotonic logic, mirrors the result and deletes them; events presented with any
other token are never applied. Storage failures get 500 so Vonage retries. Logs
contain only event codes and statuses: never tokens, token hashes, bodies, phone
numbers or message UUIDs.

On send, `settle` writes `_dinnerProviderMessages/{sha256(message_uuid)}` ->
ledger key, session and notification IDs. The webhook updates the ledger's
`deliveryStatus` and a capped `statusHistory`, monotonically (`submitted` <
`delivered` < `read`; `rejected`/`undeliverable` are terminal and never override
`delivered`/`read`). It mirrors a cook-readable document
`sessions/{sessionId}/notifications/{notificationId}` =
`{kind, status, errorTitle, errorCode, reason, simulated, updatedAt}` via the Admin
SDK. Rules let only the session owner read it; all client writes are denied.

`webhook_url` and `webhook_version: "v1"` override the dashboard status URL for
that message. If `DINNER_STATUS_BASE_URL` is not `https://host[:port]` (e.g.
`disabled`), no `webhook_url` is sent and status falls back to dashboard settings,
which cannot authenticate without the signature secret.

Recovery: a known failure (`failed`, `rejected`, `undeliverable`) frees the
meal/recipient/kind slot for a **new** notification ID only after the cook edits
and confirms again. Pending or unknown attempts still block new IDs, and nothing
is retried automatically.

### Delivery simulation (zero-cost demo)

With `ALLOW_DELIVERY_SIMULATION=true`, a request with `"simulateOutcome"` set to
`"delivered"` or `"rejected"` never contacts Vonage (`"simulateFailure": true` is
still accepted as an alias for `"rejected"`; a contradictory pair is 400). It
claims the ledger (rate limit and ownership included), records a synthetic
`sim-<uuid>` message ID, and then runs the **same** status function as the
webhook with synthetic events:

- `delivered`: `submitted` then `delivered`.
- `rejected`: `rejected`, error `Illegal Sender Address` (code 1120, the
  rejection this account really recorded), which enables the cook's recovery
  action.

The mirror is marked `simulated: true` and the app prefixes every such status
with "Simulated — no SMS sent." With the parameter unset or `false`, the request
returns 403 `simulation-disabled`. It works while `ENABLE_DINNER_MESSAGES=false`,
so both lifecycle messages (`started`, `ready`) and both outcomes can be shown
without spending Vonage credit. A real send stays optional and needs explicit
approval.

### Rate limit

`_dinnerSendLimits/{sha256(uid)}` allows 5 new claims per user per rolling hour
window inside the claim transaction. Repeating an existing notification ID
(status read) does not count.

Configuration:

- Secret Manager: `VONAGE_API_KEY`, `VONAGE_API_SECRET`, `VONAGE_FROM`, and
  `VONAGE_ALLOWED_TO` (comma-separated allowed phone numbers with country codes).
- `DINNER_CHANNEL=whatsapp` by default uses the Messages Sandbox. `sms` uses the
  production Messages API; SMS is not a Sandbox channel. Configure the appropriate
  sender and US messaging registration for ordinary US traffic. The account's
  dashboard trial example has a separate, limited path described below.
- `ENABLE_DINNER_MESSAGES=false` by default. Only the exact value `true` enables
  a provider request. Deploying code does not itself opt into sending messages.
- Optional Secret Manager `VONAGE_SIGNATURE_SECRET` (bound only to
  `vonageStatus`, and only when `DINNER_STATUS_READY=true`).
- `DINNER_STATUS_BASE_URL` (string param, default
  `https://devfest-flutter-a59e8.web.app`): origin for per-message capability
  status URLs. The workflow writes it whenever `DINNER_SERVICE_READY=true`.
- `ALLOW_DELIVERY_SIMULATION=false` by default (demo delivery/failure simulation).
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
client SDKs, as well as `_dinnerProviderMessages` and `_dinnerSendLimits`. Only
hashes, IDs, kind, channel, status, sanitised error titles/codes and timestamps
are stored; message content and recipient numbers are not written.

Retain the notification ID across network retries. Changed content with the same
ID returns 409. A second ID for the same meal/recipient/kind also returns 409 unless the prior
attempt is a known failure. Pending
or unknown attempts never resend, even after a worker crash; inspect the Vonage
dashboard before taking any manual action. Dry-run attempts are terminal too:
start a fresh cooking session for the real-send rehearsal after enabling messages.
No network retry loop is built into this integration, and tests inject the provider
transport so they never send a message.


## SMS trial setup without an account upgrade

The earlier instruction to use `Vonage APIs` for `VONAGE_FROM` was incorrect
for this account. The authorized app request was initially accepted, then the
authenticated Vonage log showed **REJECTED, 1120 Illegal Sender Address**.
The earlier delivered dashboard test used a numeric sender. Configure the exact
numeric sender from the account's delivered-message log, after verifying it is
appropriate for that account and destination; keep the number out of Git.
SousSight requires numeric senders for both SMS and WhatsApp and rejects the
previous special-case label before transport.

The [dashboard SMS example](https://developer.vonage.com/en/dashboard/build/messaging/send-sms)
and [trial guide](https://api.support.vonage.com/hc/en-us/articles/14841470272540-Understanding-the-10DLC-Trial-Campaign-in-SMS-API)
do not guarantee that the same visible dashboard label works in an app request.
A successful dashboard test is not app delivery verification. Provider acceptance
is not delivery; inspect the corresponding provider log when delivery is absent.

Authenticated dashboard inspection showed the earlier test as DELIVERED at
US$0.01 and a current balance of US$1.99. The rejected app attempt's price is
Unknown; do not infer it was free or cost US$0.01. Sending remains disabled and
no retry, upgrade or top-up is authorized. The corrected numeric sender has not
yet been tested through the app. Automated tests inject transport and consume no
Vonage credit. Reserve any further live send for explicit cook-reviewed approval.

Enter the four secrets interactively in your own terminal, not in chat, command
arguments, GitHub, Dart defines or browser assets:

```sh
firebase functions:secrets:set VONAGE_API_KEY --project devfest-flutter-a59e8
firebase functions:secrets:set VONAGE_API_SECRET --project devfest-flutter-a59e8
firebase functions:secrets:set VONAGE_FROM --project devfest-flutter-a59e8
firebase functions:secrets:set VONAGE_ALLOWED_TO --project devfest-flutter-a59e8
```

For `VONAGE_FROM`, enter the exact numeric sender verified from the delivered
message in this account, including country code. For
`VONAGE_ALLOWED_TO`, enter only the registered/verified receiving phone number,
including country code, without spaces. It is not the purchased sender number.
Use the actual key and secret from the same dashboard account. Do not add
`--force`, which can update functions to use new secret versions.

The GitHub deployment variable is `DINNER_CHANNEL=sms`. Keep
`DINNER_SERVICE_READY=false` until credentials and deployment prerequisites have
been verified, and keep `ENABLE_DINNER_MESSAGES=false` until a real test is
explicitly authorized. Changing the channel alone does not deploy or send.

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


## Human setup for delivery status (not done by automation)

Capability URLs need **no** human setup: with `DINNER_SERVICE_READY=true` the
workflow packages `src/live-dinner-index.js`, whose `vonageStatus`
(`src/status-capability-index.js`) binds no secret, and every real send carries
its own `webhook_url`. Optional extras:

1. Signed JWTs in addition (only if the account **Signature secret** is found in
   Vonage Dashboard > Settings for the same API key as `VONAGE_API_KEY`): store it
   interactively with
   `firebase functions:secrets:set VONAGE_SIGNATURE_SECRET --project devfest-flutter-a59e8`,
   then set the GitHub `production` variable `DINNER_STATUS_READY=true` (requires
   `DINNER_SERVICE_READY=true`). The workflow then packages `src/index.js`, which
   accepts both signed and capability callbacks.
2. Dashboard Status URL fallback: not useful without the signature secret, since a
   tokenless callback cannot authenticate and gets 401.
3. WhatsApp Sandbox: whether the sandbox honours per-message `webhook_url` is not
   documented. Its dashboard-level Status URL cannot carry a per-message token.
4. For the demo, `ALLOW_DELIVERY_SIMULATION=true`. Then re-run the deploy workflow.

Both modes deploy `functions:vonageStatus`; the two status rewrites are removed
only when the dinner service itself is not ready.

Verification status: unit tests cover capability URLs (token format, right/wrong/missing/legacy token, token bound to one message, buffering before settle applied only with the matching hash, no token or hash in logs or app responses), entrypoint params and the Hosting rewrites, JWT verification (valid, bad signature,
`alg` swap, stale/future `iat`, hash mismatch), status mapping and monotonicity,
unknown UUIDs, callbacks arriving before the send response (buffer and fold at
settle), delivered/rejected simulation without any provider call, templates, rate limit and pre-claim configuration
checks with an in-memory Firestore and injected transport. No real Vonage
callback, SMS, deployment or live Firestore write has been exercised.
