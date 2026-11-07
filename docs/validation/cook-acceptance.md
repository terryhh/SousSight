# Physical Cook Acceptance & Reproducible Failure Report (`SS-023`)

- **Ticket:** [Issue #41 (`SS-023`)](https://github.com/terryhh/SousSight/issues/41) — Run physical cook acceptance and report reproducible failures
- **Owner:** Jenna (`@jennajh`)
- **Runtime / Integration Counterpart:** Terry (`@terryhh`) — supplies acceptance evidence to [`SS-010` (#20)](https://github.com/terryhh/SousSight/issues/20) and [`SS-019` (#34)](https://github.com/terryhh/SousSight/issues/34)
- **Last Updated:** `2026-11-07`
- **Evaluated Commit (`origin/main`):** `d350601` (`Merge pull request #48 from terryhh/codex/cd-auth-fix`)
- **Research Panel Branch (`SS-005`):** `1553c7f` (`agy/cooking-research`)

> **Verification Honesty & Scope Rule (`AGENTS.md`):**
> - Rehearsal (`FAKE_BACKEND=true`), automated widget/unit tests, and DevTools viewport checks are strictly separated from deployed HTTPS and physical device checks.
> - Unavailable hardware, unconfigured secrets, or unintegrated branches are marked **`BLOCKED`** or **`NOT RUN`**—never **`PASS`**.
> - No Terry-owned runtime files (`lib/learner/**`, `lib/live/**`, `lib/genui/**`, `lib/data/**`, `functions/**`) are modified by this validation deliverable. All reproducible runtime defects are documented in **Section 4** for Terry's runtime fix pass.

---

## 1. Environments, Devices & Builds Under Test

Every test row in Sections 2 and 3 references one of the explicit environment profiles below:

| Profile ID | Role | Device / Hardware | OS / Platform | Browser / Runtime | URL / Entrypoint & Build | Date |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **`ENV-DESKTOP-WIN`** | Desktop Browser & HTTP Probe Host | x64 Windows Workstation | Windows 11 (`Microsoft Windows NT 10.0.26300.0`) | Google Chrome `157.0.8103.38` | `https://devfest-flutter-a59e8.web.app` (`origin/main` @ `d350601`) | `2026-11-07` |
| **`ENV-REHEARSAL-CHROME`** | Local Simulated Mobile & Desktop Rehearsal | Desktop Chrome + DevTools Mobile Viewport (`360×740`) | macOS / Desktop (`terryhh` rehearsal session recorded in `docs/MVP-WORK-PLAN.md`) | Native Google Chrome (DevTools Device Emulation `360×740`) | `http://localhost:7358` (`lib/main_learner.dart` with `FAKE_BACKEND=true`, PR #35 @ `1315dbd`) | `2026-11-07` |
| **`ENV-TEST-RUNNER`** | Automated Widget, Layout, Lifecycle & Rules Suite | Headless CI / Local Test Runner | Flutter `3.47.9` / Dart `3.13.7`, Node `22.23.4` | `flutter test` + Node test runner + Firestore Rules Emulator | `origin/main` @ `d350601` (88+ Flutter tests, 23 backend tests, 10 Firestore rules tests) | `2026-11-07` |
| **`ENV-PHONE-ANDROID`** | Physical Android Phone Target (`SS-019` / `SS-010`) | Physical Android Handset *(pending interactive handset session)* | Android (physical device required) | Chrome for Android (physical camera, mic, speaker, soft keyboard) | `https://devfest-flutter-a59e8.web.app` | `2026-11-07` |

---

## 2. Rehearsal, Responsive Layout & Failure-Path Checks (`FAKE_BACKEND=true` / Automated)

> **Disclosure:** All checks in this table use simulated backend/media (`FAKE_BACKEND=true` / `DemoLiveTransport` / `DemoLiveMedia`) or isolated unit/widget harnesses. They verify responsive layout geometry, touch-target sizing, state guards, and UI workflows, **not** physical camera/microphone capture, live Gemini WebSocket streaming, or real Vonage message delivery.

| Test ID | Scenario | Env Profile | Viewport / Condition | Status | Evidence & Notes |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **REH-01** | Narrow phone viewport layout (`320×640`) without overflow | `ENV-TEST-RUNNER` | `320×640`, `textScale: 1.0` | **PASS (Rehearsal)** | Verified in `test/learner/mobile_layout_test.dart` (`cooking workspace fits 320.0x640.0`). Header `Wrap`, camera card, and workspace scroll cleanly to `Review dinner message` with zero `FlutterError` exceptions. |
| **REH-02** | Standard Android viewport layout (`360×740`) in native Chrome + test runner | `ENV-REHEARSAL-CHROME`, `ENV-TEST-RUNNER` | `360×740`, `textScale: 1.0` | **PASS (Rehearsal)** | Verified in native Chrome at `http://localhost:7358` (`docs/MVP-WORK-PLAN.md`) and `test/learner/mobile_layout_test.dart`. Rehearsal banner (`Rehearsal mode · Camera, voice, and AI responses are simulated. No messages are sent.`) and `SIMULATED` badge clearly visible. |
| **REH-03** | Mid/large phone viewports (`390×844`, `430×932`) and landscape (`740×360`) | `ENV-TEST-RUNNER` | `390×844`, `430×932`, `740×360` | **PASS (Rehearsal)** | Verified in `test/learner/mobile_layout_test.dart`. Single-column layout activates below `850px` width (`lib/learner/cooking_app.dart:223`); two-column split activates at `>=850px`. |
| **REH-04** | Enlarged text (`1.5x` text scale on `320×740`) + primary button touch targets (`>=48px` height) | `ENV-TEST-RUNNER` | `320×740`, `textScale: 1.5` | **PASS with Finding (`DEF-005`)** | `End live session`, `Mute`, and `Watch my bowl` buttons preserve `>=48px` height (`test/learner/mobile_layout_test.dart:73-81`). **Finding `DEF-005`:** `CheckboxListTile` in `ingredientChecklist` (`lib/genui/cooking_catalog.dart:66`) sets `dense: true`, reducing single-line ingredient tap rows below `48dp` at `1.0x` scale. |
| **REH-05** | Dinner-review dialog scrolling with phone soft keyboard inset (`bottom: 300px`) | `ENV-REHEARSAL-CHROME`, `ENV-TEST-RUNNER` | `360×640` with `viewInsets.bottom = 300` | **PASS (Rehearsal)** | `AlertDialog(scrollable: true, insetPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 16))` (`lib/learner/cooking_app.dart:741-747`) keeps `Recipient`, `Message`, `Close`, and `Rehearse send` reachable above a 300px keyboard inset (`test/learner/mobile_layout_test.dart:108-137`). |
| **REH-06** | Rehearsal 5-minute step timer countdown & wall-clock persistence | `ENV-REHEARSAL-CHROME`, `ENV-TEST-RUNNER` | `360×740` | **PASS (Rehearsal)** | Starting the Step 1 (`5-minute`) timer displays `5:00` and counts down visibly (`4:59` → `4:48` in native Chrome rehearsal). Latest timer ID, label, and absolute deadline persist to `CookingSession` for reload (`lib/learner/cooking_coordinator.dart:271-285`). |
| **REH-07** | Rehearsal `Check my bowl` comparison panel generation | `ENV-TEST-RUNNER` | `320×740`, `textScale: 1.5` | **PASS (Rehearsal)** | Tapping `Check my bowl` in rehearsal renders the `comparison` GenUI component titled `Rehearsal: a little more mashing` with explicit simulated disclosure (`This is an example response, not a camera assessment.`). |
| **REH-08** | Rehearsal watch guard (`Watch my bowl` blocked when `isDemo == true`) | `ENV-TEST-RUNNER` | Rehearsal mode (`isDemo: true`) | **PASS (Rehearsal)** | Tapping `Watch my bowl` in rehearsal mode sets `alert = 'Watch needs a real camera connection; rehearsal does not inspect food.'` (`lib/learner/cooking_coordinator.dart:288-294`) and never fakes a visual watch. |
| **REH-09** | Dinner review cancel, single-send lock, duplicate-tap guard, and ambiguous/timeout no-retry | `ENV-TEST-RUNNER` | Widget test harness (`test/learner/dinner_review_test.dart`) | **PASS with Findings (`DEF-001`, `DEF-002`)** | Model `dinner_ready` tool call only drafts text; closing sends nothing; explicit confirm submits once; synchronous duplicate taps before rebuild send once (`a2ec128`); `unknown` and `TimeoutException` never auto-retry. See **`DEF-001`** and **`DEF-002`** in Section 4 for HTTP 4xx/403 error masking and `_notificationId` reuse across dialog reopens. |
| **REH-10** | Browser media lifecycle cleanup (hidden tab, `pagehide`, track `onended`, stop during reconnect) | `ENV-TEST-RUNNER` | Node + Dart test suites (`2db067e`) | **PASS (Simulated Media)** | Verified in `test/live/browser_media_test.cjs`, `test/live/live_controller_test.dart`, and `test/live/ephemeral_transport_test.dart`. Hidden tab / `pagehide` / track end stops tracks, closes `AudioContext`, and suppresses stale frames; tool responses queue across brief resumption. |
| **REH-11** | Grounded cooking research panel (`SS-005`) isolated rehearsal (`lib/main_research_demo.dart`) | `ENV-TEST-RUNNER` | `lib/research/**`, `test/research/**` (`1553c7f`) | **PASS (Isolated Branch)** | `CookingResearchPanel` on branch `agy/cooking-research` (`1553c7f`) renders grounded answers, clickable HTTPS citations, `SearchSuggestions` attribution, uncited warning banner, targeted clarification input, and editable substitution confirmation. Integration into `lib/learner/cooking_app.dart` is tracked as **`DEF-004`** / `SS-003`. |

---

## 3. Deployed HTTPS & Physical Phone / Desktop Live Acceptance Matrix

> **Current Live Gate Status (`2026-11-07T18:18-05:00`):**
> - **Hosted Origin Reachability (`https://devfest-flutter-a59e8.web.app`):** **`PASS`** — Probed from `ENV-DESKTOP-WIN` on `2026-11-07T18:18:30-05:00`; returned `HTTP/1.1 200 OK` with HSTS (`max-age=31556926; includeSubDomains; preload`) and serves the compiled Flutter web entrypoint (`<base href="/">`). See [`docs/validation/cook-acceptance/hosted-http-probe-2026-11-07.txt`](./cook-acceptance/hosted-http-probe-2026-11-07.txt).
> - **Interactive Physical Phone & Live Audio/Video Session:** **`BLOCKED` / `NOT RUN`** in the automated agent session because physical camera/microphone hardware, interactive speaker/voice turns, and an attached Android handset require human-in-the-loop execution by Jenna/Terry using the step-by-step runbook in **Section 5**.
> - **Live Vonage Dinner Send (`POST /api/dinner-ready`):** **`BLOCKED` on `SS-021` & explicit send authorization** — `DINNER_SERVICE_READY` and `ENABLE_DINNER_MESSAGES` remain `false` by design until `VONAGE_*` secrets are provisioned in Secret Manager (`docs/VONAGE-SETUP.md`) and live sending is explicitly authorized.

| Test ID | Acceptance Requirement (`SS-023`) | Target Env | Build / URL | Date | Status | Blocker / Responsible Card & Evidence |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **LIVE-01** | Deployed HTTPS origin serves production Flutter web bundle (`FAKE_BACKEND=false`, no debug token) | `ENV-DESKTOP-WIN` | `https://devfest-flutter-a59e8.web.app` (`d350601`) | `2026-11-07` | **PASS** | `Invoke-WebRequest` HEAD & GET returned `HTTP/1.1 200 OK` (`X-Served-By: cache-mia-kmia1760097-MIA`) with production `index.html`. Evidence saved in `docs/validation/cook-acceptance/hosted-http-probe-2026-11-07.txt`. |
| **LIVE-02** | Anonymous Firebase Auth + production reCAPTCHA Enterprise App Check attestation in browser | `ENV-DESKTOP-WIN`, `ENV-PHONE-ANDROID` | `https://devfest-flutter-a59e8.web.app` | `2026-11-07` | **NOT RUN (Interactive Browser)** | API-level smoke succeeded in `SS-001`; interactive browser attestation and session creation on desktop and Android Chrome must be recorded during the human-in-the-loop run (Section 5, Step 1). |
| **LIVE-03** | Camera & microphone permission **Deny** recovery on deployed HTTPS | `ENV-PHONE-ANDROID`, `ENV-DESKTOP-WIN` | `https://devfest-flutter-a59e8.web.app` | `2026-11-07` | **NOT RUN (Physical Media)** | Requires interactive browser permission prompt denial, verifying inline error (`Could not start live cooking. Check camera/microphone permissions and the Live service, then reconnect.`), track release, and subsequent recovery after granting permission (`SS-002`, `SS-019`). |
| **LIVE-04** | Camera & microphone permission **Allow**, `POST /api/live-token` (`gemini-3.8-live` / `v1beta`), and 1 fps preview | `ENV-PHONE-ANDROID`, `ENV-DESKTOP-WIN` | `https://devfest-flutter-a59e8.web.app` | `2026-11-07` | **BLOCKED (`SS-002` / `SS-008` Live Smoke)** | Requires interactive camera/mic grant and verified `POST /api/live-token` ephemeral token handshake on the deployed origin. |
| **LIVE-05** | Real two-way voice conversation (2+ spoken turns), transcripts, and speech **interruption** | `ENV-PHONE-ANDROID` | `https://devfest-flutter-a59e8.web.app` | `2026-11-07` | **BLOCKED (`SS-002` Physical Audio)** | Requires speaking to the coach over the phone mic, hearing 24 kHz PCM playback, interrupting mid-sentence to verify queued audio flushes immediately (`CookingMedia.interrupt()`), and checking `SOUSSIGHT` transcript updates. |
| **LIVE-06** | Microphone **Mute / Unmute**, **End live session**, **hidden tab / background**, and **reconnect** | `ENV-PHONE-ANDROID` | `https://devfest-flutter-a59e8.web.app` | `2026-11-07` | **NOT RUN (Physical Lifecycle)** | Requires verifying `CAMERA ON · MIC MUTED` badge on mute, immediate camera/mic indicator shutoff when locking screen or switching tabs (`Camera paused because this tab is hidden. Return and reconnect.`), and clean reconnect (`SS-002`, `SS-019`). |
| **LIVE-07** | Live Gemini-generated Flutter GenUI panel (`show_cooking_ui` / `Check my bowl`) | `ENV-PHONE-ANDROID`, `ENV-DESKTOP-WIN` | `https://devfest-flutter-a59e8.web.app` | `2026-11-07` | **BLOCKED (`SS-003` Live Panel Check)** | Requires showing a real bowl of chickpeas, selecting a prediction chip (`Ready` / `Not yet` / `Not sure`), tapping `Check my bowl`, and verifying a validated native GenUI panel updates the workspace without appearance-based food-safety claims. |
| **LIVE-08** | Targeted cook clarification (`ask_cook` / `cookQuestion`) & confirmed-fact persistence across steps/reload | `ENV-PHONE-ANDROID`, `ENV-DESKTOP-WIN` | `https://devfest-flutter-a59e8.web.app` | `2026-11-07` | **FAIL / PARTIAL (`DEF-003` in `SS-003`)** | Confirmed facts persist to Firestore (`session.confirmedFacts`), **but** answering a clarification does not dismiss or disable the `'question'` / `cookQuestion` GenUI panel (`lib/learner/cooking_coordinator.dart:180-195`, `lib/genui/cooking_catalog.dart:150-160`), allowing duplicate answers on repeated taps. See **`DEF-003`**. |
| **LIVE-09** | Grounded cooking research & substitution flow with clickable HTTPS citations and Google Search attribution | `ENV-PHONE-ANDROID`, `ENV-DESKTOP-WIN` | `https://devfest-flutter-a59e8.web.app` | `2026-11-07` | **BLOCKED (`DEF-004` / `SS-004` + `SS-005` Merge)** | Backend AI Logic grounding smoke passed in `SS-004` (`gemini-3.8-flash`, 3 source chunks), and Jenna's `CookingResearchPanel` is built on `agy/cooking-research` (`1553c7f`), **but** `lib/learner/cooking_app.dart:648-686` on `main` does not yet mount `CookingResearchPanel` (missing clarification & substitution confirmation UI). See **`DEF-004`**. |
| **LIVE-10** | Real countdown timer expiry, chime during active Live audio, panel morph survival, and page reload restoration | `ENV-PHONE-ANDROID`, `ENV-DESKTOP-WIN` | `https://devfest-flutter-a59e8.web.app` | `2026-11-07` | **NOT RUN (Live Reload Check)** | Timer countdown and reload restoration logic are verified in widget tests (`SS-006`), but live browser reload restoration against Firestore and 880 Hz chime playback during an active Live session require interactive browser execution (Section 5, Step 5). |
| **LIVE-11** | Explicit opt-in visible-change watch (`Watch my bowl` → `Pause watch`), fresh-frame requirement, and step-change stop | `ENV-PHONE-ANDROID` | `https://devfest-flutter-a59e8.web.app` | `2026-11-07` | **BLOCKED (`SS-006` / `SS-002` Live Camera)** | Requires an active camera stream (`hasFreshFrame == true`), opting into `Watch my bowl`, observing periodic 8s checks (`watchId`), and confirming `Pause watch` or `Next step →` stops observations immediately. |
| **LIVE-12** | Dinner-ready recipient & message review **without sending** (pre-authorization) and error handling | `ENV-PHONE-ANDROID`, `ENV-DESKTOP-WIN` | `https://devfest-flutter-a59e8.web.app` | `2026-11-07` | **FAIL / BLOCKED (`DEF-001`, `DEF-002`, `SS-021`)** | Opening `Review dinner message`, editing recipient/message, and closing without sending works (`REH-05`, `REH-09`). However, live submission is blocked until `SS-021` secrets and explicit authorization are complete, and non-200 server responses (`403 recipient-not-allowed`, `409`) are misreported in UI as `"Message status could not be confirmed"` (`DEF-001`, `DEF-002`). |

---

## 4. Reproducible Defects & Runtime Findings for Terry (`@terryhh`)

Per `SS-023` acceptance criteria, Jenna reports these reproducible failures and integration gaps with exact file/line references and expected vs. actual behavior so Terry can resolve them in his runtime-owned files (`lib/learner/**`, `lib/data/**`, `lib/genui/**`). Machine-readable entries are also saved in [`docs/validation/cook-acceptance/reproducible-defects.json`](./cook-acceptance/reproducible-defects.json).

### `DEF-001` (High) — Dinner review masks HTTP `403` / `400` / `409` server rejections as ambiguous delivery status and locks the dialog
- **Related Cards:** `SS-007` (#17), `SS-023` (#41)
- **Owned Files (`@terryhh`):**
  - `lib/data/dinner_messages.dart` (lines `55–57`)
  - `lib/learner/cooking_app.dart` (lines `807–827`)
  - `functions/src/dinner-ready.js` (lines `25–27`, `49–61`, `188–194`)
- **Reproduction Steps:**
  1. Open the deployed app (`FAKE_BACKEND=false`) with `dinnerReady` deployed (`DINNER_SERVICE_READY=true`).
  2. Tap **Review dinner message** (`Icons.arrow_forward` in the bottom card).
  3. Enter a syntactically valid E.164 phone number that is **not** in `VONAGE_ALLOWED_TO` (e.g., `+14075559999`) and tap **Confirm and send**.
- **Expected Behavior:**
  - `POST /api/dinner-ready` returns HTTP `403` with `{ "error": { "code": "recipient-not-allowed", "message": "This recipient has not been enabled for the demo." } }` **before** claiming any `_dinnerNotifications` or `_dinnerMealClaims` document.
  - The UI should surface the server's explicit rejection reason (or `DinnerMessageResult('failed', ...).explanation`) and allow the cook to correct the recipient number.
- **Actual Behavior:**
  - `sendDinnerMessage` (`lib/data/dinner_messages.dart:55-57`) checks `if (response.statusCode != 200) throw StateError('Message request unavailable (${response.statusCode}).');`.
  - `_reviewDinner()` (`lib/learner/cooking_app.dart:818-823`) catches all exceptions identically and sets:
    `result = 'Message status could not be confirmed. No automatic resend will occur.'`
  - Setting `result != null` permanently disables the `Recipient` input, `Message` input, and `Confirm and send` button inside the open dialog (`enabled: !sending && result == null`), falsely telling the cook that the message status is uncertain when the backend deterministically rejected the recipient before contacting Vonage.

---

### `DEF-002` (Medium) — `_notificationId` is allocated once per `_CookingScreenState` lifetime, causing `409 idempotency-conflict` if message/recipient is edited after a failed attempt
- **Related Cards:** `SS-007` (#17), `SS-025` (#46)
- **Owned Files (`@terryhh`):**
  - `lib/learner/cooking_app.dart` (line `93` & lines `808–813`)
  - `functions/src/dinner-ready.js` (lines `37–57`)
- **Reproduction Steps:**
  1. In a live session, open **Review dinner message** and submit a request that claims the notification ID in `_dinnerNotifications` or fails after claim (or reopen the dialog after closing and change the message text).
  2. Reopen **Review dinner message**, edit the `Message` text, and tap **Confirm and send**.
- **Expected Behavior:**
  - Re-submitting the exact same review attempt uses the same idempotency key, whereas starting a new distinct review after a non-claiming validation error (or in a new session) should not collide on a stale `_notificationId` with a different payload fingerprint.
- **Actual Behavior:**
  - `_CookingScreenState` declares `final _notificationId = const Uuid().v4();` once at widget initialization (`lib/learner/cooking_app.dart:93`). If an earlier attempt recorded `_dinnerNotifications/{sha256(uid + notificationId)}` and the cook later reopens the dialog and edits the message text, `functions/src/dinner-ready.js:53-55` sees a mismatched `fingerprint` for the same `notificationId` and throws HTTP `409 idempotency-conflict` (`"This notification ID already belongs to a different message."`), which `DEF-001` then turns into `"Message status could not be confirmed."`

---

### `DEF-003` (Medium) — Answering a cook clarification (`ask_cook` / `cookQuestion`) leaves the question panel and option buttons active in the GenUI workspace
- **Related Cards:** `SS-003` (#13)
- **Owned Files (`@terryhh`):**
  - `lib/learner/cooking_coordinator.dart` (lines `180–195`, `395–404`, `474–478`)
  - `lib/genui/cooking_catalog.dart` (lines `118–169`)
- **Reproduction Steps:**
  1. Trigger a cook clarification either via the Live `ask_cook` tool call (which upserts component `id: 'question'` in `lib/learner/cooking_coordinator.dart:397-404`) or via `show_cooking_ui` containing a `cookQuestion` catalog item (`lib/genui/cooking_catalog.dart:118-169`).
  2. Submit an answer in the text box (`Your answer to the coach…`) **or** tap one of the `OutlinedButton` option chips in the `cookQuestion` panel.
  3. Observe the workspace after the answer is saved.
- **Expected Behavior:**
  - Once the cook explicitly answers the clarification, the question panel should either transition to a confirmed/answered state or be removed from the active workspace so the cook cannot accidentally submit duplicate conflicting facts by tapping the option buttons again.
- **Actual Behavior:**
  - `confirmCookAnswer` (`lib/learner/cooking_coordinator.dart:180-195`) appends `$question Answer from cook: ${answer.trim()}` to `session.confirmedFacts` and sets `cookQuestion = null` (which changes the bottom text field hint back to `'Ask a cooking question…'`), **but leaves the GenUI `'question'` / `cookQuestion` panel mounted and interactive**. Tapping `cookQuestion` option buttons repeatedly appends duplicate facts to `session.confirmedFacts` and sends repeated turns to Live.

---

### `DEF-004` (Medium) — Main cooking workspace (`lib/learner/cooking_app.dart`) does not yet mount `CookingResearchPanel` (`SS-005`) and requires two taps when starting research from an empty input box
- **Related Cards:** `SS-003` (#13), `SS-004` (#14), `SS-005` (#15)
- **Owned Files (`@terryhh` for `lib/learner/cooking_app.dart` wiring; `@jennajh` owns `lib/research/**`):**
  - `lib/learner/cooking_app.dart` (lines `513–525` & `648–686`)
- **Reproduction Steps:**
  1. Open the cooking screen with the question text box empty.
  2. Tap **Research a cooking question** (`lib/learner/cooking_app.dart:513-525`).
  3. Observe that no research query starts on the first tap (it only sets `_message.text = 'Can I use vinegar instead of lemon in this recipe?'`).
  4. Tap **Research a cooking question** a second time and inspect the rendered result card (`lib/learner/cooking_app.dart:648-686`).
- **Expected Behavior:**
  - Once `SS-005` (`agy/cooking-research` @ `1553c7f`) is merged, `CookingScreen` should render `CookingResearchPanel` so the cook gets targeted follow-up clarification inputs, uncited-answer warnings, and the editable substitution confirmation flow (`onConfirmSubstitution`) that updates confirmed session state only after explicit cook approval.
- **Actual Behavior:**
  - On `origin/main` (`d350601`), `lib/learner/cooking_app.dart:648-686` renders a minimal inline `Card` (`SelectableText(result.answer)`, raw `TextButton.icon` links, and `SearchSuggestions`) without clarification or substitution confirmation controls, and tapping **Research a cooking question** with an empty input silently populates the text field without focusing or submitting it.

---

### `DEF-005` (Low) — `ingredientChecklist` uses `CheckboxListTile(dense: true)`, reducing touch target height below 48dp on mobile viewports
- **Related Cards:** `SS-019` (#34)
- **Owned Files (`@terryhh`):**
  - `lib/genui/cooking_catalog.dart` (lines `63–75`)
- **Reproduction Steps:**
  1. Open the cooking workspace at `320×640` or `360×740` with `textScale: 1.0`.
  2. Inspect the `On your counter` (`ingredientChecklist`) rows (`1 can (15 oz) chickpeas, drained`, `1 tbsp olive oil`, etc.).
- **Expected Behavior:**
  - Interactive touch targets in mobile Chrome should maintain at least `48×48dp` height, matching the `minimumSize: Size(48, 48)` configured for `FilledButton`, `OutlinedButton`, and `TextButton` in `cookingTheme` (`lib/learner/cooking_app.dart:25-33`).
- **Actual Behavior:**
  - `CheckboxListTile` in `lib/genui/cooking_catalog.dart:66` specifies `dense: true` and `contentPadding: EdgeInsets.zero`, compacting single-line ingredient rows to ~40dp vertical height on `1.0x` text scale.

---

## 5. Step-by-Step Physical Phone & Desktop Execution Runbook

Use this checklist during the interactive physical Android Chrome and desktop Chrome pass against `https://devfest-flutter-a59e8.web.app`. Record screenshots in `docs/validation/cook-acceptance/` (redact any personal notification recipients or account identifiers before committing).

### Pre-Flight Metadata to Record Before Starting
- **Date / Time (ISO-8601):** `____________________`
- **Deployed Commit / GitHub Actions Run ID:** `____________________`
- **Phone Model & Android OS Version:** `____________________`
- **Phone Chrome Version (`chrome://version`):** `____________________`
- **Desktop OS & Chrome Version:** `Windows 11 (10.0.26300.0) / Chrome 157.0.8103.38`

### Step 1 — Cold Load, Auth/App Check & Mobile Layout (`320–430px`)
1. Open `https://devfest-flutter-a59e8.web.app` on Android Chrome in portrait (`360–412px` CSS width) and with Android system font size set to **150% (Large/Largest)**.
2. Confirm the `Opening your kitchen…` bootstrap screen transitions to `SousSight` (`Your live cooking companion` badge—**not** `Interactive rehearsal`).
3. Verify zero horizontal overflow across Header, `Smashed Chickpea Salad Wrap` title, `CAMERA OFF` card, `Cook with me` / `Watch my bowl` controls, and `Your cooking space` (`1 / 4`).
4. Capture screenshot: `docs/validation/cook-acceptance/phone-01-cold-load-large-text.png`.

### Step 2 — Camera & Microphone Permission Deny → Allow Recovery
1. Tap **Cook with me** and **Deny** camera/microphone permission on the first prompt.
2. Verify the inline error notice appears (`Could not start live cooking. Check camera/microphone permissions and the Live service, then reconnect.`) and the button returns to **Cook with me**.
3. Reset site permission to **Allow**, tap **Cook with me** again, and verify:
   - Rear camera (`facingMode: environment`) frames appear in the 4:3 preview at ~1 fps.
   - Status pill updates from `CONNECTING` to `LISTENING & LOOKING` or `COACH SPEAKING`.
   - Coach speaks an opening greeting at 24 kHz and `SOUSSIGHT` transcript card updates.
4. Capture screenshot: `docs/validation/cook-acceptance/phone-02-live-connected.png`.

### Step 3 — Two-Way Voice, Interruption, Mute, Hide/Background & Reconnect
1. Speak to the coach: *"I have the canned chickpeas, olive oil, and red onion, but I don't have a lemon."*
2. While the coach is speaking its reply (`COACH SPEAKING`), speak over the coach to interrupt and verify audio playback cuts off immediately and switches to `LISTENING & LOOKING`.
3. Tap **Mute**; verify badge changes to `CAMERA ON · MIC MUTED` while camera frames continue updating. Tap **Unmute**.
4. Switch to another browser tab or lock the phone screen for 3 seconds, then return:
   - Verify camera/mic indicator turned off while hidden and inline error reads: `Camera paused because this tab is hidden. Return and reconnect.`
5. Tap **Cook with me** to reconnect, then tap **End live session** and confirm media capture stops cleanly.

### Step 4 — Generated GenUI Panel, Cook Clarification & Grounded Research
1. Reconnect (**Cook with me**), check off available ingredients in `On your counter`, select a prediction chip (`Not yet`), point the camera at partially mashed chickpeas, and tap **Check my bowl**.
2. Verify the workspace updates to a generated GenUI comparison/step panel and that the coach describes visible texture cues without claiming internal temperature or food safety.
3. Answer any targeted clarification question from the coach and reload the page (`F5` / pull-to-refresh) to verify confirmed ingredients and confirmed facts persist in the session.
4. Ask: *"Can I use apple cider vinegar instead of lemon juice in this chickpea salad?"* and tap **Research a cooking question**.
5. Verify returned citations are clickable HTTPS links from grounding metadata and Google Search suggestions attribution renders.
6. Capture screenshot: `docs/validation/cook-acceptance/phone-03-panel-and-research.png`.

### Step 5 — Real Countdown Timer & Opt-In Visible-Change Watch
1. Advance to Step 2 (`Quick-soak the red onion`) or tap **Start 5-minute timer** (and request a short 15-second demo timer via voice: *"Start a 15-second demo timer"*).
2. Reload the page while the timer is running and confirm the latest timer restores with its original wall-clock deadline.
3. When the 15-second timer reaches `0:00`, verify the `TIME TO CHECK` state, alert banner (`...: time is up. Check your food.`), and 880 Hz chime (when Live is active).
4. With Live active, tap **Watch my bowl**; verify the `WATCHING WITH YOU` panel appears, then tap **Pause watch** (or **Next step →**) and confirm the watch transitions to `WATCH PAUSED` and stops polling.
5. Capture screenshot: `docs/validation/cook-acceptance/phone-04-timer-and-watch.png`.

### Step 6 — Dinner-Ready Message Review (Pre-Authorization & Authorized Send)
1. Scroll to the bottom card (`Call everyone to the table`) and tap **Review dinner message** (`Icons.arrow_forward`).
2. Tap into the `Recipient` and `Message` fields on the phone so the soft keyboard opens; verify both inputs and the `Close` / `Confirm and send` buttons remain scrollable above the keyboard.
3. **While `SS-021` / `ENABLE_DINNER_MESSAGES=false` (Dry-Run / Pre-Authorization):**
   - Verify validation error on invalid phone format, then tap **Close** without sending, or verify dry-run returns `Rehearsal only: no message was sent.` (`status: "skipped"`).
4. **Only after `SS-021` secrets are configured and explicit send authorization is granted (`ENABLE_DINNER_MESSAGES=true`):**
   - Start a fresh cooking session, enter the allowlisted household contact, review the exact message, and tap **Confirm and send** once.
   - Verify the UI displays: `Vonage accepted the message. Delivery is not yet confirmed.` (`status: "submitted"`), **never** claiming confirmed handset delivery from the API response alone.
5. Capture redacted screenshot (masking phone number): `docs/validation/cook-acceptance/phone-05-dinner-review-redacted.png`.
