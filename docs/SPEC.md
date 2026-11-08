# SousSight design specification

Updated November 8, 2026 for the DevFest Florida (Orlando) showcase. This document is the current product direction; earlier handoffs describe an older design.

## November 8 changes

- **Pantry-first start (SS-038).** The app opens on "What did you get from the pantry?" The cook scans with the camera, records a short voice clip, or types. One structured Gemini Flash call (Firebase AI Logic, multimodal input, JSON schema output) returns candidate items, ranked bundled meals with matched/missing ingredients, and at most one clarifying question. Items are candidates the cook confirms. Picking a meal opens the live cooking screen for that recipe. `?recipe=<id>` and `RECIPE_ID` skip the scan.
- **Recipes.** Peanut Butter Sandwich (default demo, untimed), Smashed Chickpea Salad Wrap (real 5-minute pickle timer, mash/mix visual checks), and Black Bean & Corn Salsa (produce-forward, real 5-minute meld timer, dice-size visual cue). Sessions are keyed by cook and recipe; "New cook" starts a fresh session without deleting history (SS-033).
- **Vonage lifecycle (SS-036/037).** Cook-reviewed "dinner's started" and "dinner is ready" SMS from server-side templates; a signed Messages API status webhook (`/api/vonage-status`) records submitted/delivered/read/rejected/undeliverable and mirrors it to an owner-readable `sessions/{id}/notifications/{nid}` doc the UI listens to. A labelled demo action simulates a failed delivery through the same handler. Failures show the reason and offer a new reviewed attempt; there are no automatic retries.
- **Live reliability (SS-035).** Validation errors go back to the model; duplicate cook answers are blocked; socket errors attempt resumption; low media resolution; replies in the cook's language.
- **Nearby food help (SS-041).** Grounding with Google Maps (Firebase AI Logic `Tool.googleMaps` with an opt-in `RetrievalConfig` location, or a typed city/ZIP) lists nearby food pantries and stores. It shows only places from Maps grounding metadata, with Maps links and attribution, never invented hours or eligibility, and doesn't store the location.
- **Allergy-aware start and How it works (SS-042).** When a recipe has allergens, the coach first asks once about allergies (`ask_cook`), then researches a substitution if needed. The header shows an allergen chip. An in-app "How it works" sheet lists the flow, technologies, privacy and safety boundaries.
- **Cost guardrails (SS-043).** Live session cap with a warning, idle stop, a 15 s watch cadence that expires, low media resolution, and per-user, daily and global Live token caps. Zero-cost simulated Vonage outcomes.
- **Meal-complete moment (SS-049).** Completing the final step stops the live coach (no further model call) and shows a recap built only from cook-confirmed facts, with reviewed dinner text, nearby help and cook-again actions.
- **AI-drafted recipes are the primary path (SS-053).** **Make a meal from these ingredients** leads the pantry results. Gemini Flash (structured output) creates a recipe from exactly the cook-confirmed items, which is validated into the app's `Recipe` model with an id starting `draft_`, 3–7 steps, visible cues, clamped timers and the major-nine allergens only. Safety rules are enforced in code: thermometer reminders for heated meat, poultry, fish, shellfish or egg, and a no-doneness-certification line on every heated step. Drafts are labelled **AI-drafted recipe · not reviewed** and the live coach is told so. Reviewed recipes are shown as alternatives.
- **Vonage verified end to end (SS-021).** A real SMS from the hosted app was received, and the signed status callback showed Delivered. Real sends go only to allowlisted numbers; simulated outcomes remain for repeat demos.
- **Browser support.** Chrome on desktop and Android. Firefox fails client-side for Firebase AI Logic calls (#109).
- **Removed (SS-034).** The instructor board, help-request routing, triage/assessment clients, seed data and their Firestore rules are gone. References to them below are historical.

## Product

SousSight is a live cooking companion. The cook shows ingredients and the bowl to the camera, talks through a recipe, and asks “am I doing this right?” Gemini uses sampled video and microphone audio to give short spoken guidance and compose useful Flutter panels as the task changes.

**The cook is the human in the loop.** When context is missing, the coach asks the cook a precise question. When an answer needs outside information, it performs a separate Google Search grounded request and presents returned sources. The cook confirms ingredients, substitutions, progress, and messages. There is no external instructor, board, help queue, or routing requirement in this submission.

Live vision, bidirectional audio, GenUI/A2UI panels, real timers, optional visual watches, and a reviewed dinner-ready message are core features. Keep those features central when making implementation tradeoffs.

## Community use

The intended audience is a novice cook turning affordable pantry ingredients into a meal, including Central Florida students and households. The first recipe uses canned chickpeas and prepared vegetables so the demonstration can focus on learning visual cues without a stove.

[UCF's FreshU cooking demonstrations](https://whps.sswb.ucf.edu/cooking-demos-classes/) and [UCF's account of helping students use pantry produce](https://www.ucf.edu/pegasus/how-does-your-garden-grow/) illustrate the local problem this project aims to help: receiving ingredients or a recipe does not necessarily provide confidence during preparation. These are community context, not partnerships or evidence that SousSight has been validated by UCF. Food waste reduction, cooking confidence, and successful substitutions are outcomes to measure, not established results.

## Demonstration

Use one staged Smashed Chickpea Salad Wrap session and make the mode visible.

1. **Show and confirm.** Connect the camera and microphone. Show the ingredients, confirm the checklist, and tell the coach what is missing. The coach asks a targeted question if an ingredient or quantity is uncertain.
2. **Check a visible technique.** Show partially mashed chickpeas, choose Ready / Not yet / Not sure, then ask for a check. The workspace changes to a comparison or step-cue panel. Mash again and show the changed bowl. The coach describes the visible cue rather than simply saying “good.”
3. **Create useful tools.** Ask for a short, explicitly labelled demonstration timer and watch for an evenly mixed bowl. The countdown runs on the client. A watch requests new visual observations and alerts the cook when it looks ready for their check.
4. **Research a missing ingredient.** Ask whether the available vinegar can replace lemon in this recipe. Show the source-backed answer and any cook clarification. A suggested substitute does not automatically become a confirmed ingredient.
5. **Call everyone to the table.** Open the dinner-ready draft, review the configured household recipient and exact message, and explicitly confirm. With messaging disabled, demonstrate the clearly labelled rehearsal result. With a configured Vonage account, show provider acceptance accurately as delivery unconfirmed.

The five-minute onion timer remains a genuine five-minute recipe timer. Do not shorten it silently or present an edited countdown as proof of cooking readiness. Use an explicitly requested short timer when demonstrating expiration within three minutes.

## Current implementation and limits

| Capability | Implementation / current limit |
|---|---|
| Recipe | One bundled `chickpea_wrap_v1` recipe, four steps. General recipe import is outside the current build. |
| Live vision and voice | Browser camera frames, microphone PCM, streamed spoken responses, transcription, and tool calls. Real hardware and deployed model connectivity still need a smoke test. |
| Dynamic workspace | GenUI 0.10.4 renders validated A2UI components from a cooking catalog. The model chooses composition and content; it does not generate executable Dart or arbitrary HTML. |
| Check my bowl | Active cook flow asks Live to compare the latest frame with the current recipe cue. It is not a measured vision accuracy benchmark. |
| Cook questions | `ask_cook` presents a specific missing fact; explicit answers are saved as cook-confirmed context. |
| Research | Separate Gemini 3.8 Flash request with Google Search. Sources come from provider grounding metadata; the real client rejects answers without usable sources. |
| Timers | Absolute deadlines drive countdowns. Multiple timers can run in memory; only the latest timer ID, label, and deadline are saved in the cooking session for reload. |
| Watch | Opt-in visual goal, fresh-frame checks, periodic model prompts, and watch IDs to reject stale results. It pauses when the session ends or the tab becomes hidden. |
| Dinner notification | Cook-reviewed request to an authenticated backend; Vonage sending is disabled by default. Provider acceptance is not confirmed delivery. |
| Rehearsal | `FAKE_BACKEND=true` uses simulated AI and in-memory services. It does not capture camera/audio, run a real watch, search Google, or send a message. |
| Reference assets | Existing target JPEGs are small placeholders. Recipe fixture fields saying `Recipe reviewer` are not evidence of a real human review. |

The earlier still-image assessment, triage, help-request and routing code was removed (SS-034); the cook UI uses the Live flow above. Do not describe placeholder photos or seeded reviewer names as demonstrated product functionality. Replace reference assets and establish a documented recipe review before claiming reviewed visual targets.

## Architecture

One Flutter web application serves the cooking experience. `lib/main.dart` forwards to `lib/main_learner.dart`; the build script compiles that cook entrypoint into `build/web`. Firebase Hosting serves that directory over HTTPS. Historical board entrypoints are not built or deployed by the current script.

```text
lib/app/       application services and dependency injection
lib/core/      recipe/session models, research contract, fakes
lib/data/      Firebase Auth, Firestore, App Check, API clients
lib/ai/        grounded research plus existing structured-model clients
lib/live/      browser media, Live transport, tools, lifecycle and watch control
lib/genui/     trusted cooking catalog, validated surfaces, timers
lib/learner/   cooking screen, coordinator, labelled rehearsal transport
lib/research/  sister's AGY research/substitution experience (separate task)
functions/    protected Live-token and dinner-ready endpoints
tool/         local build tooling
```

The data and UI layers use injectable interfaces so rehearsal and tests do not require credentials. No model response is allowed to directly submit a dinner notification or silently mark a step complete.

### Live transport

For web, the app calls `POST /api/live-token` with a Firebase ID token and App Check token. The backend verifies both, applies a per-user attempt limit, and mints a short-lived Gemini token using a server-side `GEMINI_API_KEY` secret. The response supplies the model and API version; the browser does not embed a long-lived Gemini key.

The current backend contract selects `gemini-3.8-live` and `v1beta`. The token is single-use for starting a session, with a 60-second new-session window and 30-minute expiry. The browser connects to the constrained Live WebSocket endpoint with `access_token`, supplies the cooking context and function schemas, and requests audio plus transcription. The current [ephemeral-token guide](https://ai.google.dev/gemini-api/docs/live-api/ephemeral-tokens) and [Google's Live migration guide](https://github.com/google-gemini/gemini-skills/blob/main/skills/gemini-live-api-dev/references/migration.md) are the model/protocol references. Older examples still mention v1alpha; verify the actual deployed connection rather than treating compilation as proof.

The Firebase AI Logic 5.1 browser Live implementation does not attach App Check headers to its WebSocket. The [tracked Firebase issue](https://github.com/firebase/firebase-js-sdk/issues/10018) explains why the browser uses the protected ephemeral-token route. `FirebaseLiveTransport` remains a separate adapter for SDK-supported clients, with its separately configured model. Standard grounded research uses Firebase AI Logic's HTTPS path.

Browser media behavior:

- One JPEG frame per second, maximum dimension 768 pixels; the UI preview shows the latest sampled frame.
- Mono PCM16 little-endian microphone input at 16 kHz, including resampling from the browser's capture rate.
- Queued PCM16 speech playback at 24 kHz; interruption clears queued speech.
- User gesture starts camera/audio. Mute gates the microphone while camera frames continue. Stop, page hide, permission failure, or disconnected capture tracks clean up capture resources.
- The receiver remains active after `turnComplete`. Session resumption is attempted when a valid handle is available. Text and tool acknowledgements wait through a brief reconnection; stale camera/audio packets may be dropped.
- No promise of sub-300ms latency, arbitrary full-motion video, exact spatial measurements, or unattended background monitoring.

### Live tools and GenUI

Live tool calls are schema checked before reaching application state. Tool IDs prevent a duplicate model call from running the same action twice. The GenUI layer validates component names, IDs, fields, actions, and tree structure before rendering.

| Tool | Host behavior |
|---|---|
| `show_cooking_ui` | Validate the `uiJson` component tree and update the cooking workspace. |
| `start_timer` | Start a host-owned timer using ID, label, and 1–7200 seconds; persist the latest timer deadline. |
| `watch_cooking` | Start the requested visible goal and return a new `watchId`. |
| `report_readiness` | Require that exact active `watchId` and a fresh frame; show watching / uncertain / looks-ready-for-your-check. |
| `ask_cook` | Present the missing question and reason; the cook supplies the answer. |
| `research_cooking` | Run the separate grounded research client and return its answer and sources. |
| `check_now` | Invite the cook to make a prediction and request a deliberate visual check. |
| `next_step` | Suggest progression; the cook confirms using the step action. |
| `dinner_ready` | Open an editable message draft. Sending requires a separate explicit action. |

The catalog contains cooking layouts and panels such as ingredient checklists, step cues, comparisons, cook questions, watch status, timers, and dinner-ready drafts. A stable timer keeps its actual deadline even when the model replaces surrounding UI. The catalog, not arbitrary model output, owns available actions.

### Watch semantics

Watch mode concerns an observable technique cue: coarse chickpea texture, dressing spread evenly, or a similar visible change. Every watch receives a new ID. The application asks for a fresh observation about every eight seconds while the connection is listening and the camera frame is fresh. Reports for a stopped, replaced, or previous-step watch are rejected, including cached duplicate tool results. A slow result cannot stop a newer watch.

The first accepted ready report produces “Looks ready for your check” and a visible alert. The screen can chime while live audio playback is active. Timers likewise show expiration and can chime during an active live session. Background browser execution, a closed tab, or an inactive audio context is not a reliable alarm service.

Appearance, elapsed time, and food safety are distinct. An image cannot establish internal temperature, allergen absence, freshness, or safe storage. The coach asks the cook for relevant facts and can research authoritative guidance; it must not certify that food is safe from the camera.

### Research and confirmation

The separate `CookingResearchClient` accepts a question, the current step, and confirmed ingredients. The real implementation uses `FirebaseAI.googleAI()`, `gemini-3.8-flash`, and `Tool.googleSearch()` in a dedicated HTTPS call. It keeps search separate from the Live custom-function setup to avoid unsupported tool combinations.

Citations are HTTPS links taken from grounding metadata, never extracted from model-authored prose. Google-provided search suggestions are preserved in an isolated renderer. Failure, timeout, and a missing usable source are explicit states. The cook may clarify context or retry; late results must not overwrite a newer question.

The sister's [AGY task](handoffs/AGY-COOKING-RESEARCH.md) adds a focused research panel, clarification flow, and editable substitution confirmation through the provider-independent contract. It must not silently change the recipe or claim that a substitution has been reviewed by someone else.

## Persistence and privacy boundaries

Anonymous Firebase Auth identifies the cook. Firestore sessions are owner-scoped and contain the current recipe step, completed steps, confirmed ingredient states and facts, revision, and the latest timer metadata. Confirmed mutations increment `revision` and update the timestamp. The bundled recipe remains available when a remote recipe is absent; deployed access and offline behavior still need verification.

Live image/audio streams go to Gemini during the active connection. The browser bridge does not write continuous recordings to Firestore. Current transcripts are held in memory for the display. Existing checkpoint model/storage support is separate from continuous media capture.

Backend-only Firestore collections hold token quotas and dinner-message idempotency records. Clients must not be able to read or write those ledgers. No long-lived Gemini or Vonage secret belongs in Flutter source, Dart defines, or web assets.

## Dinner-ready messaging

`POST /api/dinner-ready` receives the session ID, a stable notification ID, the cook-approved recipient, and the exact approved message. It verifies Firebase Auth, App Check, and session ownership, and checks the configured recipient allowlist before any provider request.

The backend defaults to `ENABLE_DINNER_MESSAGES=false`. WhatsApp uses the Vonage Messages Sandbox; SMS uses the production Messages API with the appropriate sender/account setup. Keep channel and account details in [functions/README.md](../functions/README.md), including secret names, sandbox enrollment, and rate limits.

A transaction claims the notification before contacting Vonage. A second ID cannot bypass an existing announcement for the same meal and recipient. Pending or ambiguous outcomes are not automatically retried. The UI distinguishes rehearsal, provider rejection, uncertain status, and provider acceptance with delivery unconfirmed. Delivery callbacks are not implemented in this build, so do not display a delivered receipt.

## Build and release shape

The application artifact is `build/web`, produced by `tool/build_web.sh`. Hosting needs rewrites for `/api/live-token` and `/api/dinner-ready` before the single-page-app fallback. The token and dinner functions run in `us-central1`. Keep runtime secrets in Secret Manager and service settings on the backend; the web build only receives public configuration and development-only App Check settings.

Continue the existing stack with small reviewable commits. The foundation and data layers remain the base, followed by structured AI, live cooking, dynamic UI, the cook application, protected backend functions, and integration checks. Historical board branches are not the current product plan. The AGY research task has separate file ownership and joins the stack through its draft PR.

## Acceptance and remaining validation

Before calling the submission demo ready:

- Run static analysis, focused Dart tests, browser media tests, backend tests, and the web build for the integrated cook entrypoint. Report sandbox or environment blocks separately from passing tests.
- Exercise the actual hosted app on a phone: permissions, camera framing, two or more spoken turns, interruption, mute, disconnect, hide/resume, and a generated interactive panel.
- Verify the deployed token endpoint, App Check, anonymous Auth, Gemini 3.8 Live setup, Google Search grounding, Firestore rules, and session resume with real services.
- Check a timer across panel replacement and reload. Verify the latest timer restores, and state plainly that other in-memory timers do not yet restore.
- Switch or stop a watch before an old observation returns; confirm it cannot update the new step. Never show a rehearsal watch as an actual observation.
- Review the recipe and replace placeholder target images before making any reviewed-target claim. Record what was actually tested rather than inventing accuracy metrics.
- Test dinner messaging with an explicitly approved recipient and text. Verify duplicate/ambiguous requests do not resend, and label submission versus delivery accurately.
- Check phone and desktop layouts, readable transcripts, keyboard operation, and visible errors.

Production services, real camera/audio behavior, verified recipe review, and end-to-end provider delivery have not been established by the current local build. Keep those as explicit release checks, not implied completed work.
