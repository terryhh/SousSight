# Physical Cook Acceptance & Reproducible Failure Report (`SS-023`)

- **Ticket:** [Issue #41 (`SS-023`)](https://github.com/terryhh/SousSight/issues/41) — Run physical cook acceptance and report reproducible failures
- **Owner:** Jenna (`@jennajh`)
- **Runtime / Integration Counterpart:** Terry (`@terryhh`) — supplies acceptance evidence to [`SS-010` (#20)](https://github.com/terryhh/SousSight/issues/20) and [`SS-019` (#34)](https://github.com/terryhh/SousSight/issues/34)
- **Last Updated:** `2026-11-07`
- **Evaluated Commit (`origin/main`):** `e348527` (`Merge pull request #70 from terryhh/codex/final-acceptance`)
- **Merged Research Panel & Integration (`SS-005` / `SS-026`):** `7ce623b` (PR #45 / PR #57 `f079303`) + `2bad9dd` (PR #61 `75c5380`)

> **Verification Honesty & Scope Rule (`AGENTS.md`):**
> - Rehearsal (`FAKE_BACKEND=true`), automated widget/unit tests, synthetic token/tool probes, HTTP reachability probes, and DevTools viewport checks are strictly separated from deployed HTTPS and physical device checks.
> - Unavailable hardware, unconfigured secrets, or unverified interactive scenarios are marked **`BLOCKED`** or **`NOT RUN`**—never **`PASS`**.
> - No Terry-owned runtime files (`lib/learner/**`, `lib/live/**`, `lib/genui/**`, `lib/data/**`, `functions/**`) are modified by this validation deliverable. All reproducible runtime defects are documented in **Section 4** for Terry's runtime fix pass.

---

## 1. Environments, Devices & Builds Under Test

Every test row in Sections 2 and 3 references one of the explicit environment profiles below:

| Profile ID | Role | Device / Hardware | OS / Platform | Browser / Runtime | URL / Entrypoint & Build | Date |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **`ENV-DESKTOP-WIN`** | Desktop HTTP Reachability Probe Host | x64 Windows Workstation | Windows 11 (`Microsoft Windows NT 10.0.26300.0`) | PowerShell `Invoke-WebRequest` (Google Chrome `157.0.8103.38` installed) | `https://devfest-flutter-a59e8.web.app` (HTTP `HEAD`/`GET` reachability probe only) | `2026-11-07` |
| **`ENV-DESKTOP-HOSTED`** | Desktop Native Chrome Hosted Verification | Desktop Workstation (`terryhh` hosted verification sessions in [`docs/MVP-READINESS.md`](../MVP-READINESS.md)) | Desktop OS | Native Google Chrome (Normal + Incognito / Cache-Disabled) | `https://devfest-flutter-a59e8.web.app` (rollouts `42422724152`, `42424326318`, `42425656543`, `42425937906`, `42428461526`) | `2026-11-07` |
| **`ENV-REHEARSAL-CHROME`** | Local Simulated Mobile & Desktop Rehearsal | Desktop Chrome + DevTools Mobile Viewport (`360×740`) | Desktop OS (`terryhh` rehearsal sessions in [`docs/MVP-WORK-PLAN.md`](../MVP-WORK-PLAN.md) & [`docs/MVP-READINESS.md`](../MVP-READINESS.md)) | Native Google Chrome (DevTools Device Emulation `360×740`) | `http://localhost:7358` (`lib/main_learner.dart` with `FAKE_BACKEND=true`, PR #35 @ `1315dbd` & PR #64 @ `da97bf9`) | `2026-11-07` |
| **`ENV-TEST-RUNNER`** | Automated Widget, Layout, Lifecycle & Rules Suite | Headless CI / Local Test Runner | Flutter `3.47.9` / Dart `3.13.7`, Node `22.23.4` | `flutter test` + Node test runner + Firestore Rules Emulator | `origin/main` @ `e348527` (133+ Flutter tests, 25 backend tests, 10 Firestore rules tests) | `2026-11-07` |
| **`ENV-PHONE-ANDROID`** | Physical Android Phone Target (`SS-019` / `SS-010`) | Physical Android Handset *(pending interactive handset session)* | Android (physical device required) | Chrome for Android (physical camera, mic, speaker, soft keyboard) | `https://devfest-flutter-a59e8.web.app` | `2026-11-07` |

---

## 2. Rehearsal, Responsive Layout & Failure-Path Checks (`FAKE_BACKEND=true` / Automated)

> **Disclosure:** All checks in this table use simulated backend/media (`FAKE_BACKEND=true` / `DemoLiveTransport` / `DemoLiveMedia`) or isolated unit/widget harnesses. They verify responsive layout geometry, sticky control-dock stability, touch-target sizing, state guards, and UI workflows, **not** physical camera/microphone capture, live Gemini WebSocket streaming, or real Vonage message delivery.

| Test ID | Scenario | Env Profile | Viewport / Condition | Status | Evidence & Notes |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **REH-01** | Narrow phone viewport layout (`320×640`) without overflow + full-width `CAMERA OFF` preview | `ENV-TEST-RUNNER` | `320×640`, `textScale: 1.0` | **PASS (Rehearsal)** | Verified in `test/learner/mobile_layout_test.dart` (`cooking workspace fits 320.0x640.0` and PR #52 `39c8451`). Header `Wrap`, full-width camera placeholder, workspace, and sticky `_controlDock` render with zero `FlutterError` exceptions. |
| **REH-02** | Standard Android viewport layout (`360×740`) in native Chrome + test runner | `ENV-REHEARSAL-CHROME`, `ENV-TEST-RUNNER` | `360×740`, `textScale: 1.0` | **PASS (Rehearsal)** | Verified in native Chrome at `http://localhost:7358` ([`docs/MVP-WORK-PLAN.md`](../MVP-WORK-PLAN.md), [`docs/MVP-READINESS.md`](../MVP-READINESS.md)) and `test/learner/mobile_layout_test.dart`. Rehearsal banner (`Rehearsal mode · Camera, voice, and AI responses are simulated. No messages are sent.`) and `SIMULATED` badge clearly visible; simulated `360px` viewport also exercised the stable control dock, scrolling, and `Stop`. |
| **REH-03** | Mid/large phone viewports (`390×844`, `430×932`) and landscape (`740×360`) | `ENV-TEST-RUNNER` | `390×844`, `430×932`, `740×360` | **PASS (Rehearsal)** | Verified in `test/learner/mobile_layout_test.dart`. Single-column layout activates below `850px` width (`lib/learner/cooking_app.dart:217`); two-column split activates at `>=850px`. |
| **REH-04** | Enlarged text (`1.5x` text scale on `320×740`), sticky control dock, pending-capture `Stop`, and touch targets (`>=48px` height) | `ENV-TEST-RUNNER` | `320×740`, `textScale: 1.5`, keyboard inset `300px` | **PASS (Rehearsal)** | `live-session-toggle` (`Stop`/`Start`), `microphone-toggle`, and `Watch my bowl` preserve `>=48px` height (`test/learner/mobile_layout_test.dart:251-261`), and `VisualDensity.standard` in `cookingTheme` keeps single-line `ListTile`/`CheckboxListTile` rows at a `48dp` minimum height. PR #64 (`da97bf9`, `SS-028`) and PR #70 (`089ca74`) verify that `cooking-message-input` and `live-session-toggle` stay stationary and focused above a `300px` keyboard inset while generated panels expand, and that tapping pinned `Stop` during a pending permission request cancels capture without resurrection (`test/learner/mobile_layout_test.dart:54-107`, `282-362`). |
| **REH-05** | Dinner-review dialog scrolling with phone soft keyboard inset (`bottom: 300px`) | `ENV-REHEARSAL-CHROME`, `ENV-TEST-RUNNER` | `360×640` with `viewInsets.bottom = 300` | **PASS (Rehearsal)** | `AlertDialog(scrollable: true, insetPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 16))` (`lib/learner/cooking_app.dart:737-743`) keeps `Recipient`, `Message`, `Close`, and `Rehearse send` reachable above a 300px keyboard inset (`test/learner/mobile_layout_test.dart:364-393`). |
| **REH-06** | Rehearsal 5-minute step timer countdown & wall-clock persistence | `ENV-REHEARSAL-CHROME`, `ENV-TEST-RUNNER` | `360×740` | **PASS (Rehearsal)** | Starting the Step 1 (`5-minute`) timer displays `5:00` and counts down visibly (`4:59` → `4:48` in native Chrome rehearsal). Latest timer ID, label, and absolute deadline persist to `CookingSession` for reload (`lib/learner/cooking_coordinator.dart:290-304`). |
| **REH-07** | Rehearsal `Check my bowl` comparison panel generation & stale-step workspace rejection | `ENV-TEST-RUNNER` | `320×740`, `textScale: 1.5` | **PASS (Rehearsal)** | Tapping `Check my bowl` in rehearsal renders `Rehearsal: a little more mashing` with explicit simulated disclosure. PR #56 (`9f28b14`) rejects late `show_cooking_ui` payloads whose `stepId` does not match the current recipe step (`test/learner/cooking_coordinator_test.dart:427-470`). |
| **REH-08** | Rehearsal watch guard (`Watch my bowl` blocked when `isDemo == true`) | `ENV-TEST-RUNNER` | Rehearsal mode (`isDemo: true`) | **PASS (Rehearsal)** | Tapping `Watch my bowl` in rehearsal mode sets `alert = 'Watch needs a real camera connection; rehearsal does not inspect food.'` (`lib/learner/cooking_coordinator.dart:307-313`) and never fakes a visual watch. |
| **REH-09** | Dinner review cancel, single-send lock, duplicate-tap guard, and ambiguous/timeout no-retry | `ENV-TEST-RUNNER` | Widget + backend test harness (`a2ec128`, `3cf47a6`) | **PASS with Findings (`DEF-001`, `DEF-002`)** | Model `dinner_ready` tool call only drafts text; closing sends nothing; explicit confirm submits once; synchronous duplicate taps before rebuild send once (`a2ec128`); `unknown` and `TimeoutException` never auto-retry; backend supports `DINNER_CHANNEL=sms` with exact trial sender `Vonage APIs` (`3cf47a6`). See **`DEF-001`** (tracked in `SS-030` / #72) and **`DEF-002`** in Section 4 for client-side HTTP 4xx/403 error masking on `e348527` and `_notificationId` reuse across dialog reopens. |
| **REH-10** | Browser media lifecycle cleanup (hidden tab, `pagehide`, track `onended`, stop during reconnect) | `ENV-TEST-RUNNER` | Node + Dart test suites (`2db067e`, `645eefb`) | **PASS (Simulated Media)** | Verified in `test/live/browser_media_test.cjs`, `test/live/live_controller_test.dart`, and `test/live/ephemeral_transport_test.dart`. Hidden tab / `pagehide` / track end stops tracks, closes `AudioContext`, and suppresses stale frames; per-turn transcripts reset cleanly (`645eefb`). |
| **REH-11** | Grounded cooking research panel (`SS-005` / `SS-026`) & shared learner integration | `ENV-TEST-RUNNER` | `lib/research/**`, `lib/learner/research_panel_client.dart` (`7ce623b`, `2bad9dd`) | **PASS with Finding (`DEF-004`)** | Jenna's `CookingResearchPanel` (`7ce623b`, 8 widget tests) is merged via PR #57 and integrated into `CookingScreen` via `ResearchPanelClient` in PR #61 (`2bad9dd`, `SS-026` `Done`), preventing duplicate initial research calls and forwarding confirmed substitutions to `session.confirmedFacts`. See **`DEF-004`** for the two-tap empty-input UX on `Research a cooking question`. |

---

## 3. Deployed HTTPS & Physical Phone / Desktop Live Acceptance Matrix

> **Current Live Gate Status (`2026-11-07`):**
> - **Production Real-Mode Deployment & Browser Verification (`ENV-DESKTOP-HOSTED`):** Verified in [`docs/MVP-READINESS.md`](../MVP-READINESS.md) — GitHub Actions rollout `42422724152` attempt 2 deployed `main` (`d350601`) and native Chrome loaded the real-mode app (`FAKE_BACKEND=false`, no CI debug token), completing a production Auth + reCAPTCHA Enterprise App Check + `gemini-3.8-flash` grounded research query. Subsequent rollouts verified protected `/api/live-token` (`42423984364`), full-width `CAMERA OFF` (`42424326318`), real Gemini-generated GenUI panels and timers (`42425656543`), `Cache-Control: no-cache` on `main.dart.js` (`42425937906`), hosted `CookingResearchPanel` fact confirmation (`198b2ab`), hosted `cookQuestion` choice + pinned `Stop` (`c5141d6`), user-confirmed two-way desktop speech (`7bf0141`), and `dinnerReady` SMS deployment with sending disabled (`42428461526`).
> - **HTTP Reachability Log (`ENV-DESKTOP-WIN`):** [`docs/validation/cook-acceptance/hosted-http-probe-2026-11-07.txt`](./cook-acceptance/hosted-http-probe-2026-11-07.txt) records an unauthenticated `HEAD`/`GET` check (`HTTP/1.1 200 OK`, HSTS `max-age=31556926; includeSubDomains; preload`), which establishes origin reachability only—not compiled Dart flags or deployment identity.
> - **Physical Android Phone (`ENV-PHONE-ANDROID`) & Remaining Live Checks:** Physical Android Chrome camera/microphone permissions, phone speech interruption, hidden-tab/background lifecycle, post-reload confirmed-fact persistence, deployed stale-step guard, and opt-in visible-change watch lifecycle remain **`IN PROGRESS` / `NOT RUN`** and must be completed using the runbook in **Section 5**.
> - **Live Vonage Dinner Send (`POST /api/dinner-ready`):** **`BLOCKED` on explicit send authorization** — `dinnerReady` is deployed and `ACTIVE` on Node 22 (`run 42428461526`) with `DINNER_CHANNEL=sms`, `DINNER_SERVICE_READY=true`, and the four enabled Vonage Secret Manager versions (`VONAGE_API_KEY/3`, `VONAGE_API_SECRET/3`, `VONAGE_FROM/2`, `VONAGE_ALLOWED_TO/1`) bound for runtime access, while `ENABLE_DINNER_MESSAGES=false` keeps provider sending disabled until a real cook-reviewed send is explicitly authorized ([`docs/COST-LEDGER.md`](../COST-LEDGER.md)).

| Test ID | Acceptance Requirement (`SS-023`) | Target Env | Build / URL | Date | Status | Blocker / Responsible Card & Evidence |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **LIVE-01** | Deployed HTTPS origin serves production Flutter web bundle (`FAKE_BACKEND=false`, no debug token) | `ENV-DESKTOP-HOSTED`, `ENV-DESKTOP-WIN` | `https://devfest-flutter-a59e8.web.app` (rollouts `42422724152`, `42425937906`, `42428461526`) | `2026-11-07` | **PASS** | Verified directly in [`docs/MVP-READINESS.md`](../MVP-READINESS.md): rollout `42422724152` attempt 2 deployed `main` (`d350601`) and native Chrome loaded the production real-mode app (`FAKE_BACKEND=false`) and executed a real grounded research request through production Auth and reCAPTCHA Enterprise App Check without a CI debug token; rollout `42425937906` verified `Cache-Control: no-cache` on production `main.dart.js`. (Note: [`hosted-http-probe-2026-11-07.txt`](./cook-acceptance/hosted-http-probe-2026-11-07.txt) establishes HTTP `200` reachability and HSTS headers only, not compiled flags.) |
| **LIVE-02** | Anonymous Firebase Auth + production reCAPTCHA Enterprise App Check attestation in browser | `ENV-DESKTOP-HOSTED` (Desktop: **PASS**), `ENV-PHONE-ANDROID` (Phone: **NOT RUN**) | `https://devfest-flutter-a59e8.web.app` (`run 42422724152`) | `2026-11-07` | **PARTIAL (Desktop PASS / Phone NOT RUN)** | Verified in desktop Chrome after rollout `42422724152` without a CI debug token (`SS-001` & `SS-016` `Done`; [`docs/MVP-READINESS.md`](../MVP-READINESS.md)). Physical Android Chrome verification remains open (`SS-019`). |
| **LIVE-03** | Camera & microphone permission **Deny** recovery on deployed HTTPS | `ENV-PHONE-ANDROID`, `ENV-DESKTOP-HOSTED` | `https://devfest-flutter-a59e8.web.app` | `2026-11-07` | **NOT RUN (Interactive Permission Check)** | Earlier native Chrome permission denial blocked connection as expected, and PR #70 (`089ca74`) covers pending-permission `Stop` in widget tests, but structured deny → inline error → allow recovery on Android Chrome remains to be recorded (Section 5, Step 2; `SS-002`, `SS-019`). |
| **LIVE-04** | Camera & microphone permission **Allow**, `POST /api/live-token` (`gemini-3.8-live` / `v1beta`), and 1 fps preview | `ENV-DESKTOP-HOSTED` (Desktop: **PASS**), `ENV-PHONE-ANDROID` (Phone: **NOT RUN**) | `https://devfest-flutter-a59e8.web.app` (rollouts `42423984364` & `42425656543`) | `2026-11-07` | **PARTIAL (Desktop PASS / Phone NOT RUN)** | `SS-008` is `Done`: hosted `/api/live-token` returned a valid ephemeral token and `38,402` audio bytes in `2,368 ms` (`gemini-3.8-live`, `v1beta`). Hosted desktop Chrome sessions showed live camera preview and `COACH SPEAKING` ([`docs/MVP-READINESS.md`](../MVP-READINESS.md)). Physical Android phone camera/mic connection remains `NOT RUN` (`SS-002`, `SS-019`). |
| **LIVE-05** | Real two-way voice conversation (2+ spoken turns), distinct mic recognition, transcripts, and speech **interruption** | `ENV-DESKTOP-HOSTED` (Desktop 2-way speech: **PASS**), `ENV-PHONE-ANDROID` (Phone & Interruption: **NOT RUN**) | `https://devfest-flutter-a59e8.web.app` | `2026-11-07` | **PARTIAL (Desktop 2-Way Speech PASS / Phone & Interruption NOT RUN)** | Terry confirmed audible desktop coach playback and explicitly confirmed `"I spoke and it understood me"` in the latest hosted live session (`7bf0141`, [`docs/MVP-READINESS.md`](../MVP-READINESS.md)). Mid-sentence speech **interruption** and physical Android Chrome voice turns remain unverified (`SS-002`). |
| **LIVE-06** | Microphone **Mute / Unmute**, **Stop**, **hidden tab / background**, and **reconnect** | `ENV-DESKTOP-HOSTED` (Desktop Stop/Mute/Reload: **PASS**), `ENV-PHONE-ANDROID` (Phone: **NOT RUN**) | `https://devfest-flutter-a59e8.web.app` | `2026-11-07` | **PARTIAL (Desktop Stop/Mute/Reload PASS / Phone & Hidden-Tab NOT RUN)** | Hosted desktop Chrome verified microphone mute, clicking pinned `Stop` (turning camera/mic off and clearing Chrome's recording indicator, `c5141d6`), and browser reload track release (`CAMERA OFF`, `e7ac91c`). Hidden-tab pause, reconnect recovery, and physical Android Chrome lifecycle checks remain `NOT RUN` (`SS-002`, `SS-019`). |
| **LIVE-07** | Live Gemini-generated Flutter GenUI panel (`show_cooking_ui` / `Check my bowl`) & stable input dock | `ENV-DESKTOP-HOSTED` (Desktop: **PASS**), `ENV-PHONE-ANDROID` (Phone: **NOT RUN**) | `https://devfest-flutter-a59e8.web.app` (`run 42425656543`, `c5141d6`) | `2026-11-07` | **PARTIAL (Desktop Panel & Dock PASS / Phone NOT RUN)** | Hosted desktop Chrome verified real Gemini Live generation of `stepCue` (`"Quick-pickle the onion"`), `cookingTimer` (`"Pickle onions"`), `comparison` (`"Mash texture check"`), and `cookQuestion` (`"Chickpea Texture"` → `"Got it: Smooth chickpeas"`), with the pinned composer remaining stable through recomposition (`SS-028` `Done`; [`docs/MVP-READINESS.md`](../MVP-READINESS.md)). Physical Android Chrome check remains `NOT RUN` (`SS-019`). |
| **LIVE-08** | Targeted cook clarification (`ask_cook` / `cookQuestion`), stale-step guard, & confirmed-fact persistence | `ENV-DESKTOP-HOSTED`, `ENV-PHONE-ANDROID` | `https://devfest-flutter-a59e8.web.app` (`c5141d6`) | `2026-11-07` | **PARTIAL (`SS-003` Question/Choice PASS; Reload Persistence & `DEF-003` Open)** | Hosted desktop Chrome (`c5141d6`) verified a real Gemini `"Chickpea Texture"` `cookQuestion` (`Chunky`/`Smooth`), explicit `Smooth` selection, coach caption acknowledgement, and panel replacement (`"Got it: Smooth chickpeas"`). However, post-reload confirmed-fact persistence and deployed stale-step rejection were not verified in that live run (`SS-003`), and offline/pre-turn option buttons remain active until a replacement workspace arrives (`DEF-003`). |
| **LIVE-09** | Grounded cooking research & substitution flow with clickable HTTPS citations and Google Search attribution | `ENV-DESKTOP-HOSTED` (Desktop: **PASS**), `ENV-PHONE-ANDROID` (Phone: **NOT RUN**) | `https://devfest-flutter-a59e8.web.app` (`198b2ab`) | `2026-11-07` | **PARTIAL (Desktop Research & Confirm PASS / Reload & Phone NOT RUN)** | Hosted desktop Chrome (`198b2ab`, [`docs/MVP-READINESS.md`](../MVP-READINESS.md)) opened the integrated `CookingResearchPanel` from the stable dock, displayed a grounded answer with 9 sources, the Google logo, and provider suggestion chips, and confirmed `"Acceptance test: use a fork to keep the chickpea mixture chunky."` into `Cook-confirmed kitchen facts` (`SS-004`, `SS-005`, `SS-026` `Done`). Post-reload fact persistence, physical Android Chrome check, and **`DEF-004`** (two-tap empty-input button UX) remain open. |
| **LIVE-10** | Real countdown timer expiry, chime during active Live audio, panel morph survival, and page reload restoration | `ENV-DESKTOP-HOSTED` (Desktop Countdown/Reload/Expiry/Dismiss: **PASS**), `ENV-PHONE-ANDROID` (Phone: **NOT RUN**) | `https://devfest-flutter-a59e8.web.app` (`e7ac91c`, `29d1e01`) | `2026-11-07` | **PARTIAL (Desktop Timer Lifecycle PASS / Chime & Phone NOT RUN)** | Hosted desktop Chrome verified a real Gemini-started `"Pickle onions"` timer counting down (`4:57 → 4:44 → 4:34`) across panel replacement (`e7ac91c`), persisting across reload, counting down `0:36 → 0:22 → 0:00` to `TIME TO CHECK`, and remaining removed after `Dismiss` and a subsequent reload (`29d1e01`, [`docs/MVP-READINESS.md`](../MVP-READINESS.md)). Active-Live 880 Hz chime and physical Android timer check remain `NOT RUN` (`SS-006`). |
| **LIVE-11** | Explicit opt-in visible-change watch (`Watch my bowl` → `Pause watch`), fresh-frame requirement, and step-change stop | `ENV-PHONE-ANDROID`, `ENV-DESKTOP-HOSTED` | `https://devfest-flutter-a59e8.web.app` | `2026-11-07` | **NOT RUN (`SS-006` Live Watch)** | Requires opting into `Watch my bowl` during an active camera session, observing periodic 15s checks (auto-pause after 3 minutes) (`watchId`), and confirming `Pause watch` or `Next step →` stops observations immediately (`SS-006`). |
| **LIVE-12** | Dinner-ready recipient & message review **without sending** (pre-authorization) and error handling | `ENV-DESKTOP-HOSTED`, `ENV-PHONE-ANDROID` | `https://devfest-flutter-a59e8.web.app` (`run 42428461526`) | `2026-11-07` | **FAIL / BLOCKED (`DEF-001` / `SS-030`, `DEF-002`, Send Authorization)** | `dinnerReady` is deployed and `ACTIVE` on Node 22 (`run 42428461526`) with `DINNER_CHANNEL=sms`, `DINNER_SERVICE_READY=true`, `ENABLE_DINNER_MESSAGES=false`, and hosted `405`/`401`/`204` boundary checks passing (`f046f2a`). Live sending remains blocked until explicitly authorized. On `main` (`e348527`), client error handling has **`DEF-001`** (fix underway in `SS-030` / #72 on `codex/dinner-validation` @ `a0c3aa4`) and **`DEF-002`**. |

---

## 4. Reproducible Defects & Runtime Findings for Terry (`@terryhh`)

Per `SS-023` acceptance criteria, Jenna reports these four reproducible failures and UX edge cases on `origin/main` (`e348527`) with exact file/line references and expected vs. actual behavior so Terry can resolve them in his runtime-owned files (`lib/learner/**`, `lib/data/**`, `lib/genui/**`). Machine-readable entries are also saved in [`docs/validation/cook-acceptance/reproducible-defects.json`](./cook-acceptance/reproducible-defects.json).

> **Resolved / Closed Findings:**
> - **Research Panel Mounting (`SS-005` / `SS-026`):** Resolved on `main` by PR #57 (`f079303`) and PR #61 (`75c5380` / `2bad9dd`), and verified on hosted Chrome (`198b2ab`).
> - **Dynamic Workspace Input / Stop Displacement (`SS-028`):** Resolved on `main` by PR #64 (`303a22e` / `da97bf9`) and PR #70 (`e348527` / `089ca74`), and verified on hosted desktop Chrome (`c5141d6`).
> - **Stale-Step Generated Workspace Guard (`SS-003`):** Resolved in code on `main` by PR #56 (`3e074e6` / `9f28b14`).
> - *(Removed per PR #68 review `#4504275050`):* The earlier unmeasured `DEF-005` (`CheckboxListTile` height) claim has been removed because `cookingTheme` sets `VisualDensity.standard`, under which Flutter's `ListTile` computes a dense single-line tile minimum height of `48dp`.

### `DEF-001` (High — Tracked in `SS-030` / #72) — Dinner review masks HTTP `403` / `400` pre-send validation rejections as ambiguous delivery status and locks the dialog
- **Related Cards:** `SS-007` (#17), `SS-023` (#41), `SS-030` (#72 — fix prepared on `codex/dinner-validation` @ `a0c3aa4`)
- **Owned Files (`@terryhh`):**
  - `lib/data/dinner_messages.dart` (lines `55–57` on `e348527`)
  - `lib/learner/cooking_app.dart` (lines `855–875` on `e348527`)
  - `functions/src/dinner-ready.js` (lines `8–12`, `14–27`, `193–199`)
- **Reproduction Steps:**
  1. Open the deployed app (`FAKE_BACKEND=false`) with `dinnerReady` deployed (`DINNER_SERVICE_READY=true`).
  2. Tap **Review dinner message** (`Icons.arrow_forward` in the bottom card).
  3. Enter a syntactically valid E.164 phone number that is **not** in `VONAGE_ALLOWED_TO` (e.g., `+14075559999`) and tap **Confirm and send**.
- **Expected Behavior:**
  - `POST /api/dinner-ready` returns HTTP `403` (`code: 'recipient-not-allowed'`) or HTTP `400` (`code: 'invalid-recipient'` / `'invalid-request'`) **before** claiming any `_dinnerNotifications` or `_dinnerMealClaims` document.
  - The UI should display a safe pre-send validation message (`No message was sent.`) and keep the `Recipient` / `Message` fields and `Confirm and send` button editable for an explicit retry, while keeping `409` / `5xx` / timeouts locked.
- **Actual Behavior (on `origin/main` @ `e348527`):**
  - `sendDinnerMessage` (`lib/data/dinner_messages.dart:55-57`) checks `if (response.statusCode != 200) throw StateError('Message request unavailable (${response.statusCode}).');`.
  - `_reviewDinner()` (`lib/learner/cooking_app.dart:866-871`) catches all exceptions identically and sets:
    `result = 'Message status could not be confirmed. No automatic resend will occur.'`
  - Setting `result != null` permanently disables the `Recipient` input, `Message` input, and `Confirm and send` button inside the open dialog (`enabled: !sending && result == null`). *(Note: Terry's `SS-030` branch `codex/dinner-validation` @ `a0c3aa4` introduces `DinnerValidationException` to fix this.)*

---

### `DEF-002` (Medium) — `_notificationId` is allocated once per `_CookingScreenState` lifetime, causing `409 idempotency-conflict` if message/recipient is edited after a claimed failure
- **Related Cards:** `SS-007` (#17), `SS-025` (#46)
- **Owned Files (`@terryhh`):**
  - `lib/learner/cooking_app.dart` (line `93` & lines `856–861` on `e348527`)
  - `functions/src/dinner-ready.js` (lines `37–57`)
- **Reproduction Steps:**
  1. In a live session, open **Review dinner message** and submit a request that claims the notification ID in `_dinnerNotifications` and settles as `status: "failed"` (e.g., `not-configured` or `invalid-sender`).
  2. Close the dialog, reopen **Review dinner message**, edit the `Message` text, and tap **Confirm and send**.
- **Expected Behavior:**
  - Re-submitting the exact same review attempt uses the same idempotency key, whereas starting a new distinct review after a non-pending deterministic failure (or in a new session) should not collide on a stale `_notificationId` with a different payload fingerprint.
- **Actual Behavior:**
  - `_CookingScreenState` declares `final _notificationId = const Uuid().v4();` once at widget initialization (`lib/learner/cooking_app.dart:93`). If an earlier attempt recorded `_dinnerNotifications/{sha256(uid + notificationId)}` and the cook later reopens the dialog and edits the message text, `functions/src/dinner-ready.js:53-55` sees a mismatched `fingerprint` for the same `notificationId` and throws HTTP `409 idempotency-conflict` (`"This notification ID already belongs to a different message."`).

---

### `DEF-003` (Medium) — Answering a cook clarification (`ask_cook` / `cookQuestion`) leaves the question panel and option buttons active until a replacement `show_cooking_ui` arrives
- **Related Cards:** `SS-003` (#13)
- **Owned Files (`@terryhh`):**
  - `lib/learner/cooking_coordinator.dart` (lines `199–219`, `467–476`, `562–566` on `e348527`)
  - `lib/genui/cooking_catalog.dart` (lines `118–169`)
- **Reproduction Steps:**
  1. Trigger a cook clarification either via the Live `ask_cook` tool call (which upserts component `id: 'question'` in `lib/learner/cooking_coordinator.dart:469-476`) or via `show_cooking_ui` containing a `cookQuestion` catalog item (`lib/genui/cooking_catalog.dart:118-169`).
  2. Submit an answer in the text box (`Your answer…`) **or** tap one of the `OutlinedButton` option chips in the `cookQuestion` panel while Live is disconnected or before the model responds with a replacement `show_cooking_ui` call.
  3. Tap the `cookQuestion` option button a second time before the workspace updates.
- **Expected Behavior:**
  - While an active Live session normally replaces the panel on the model's turn (as verified in `c5141d6` when `Smooth` was replaced by `"Got it: Smooth chickpeas"`), `confirmCookAnswer` should also locally disable or transition the answered `cookQuestion` / `'question'` panel immediately so rapid or offline taps cannot append duplicate confirmed facts before the model turn completes.
- **Actual Behavior:**
  - `confirmCookAnswer` (`lib/learner/cooking_coordinator.dart:199-219`) appends `$question Answer from cook: ${answer.trim()}` to `session.confirmedFacts` and sets `cookQuestion = null`, **but leaves the GenUI `'question'` / `cookQuestion` panel mounted and interactive** until a subsequent `show_cooking_ui` tool call arrives.

---

### `DEF-004` (Low) — Tapping `Research a cooking question` (`Icons.travel_explore`) in `_controlDock` with an empty input box only populates text without focusing or starting research
- **Related Cards:** `SS-026` (#58), `SS-028` (#63)
- **Owned Files (`@terryhh`):**
  - `lib/learner/cooking_app.dart` (lines `589–600` on `e348527`)
- **Reproduction Steps:**
  1. Open the cooking screen with the bottom `Ask the coach…` text field empty.
  2. Tap the **Research a cooking question** icon button (`Icons.travel_explore` in `_controlDock`, `lib/learner/cooking_app.dart:589-600`).
  3. Observe that no `CookingResearchPanel` opens on the first tap (it only sets `_message.text = 'Can I use vinegar instead of lemon in this recipe?'` without focusing the text field or calling `cook.researchQuestionNow`).
- **Expected Behavior:**
  - Either tapping **Research a cooking question** with an empty input focuses and selects the seeded question (with a brief hint/announcement so the cook knows to review/tap again), or submits/opens the research panel directly when the cook explicitly taps the research button.
- **Actual Behavior:**
  - The first tap silently assigns `_message.text` without moving focus or triggering `cook.researchQuestionNow`, requiring a second tap on `Icons.travel_explore` to open `CookingResearchPanel`.

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
3. Verify zero horizontal overflow across Header, `Smashed Chickpea Salad Wrap` title, full-width `CAMERA OFF` card, `Watch my bowl` control, `Your cooking space` (`1 / 4`), and sticky bottom `_controlDock` (`Start`, `Ask the coach…`, `Research a cooking question`).
4. Capture screenshot: `docs/validation/cook-acceptance/phone-01-cold-load-large-text.png`.

### Step 2 — Camera & Microphone Permission Deny → Allow Recovery
1. Tap **Start** (`Cook with me` tooltip in the sticky bottom dock) and **Deny** camera/microphone permission on the first prompt.
2. Verify the inline error notice appears (`Could not start live cooking. Check camera/microphone permissions and the Live service, then reconnect.`) and the button returns to **Start**.
3. Reset site permission to **Allow**, tap **Start** again, and verify:
   - Rear camera (`facingMode: environment`) frames appear in the 4:3 preview at ~1 fps.
   - Status pill updates from `CONNECTING` to `LISTENING & LOOKING` or `COACH SPEAKING`, and sticky dock button switches to **Stop** with a **Mute microphone** icon button.
   - Coach speaks an opening greeting at 24 kHz and `SOUSSIGHT` scrollable caption card (`maxHeight: 160`) updates per turn.
4. Capture screenshot: `docs/validation/cook-acceptance/phone-02-live-connected.png`.

### Step 3 — Two-Way Voice, Interruption, Mute, Hide/Background & Reconnect
1. Speak to the coach: *"I have the canned chickpeas, olive oil, and red onion, but I don't have a lemon."*
2. Verify distinct microphone speech recognition and workspace adaptation (`show_cooking_ui` with `stepId=prep`).
3. While the coach is speaking its reply (`COACH SPEAKING`), speak over the coach to interrupt and verify audio playback cuts off immediately and switches to `LISTENING & LOOKING`.
4. Tap **Mute microphone** in the bottom dock; verify badge changes to `CAMERA ON · MIC MUTED` while camera frames continue updating. Tap **Unmute microphone**.
5. Switch to another browser tab or lock the phone screen for 3 seconds, then return:
   - Verify camera/mic indicator turned off while hidden and inline error reads: `Camera paused because this tab is hidden. Return and reconnect.`
6. Tap **Start** to reconnect, then tap **Stop** and confirm media capture stops cleanly.

### Step 4 — Generated GenUI Panel, Sticky Input Stability, Cook Clarification & Grounded Research
1. Reconnect (**Start**), focus the `Ask the coach…` input so the phone keyboard opens, and verify the sticky bottom dock (`cooking-message-input` and `Stop` button) stays stationary above the keyboard while generated panels update above it (`SS-028`).
2. Check off available ingredients in `On your counter`, select a prediction chip (`Not yet`), point the camera at partially mashed chickpeas, and tap **Check my bowl**.
3. Verify the workspace updates to a generated GenUI comparison/step panel and that the coach describes visible texture cues without claiming internal temperature or food safety.
4. Answer any targeted clarification question from the coach and reload the page (`F5` / pull-to-refresh) to verify confirmed ingredients and confirmed facts persist in the session.
5. Type *"Can I use apple cider vinegar instead of lemon juice in this chickpea salad?"* and tap **Research a cooking question** (`Icons.travel_explore`).
6. Verify `CookingResearchPanel` renders the grounded answer, clickable HTTPS citation chips, Google Search suggestions attribution, targeted follow-up clarification input, and explicit substitution confirmation input (`Confirm & Save to Recipe`), and that confirming updates `session.confirmedFacts` and notifies Live (`SS-026`).
7. Capture screenshot: `docs/validation/cook-acceptance/phone-03-panel-and-research.png`.

### Step 5 — Real Countdown Timer & Opt-In Visible-Change Watch
1. Advance to Step 2 (`Quick-soak the red onion`) or tap **Start 5-minute timer** (and request a short 15-second demo timer via voice: *"Start a 15-second demo timer"*).
2. Reload the page while the timer is running and confirm the latest timer restores with its original wall-clock deadline.
3. When the 15-second timer reaches `0:00`, verify the `TIME TO CHECK` state, alert banner (`...: time is up. Check your food.`), and 880 Hz chime (when Live is active).
4. With Live active, tap **Watch my bowl**; verify the `WATCHING WITH YOU` panel appears, then tap **Pause watch** (or **Next step →**) and confirm the watch transitions to `WATCH PAUSED` and stops polling.
5. Capture screenshot: `docs/validation/cook-acceptance/phone-04-timer-and-watch.png`.

### Step 6 — Dinner-Ready Message Review (Pre-Authorization & Authorized Send)
1. Scroll to the bottom card (`Call everyone to the table`) and tap **Review dinner message** (`Icons.arrow_forward`).
2. Tap into the `Recipient` and `Message` fields on the phone so the soft keyboard opens; verify both inputs and the `Close` / `Confirm and send` buttons remain scrollable above the keyboard.
3. **While `ENABLE_DINNER_MESSAGES=false` (Dry-Run / Pre-Authorization on Deployed `dinnerReady`):**
   - Verify validation error on invalid phone format, then tap **Close** without sending, or verify dry-run with an allowlisted contact returns `Rehearsal only: no message was sent.` (`status: "skipped"`).
4. **Only after explicit send authorization is granted (`ENABLE_DINNER_MESSAGES=true` with `VONAGE_API_KEY`, `VONAGE_API_SECRET`, `VONAGE_FROM=Vonage APIs` for SMS trial, and `VONAGE_ALLOWED_TO` active):**
   - Start a fresh cooking session, enter the allowlisted household contact, review the exact message, and tap **Confirm and send** once.
   - Verify the UI displays: `Vonage accepted the message. Delivery is not yet confirmed.` (`status: "submitted"`), **never** claiming confirmed handset delivery from the API response alone.
5. Capture redacted screenshot (masking phone number): `docs/validation/cook-acceptance/phone-05-dinner-review-redacted.png`.
