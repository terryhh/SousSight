# Live cooking integration

The browser uses Gemini 3.8 Live, selected by the protected `/api/live-token`
response. `FirebaseLiveTransport` remains available for SDK-supported native
clients. Firebase AI Logic 5.1's browser Live path omits App Check headers, so
web intentionally uses an ephemeral token, never a long-lived key.

```dart
final live = LiveCookingController(
  media: createBrowserLiveMedia(),
  transportFactory: () => EphemeralGeminiLiveTransport(
    tokenProvider: () async => LiveEphemeralToken.fromJson(await fetchLiveToken()),
  ),
  onToolCall: handleCookingTool,
);
await live.start(cookingContext: '$recipeContext\n$cookingUiInstructions');
```

Load `web/soussight_live.js` before Flutter's bootstrap in `web/index.html`.
Add direct dependency `web_socket_channel: ^3.0.3`. The browser bridge uses
only browser media primitives and a local AudioWorklet. Call `start` directly
from the Connect button's user gesture, call `stop` when leaving, and dispose
the controller with the screen. Render `latestFrame` with `Image.memory`.
Camera frames are sent once per second, maximum dimension 768 px. Microphone
input is PCM16 little-endian at 16 kHz; model playback is PCM16 at 24 kHz.

Listen to controller changes for status, user/coach transcripts, frame, error,
and notice. `setMicrophoneMuted`, `startWatch`, `stopWatch`, and `sendText` are
available. Watch mode explicitly requests fresh visual observations every 8s;
it does not assume that silent video will automatically trigger responses.
Readiness reports require a fresh frame and active watch, and only the first
ready report reaches the host per watch. A timer or appearance report never
certifies internal temperature or food safety.

Host tool handler names:
- `show_cooking_ui`: `uiJson` containing a components array; pass through GenUI validator.
- `start_timer`: `id`, `label`, integer `seconds` (1–7200).
- `watch_cooking`: `goal`; controller starts watch, host updates panel.
- `report_readiness`: `state` watching/ready/uncertain, `observation`.
- `ask_cook`: `question`, `reason`; show a targeted question to the cook.
- `research_cooking`: `question`; delegate to a separate grounded Google Search model.
- `check_now`, `next_step`: no arguments, host enforces current-step confirmation.
- `dinner_ready`: `message`; opens a draft, never sends automatically.

Return JSON-compatible `{ok: true, ...}` or `{ok: false, error: '...'}`. Tools
are bounded/validated and deduplicated by call ID. The receiver stays active
across turnComplete messages. Interruptions clear queued speech. GoAway uses a
resumption handle and holds text/tool replies until reconnection completes.

Primary references checked 2026-11-07:
- https://ai.google.dev/gemini-api/docs/live-api/ephemeral-tokens
- https://github.com/google-gemini/gemini-skills/blob/main/skills/gemini-live-api-dev/references/migration.md
- https://github.com/firebase/firebase-js-sdk/issues/10018
- https://docs.cloud.google.com/gemini-enterprise-agent-platform/models/live-api/configure-gemini-capabilities

Current Google documentation uses v1beta ephemeral tokens and Gemini 3.8 Live;
older SDK snippets still mention v1alpha. The transport follows server-returned
model/version metadata and uses the constrained WebSocket endpoint. Verify a
real session with deployed token endpoint, App Check and Auth before a demo.
Do not claim that compilation proves a real Gemini connection.

Validation: browser bridge tests run with `node --test test/live/browser_media_test.cjs`.
Flutter protocol/lifecycle tests run with `flutter test test/live`. A successful
web compile exercises Dart JS interop but does not verify hardware permissions,
actual microphone/speaker behavior, credentials, or model output.
