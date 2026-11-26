# SousSight → #BuildHybridAI 2026: plan to win

> **Status:** revision 2, 2026-11-25, after a Codex (`gpt-6.2-astra`) review. Awaiting Terry's
> approval. No code has been changed yet.
> Contest: https://firebasehybridaihackathon.devpost.com/ (Official Rules on the Rules tab).

## Context

SousSight (3rd place, DevFest Florida, Nov 8) will be entered in Google's #BuildHybridAI 2026
hackathon. Hard deadline **Mon Nov 30, 2:00 pm PT / 5:00 pm EST**; later commits are not
evaluated, and the judged build must stay reachable free of charge through Dec 16.
Existing projects are eligible if significantly updated after Nov 11, with prior work disclosed.
`origin/main` was last touched Nov 10, so everything here is new work.

Goal is the **$10k Grand Prize**. Four equally weighted criteria: hybrid implementation, design,
impact, idea quality. Multi-platform apps get "strong consideration"; a submission can also take
one Best-of-platform prize.

Decisions made: target **Web + Android + iOS**; **free tier only**; parallel agents; stay in
this repo. License (AGPL → Apache-2.0) is open; see section 10.

Starting facts (verified against `origin/main` and installed SDKs):
- Every AI call today is cloud. No hybrid code exists.
- Flutter's `firebase_ai` has **no hybrid API**. Hybrid lives only in the official Web JS,
  Android (Kotlin) and Apple (Swift) SDKs.
- The Live coach bypasses AI Logic (`lib/learner/cooking_app.dart:147` always picks
  `EphemeralGeminiLiveTransport`), while the rules say "your app's AI runs on Firebase AI Logic".
- Media capture is web-only; `ios/`, `android/` are scaffolds; App Check is wired for web only;
  no iOS Firebase app; Android release builds use debug signing.
- This Mac has **no Flutter SDK, no Xcode, no Android SDK**.

## 1. The idea: "What happens at the counter stays at the counter"

Audience: food-pantry cooks with limited data plans, patchy kitchen Wi-Fi, and photos of their
home plus allergy details they'd rather not upload.

- **Private by default:** what the camera sees is processed on the device when the device can.
- **Free and resilient:** help keeps working after the Live cap and when the signal drops.
- **Cloud when it earns it:** live voice + vision coach, Google Search/Maps grounding, and what the local model can't do.

**Hero journey (the demo and the thing every track serves):** confirm pantry items → open a
recipe → start a **local watch** on the chickpea mash (frames stay on the device) → an obscured
bowl gets a targeted question instead of a guess → the connection drops → the cook asks about
the step and gets a generated panel on-device → a real timer runs → a clearly simulated
dinner-ready message. The source of each answer sits beside the result.

## 2. Day-one gates (run before the fan-out; go/no-go Fri Nov 27)

Each gate can remove a platform or the headline demo, so they come first. G6 and G1 run before
any live traffic. How to run each gate, and the technical design for every card, is in
[DESIGN.md](DESIGN.md).

| Gate | Pass bar | If it fails |
|---|---|---|
| **G1 Free cloud route** | For each cloud path (hybrid fallback, Live, Search/Maps grounding): the project, backend, model and quota are confirmed free in the console, and one real automatic cloud fallback succeeds. Real SMS confirmed disabled server-side. | That path stays out of the judged build. Stop and ask before anything bills. |
| **G2 Web hybrid slice** | One real task in the real app: on-device result in Chrome; then the **same task, same prefer-on-device config**, where the local model is genuinely unavailable, returns a cloud result with the SDK-reported source and App Check on the request. | Fix before anything else; this is the contest's defining behaviour. |
| **G3 Web Live through AI Logic** | Real app factory, **same Live model pinned on both paths**, enforcement on, production App Check: two spoken turns, a camera-driven reply, a generated panel. | Default: the judged web build ships without the direct-Gemini coach, and Live runs through AI Logic on native (see section 9). |
| **G4 Android** | Phone enrolled in AICore preview; Gradle resolves `firebase-ai` + `firebase-ai-ondevice` against BoM 35.1.0 at minSdk 26; the **signed release APK**, clean-installed, reports a **Gemini Nano 4** on-device result, an attested cloud fallback, and working camera/mic. | Android is not claimed. |
| **G5 iOS** | One build with `FirebaseAILogic` on the shared SPM graph (pin is exactly 13.1.1), OS availability guards (Runner targets iOS 15), iOS app registered, signing, App Check, real on-device source on the iPhone. | iOS is dropped from platform selection. |
| **G6 Eligibility** | Terry confirms who funded the DevFest prize and whether the $300 welcome credit / $10 Developer Program benefit in `docs/COST-LEDGER.md` were used; asks the hackathon manager if unclear. | Resolve with the organizer before building further. |

## 3. The bridge: Flutter → Firebase AI Logic hybrid

In-repo plugin `packages/ai_logic_hybrid/` (clearly labelled unofficial). One Dart API, three
backends, each calling the official Firebase AI Logic SDK for that platform:

| Platform | Backend | On-device model | Limits that drive routing |
|---|---|---|---|
| Web (Chrome desktop) | `dart:js_interop` → `firebase/ai` JS SDK 13.1.0, loaded at `firebase_core.SDK_VERSION` so it shares the app and App Check | Chrome built-in Gemini Nano | text + JPEG/PNG, JSON schema, ~9.2k tokens |
| Android | Kotlin channel → `firebase-ai` + `firebase-ai-ondevice` | Gemini Nano 4 (preview option) | text + 1 bitmap, JSON, 4k tokens, foreground only, battery quota |
| iOS | Swift (SPM) → `FirebaseAILogic` `HybridModel` | Apple Foundation Models | text only, 4k tokens |

Dart surface: `capabilities()`, `availability()`, `prepare()`, `generate()` →
`{text, source, modelLabel}`, plus a fake for tests and Rehearsal mode. Each local task gets its
own bounded schema and token budget (the existing 8,192-token + thinking config is cloud-only).
Native API names are re-verified against installed SDKs before coding.

## 4. Routing and privacy rules (`lib/ai/hybrid/inference_policy.dart`, table-tested)

| Feature | Route | Notes |
|---|---|---|
| Pantry scan: typed list / photo | prefer on-device (photo → cloud on iOS, with consent) | Photo and voice become **separate requests**, so a voice clip can't drag the photo to the cloud. |
| Pantry scan: voice clip | cloud | Audio isn't supported on-device. |
| Recipe draft | on-device first; one cloud retry on semantic rejection | No retry if the SDK already answered from cloud. |
| Local watch | on-device only | On "unsure": ask for a better view, or explicit consent to send that one frame. |
| Coach Lite | on-device; cloud if the panel fails validation and the cook is online | |
| Label check | on-device only by default | iOS: typed-label path. |
| Research, nearby food help, Live coach | cloud | Grounding and real-time audio/video. |

**Strict local-only wins over every retry, quota rule and Remote Config value.**

## 5. Features (each a card and a PR)

- **A. Hybrid pantry scan**: `PantryGenerator` seam in `lib/pantry/pantry_client.dart`; parser in `lib/pantry/pantry_models.dart`.
- **B. Recipe draft with a real quality gate**: `buildDraftRecipe` in `lib/pantry/recipe_draft_client.dart` gains a check that required ingredients are ones the cook confirmed; the retry is validated too.
- **C. Local watch (hero feature)**: its own camera-only mode that runs **without an active cloud video stream**. Today a watch requires Live (`cooking_coordinator.dart:391`) and Live uploads every frame (`live_controller.dart:153`), so the privacy claim is only made for this mode. Covers the model-initiated entry point too. Stop, step change or backgrounding cancels an in-flight verdict. Still opt-in; never certifies doneness or safety.
- **D. Coach Lite**: questions route through `CookingCoordinator` (today `say()` refuses when Live is off), with the same step guards; panels come from the trusted catalog; timers are started by the coordinator, not drawn; late answers after a step change are dropped.
- **E. Label check**: lists allergens a label mentions against locally stored household allergens; wording stays "the label mentions…, read it yourself".
- **F. Trust surface**: source beside every result; a ledger written **at dispatch**, covering every outbound AI transfer (hybrid, Live, research, nearby) including failed attempts, without storing content; plain statement of what the session saves to Firestore and what the Live coach is told.
- **G. First-run states**: no model yet, unsupported hardware, camera denied, no network — each gives a useful next step.
- **H. Offline, as scoped**: the supported offline state is defined and tested (prepared model, network cut, ask about the step, advance, run a timer, reconnect without lost or duplicate progress). Awaited Firestore writes and the transaction in `lib/data/firestore_repositories.dart` are made offline-tolerant, or the claim is limited to an already-open session.
- **I. Native runtime**: `NativeLiveMedia` for `LiveMedia`, native capture in both `cooking_app.dart` and `pantry_flow.dart`, permissions, iOS Firebase app, native App Check, release signing.
- **J. Live through AI Logic**: `lib/live/firebase_live_transport.dart` on native (and web if G3 passes). A server-side session reservation reusing `functions/src/token-quota.js` keeps the per-user and project limits that token minting enforces today.
- **K. Evidence**: human-scored test on the labelled photos in `assets/reference-cooking/` (expected observation, correct abstention on obscured frames, latency, frames uploaded) plus one filmed cook-through with the connection cut. Hardware, denominators and who the cook is are reported as they are.
- **L. Remote Config policy** and **M. device TTS**: lowest priority.
- **N. Reframe + audit**: remove DevFest/sponsor framing; inventory inherited features and media with licenses (third-party CC BY / CC BY-SA photos); keep required Search attribution; check repo, instructions and video for keys, PII and third-party branding. Firebase client config is documented as public identifiers with restrictions, not removed.

## 6. Submission and release

- Tag `origin/main` @ `430747b` as `pre-buildhybridai` and cut a release from it (disclosed baseline).
- `docs/buildhybridai/SUBMISSION.md` (value proposition, AI Logic use per platform, features, "Built during the submission period", prior-work disclosure, limits), `JUDGES.md`, `DEMO-SCRIPT.md` (≤3:00, the hero journey).
- **Frozen release identity:** final SHA + tag, deployed build, APK hash, device prerequisites, clean-install result; public route tested with no developer session or private token.
- **Judge access:** hosted web app is the primary entry point; APK only if G4 passes on a clean install; iOS by video + build instructions. A named owner keeps it up through Dec 16.

## 7. Execution with parallel agents

Worktrees under `.worktrees/` from `origin/main`. Stacked PRs, no force-push, cards via
`tool/publish_backlog.py`, moved to **In review**; Codex/Terry merge (merges auto-deploy).
One **integration owner** agent holds the shared files (`cooking_app.dart`, `pantry_flow.dart`,
manifests, `pubspec.lock`). CI gains a real (non-rehearsal) build and a deployed-candidate smoke
test beyond fetching `/`.

| When | Work |
|---|---|
| Wed–Thu Nov 25–26 | Toolchain; baseline tag; bridge contract + fake; gates G1–G6; web vertical slice |
| Fri Nov 27 | Platform go/no-go; features A–F in parallel on what passed |
| Sat Nov 28 | Complete cook-through on real devices; evidence (K); G/H/I polish |
| Sun Nov 29 | Release candidate; video; submission text |
| Mon Nov 30 | Freeze ~noon EST; submit by 3 pm EST |

If something slips, cut in this order: Remote Config, device TTS, label check, broad offline,
recipe retry, then iOS. The hero journey, the web slice and the evidence are never cut.

## 8. Verification

- **Automated (fakes, labelled):** `flutter analyze && flutter test` (policy table, local-only
  precedence, capability gating, ledger at dispatch, stale-verdict rejection); `node --test` for
  the JS bridge; Kotlin/Swift tests for channel mapping; functions/rules suites; real web build;
  Android and iOS builds compile.
- **Real, cannot be faked:** the gate pass bars above, on the named device. For the local watch,
  check WebSocket traffic as well as HTTP. Nothing is reported as live-tested unless it ran there.
- **Cost:** agents never call cloud models in tests; real cloud checks are few and counted;
  existing budget alerts stay; no real SMS.

## 9. Needs Terry

- **Now:** G6 eligibility facts; install Xcode; connect both phones; enroll the Android phone in
  the AICore Developer Preview; Firebase CLI login.
- **If G3 fails:** the default is that the judged web build ships without the direct-Gemini coach
  (Live stays on native through AI Logic; web gets Coach Lite). The direct connection breaks
  the "runs on Firebase AI Logic" rule, so it can only stay in a separate build that is not the entry.
- **Later:** real-device passes, the ≤3 min YouTube video, joining on Devpost, adding Jenna,
  platform selection, submitting.

I will reinstall Flutter 3.47.9 at `~/dev/flutter` and the Android command-line SDK.

## 10. Open decision: license

A ready-to-merge PR switching AGPL-3.0 → Apache-2.0 is prepared but **only merged on an explicit
yes from both Terry and Jenna**. Keeping AGPL remains fully within the rules.
