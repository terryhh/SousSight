<!--
  Devpost "About the project" copy for #BuildHybridAI 2026 (card SS-080, #167).
  Before pasting into Devpost:
  - Resolve every `VERIFY` comment. Each names the gate (DESIGN.md §8) or PR the claim depends on.
    If the gate passed, delete the comment. If it did not, delete or reword the claim it marks.
  - Replace <HOSTED_URL>, <YOUTUBE_URL> and <FINAL_TAG> with the frozen values (RELEASE.md).
  - Delete this comment. Devpost renders Markdown; HTML comments should not reach the form.
  Evidence as of 2026-11-26 (COMPLIANCE.md §3): G2b and the on-device half of G2c passed on
  Terry's desktop Chrome, from a local build. Nothing else has run on a device. The Pixel 9 is
  enrolled in the AICore preview and reports `nano-v4-full` available, but `generate` fails
  (ErrorCode 8), so G4 is blocked. The judged web build is `CLOUD_ROUTES=hybridFallback,research`,
  `LIVE_BACKEND=none`, `DINNER_MODE=simulated`: no Maps grounding and no Live coach.
-->

# SousSight: Counter Intelligence

*An AI sous-chef for pantry cooks. It watches your counter and coaches each step on your device, and calls the cloud only when it earns it. Hybrid AI with Firebase AI Logic.*

## Inspiration

SousSight started in Central Florida, with food pantries, community gardens and campus cooking demos. People leave with a bag of canned chickpeas, a loaf of bread and a garden tomato. Getting the food is half the job. The other half is knowing what to make and feeling confident making it.

Our first version (DevFest Florida 2026) answered that with a live voice-and-vision coach in the browser. It worked, and it taught us who we were really building for. Pantry cooks often have prepaid data plans, patchy kitchen Wi-Fi and a camera pointed at their own home. They tell the app who in the household has a peanut allergy. In that version, every one of those things went to the cloud, every time.

So for #BuildHybridAI we rebuilt SousSight around one rule: **what happens at the counter stays at the counter, unless the cook chooses the cloud.** The model on your device does the everyday AI work. The cloud is used for what only the cloud can do, and the app shows you, answer by answer, which one ran.

## Value proposition

- **Private by default.** Pantry scans, step help, the camera watch and label checks run on the device when the device can run them. The on-device watch keeps its frames on the device. It sends one frame to the cloud only if the cook asks and approves that exact frame. The Live coach is different, and labelled as cloud: once the cook taps **Start**, it streams the camera and microphone to Gemini Live until they stop it. <!-- VERIFY: gate G3. The judged build has LIVE_BACKEND=none, so it has no Live coach; if G3 does not pass, delete these two sentences -->
- **Free and resilient.** Help keeps coming when the signal drops or the data plan runs out, because the everyday features don't need a connection.
- **Cloud when it earns it.** Grounded research with sources uses Gemini in the cloud, and so does a fallback when the device can't do the job and the cook's settings allow it. Each cloud request is recorded in a ledger the cook can read. (Nearby food help and the live voice coach are built but off in the judged build.)
- **Honest about where it ran.** Every answer has a badge for each request it took: "On this device" or "Cloud · Gemini", as reported by the Firebase AI Logic SDK. The badge never just repeats the setting.

## What it does

The hero journey is a Smashed Chickpea Salad Wrap made from pantry staples.

1. **Scan what you have, on the device.** Type your items or show them to the camera. The on-device model lists what it sees, and only the items you tap count. <!-- VERIFY: gate G2c covered the typed scan; the photo scan on-device needs the multimodal flag and has not run in the production path --> A voice clip is sent as its own cloud request, because the local models don't take audio. It gets its own badge, so a voice note can't pull your photo into the cloud.
2. **Make a meal from exactly those items.** The recipe draft runs on the device first. Code checks that every required ingredient is one you confirmed: "milk" doesn't pass because you confirmed "coconut milk". If the local draft fails that check, SousSight retries once in the cloud, if your privacy settings allow it. <!-- VERIFY: gate G2 cloud fallback (#184 is merged) -->
3. **A private watch.** Prop the phone or laptop by the bowl and tap *Watch my food*. SousSight opens the camera only, with no microphone and no live cloud stream, and the on-device model compares each fresh frame to the step's visible cue: *ready*, *not yet* (more or less), or *unsure*. <!-- VERIFY: SS-075 evidence run and filmed cook-through; G2b covered the obscured frame in the gate harness only -->
   - When the bowl is blocked or blurred, it **asks for a better view** instead of guessing.
   - If you want a second opinion, *Ask the cloud about this photo* shows you the exact frame and sends it only after you tap **Allow once**. That approval covers that frame only.
   - It describes only what the camera can see. It never says food is done, hot enough, fresh or allergen-free.
   - In a build with the Live coach, if it is already on, *Watch my food* uses the Live coach's watch instead. That is cloud vision over the continuous Live stream, with no per-frame prompt, and the app says so when it starts.
4. **Coach Lite when the Live coach is off or the Wi-Fi drops.** Type a question about the step and the on-device model answers with a small generated panel: step cues and comparisons from a trusted Flutter GenUI catalog, validated before it renders. If it suggests a timer, the cook taps **Start timer**. The model can't start one on its own. <!-- VERIFY: SS-072 offline (#203) merged and an offline Coach Lite answer seen on the hosted build; otherwise drop "or the Wi-Fi drops" -->
5. **Label check.** Photograph an ingredient label. The on-device model lists the allergens the label mentions and compares them with the household allergens stored on this device. The wording is always "the label mentions…, read it yourself". An unreadable label never becomes "no allergens".
6. **The trust surface.** A source badge for each request, a session ledger of AI requests (**What was sent**: "Allowed to leave", "Reported as sent", "May have been sent", "Stayed on this device", plus what the session saves to Firestore), an *On-device AI* sheet with per-feature keep-on-device switches, and first-run states that explain what to do when there's no model yet, the hardware can't run one, the camera is blocked or the network is down.
7. **The cloud moment.** Substitution research grounded with Google Search, with sources and Search suggestions. It is a single cloud request, enabled because this build allows the research route, and written to the ledger. The code also has nearby food help grounded with Google Maps and the Gemini Live voice-and-vision coach through Firebase AI Logic, but the judged build leaves both routes off. <!-- VERIFY: gate G1 research route answered once on the hosted build under App Check. If gate G3 passes and the judged build turns Live on, add: "Live is a continuous camera and microphone stream that the cook starts and stops, and the ledger records each connect." -->
8. **Call everyone to the table.** The cook reviews a "dinner is ready" text before it goes. In the judged build this send is **simulated**: it goes to a fictional "Demo household", every status says "Simulated — no SMS sent.", and no SMS provider is contacted.

## How we built it

### Firebase AI Logic, one platform at a time

Flutter's `firebase_ai` package has no hybrid API. Hybrid inference exists only in the official Web (JavaScript), Android (Kotlin) and Apple (Swift) SDKs. So we wrote `packages/ai_logic_hybrid`, an **unofficial** in-repo Flutter plugin with one Dart contract and three backends. Each backend calls the official Firebase AI Logic SDK for its platform.

| Platform | Firebase AI Logic | On-device model | How the hybrid choice is made | Status |
|---|---|---|---|---|
| **Web** (desktop Chrome) | `firebase/ai` JS SDK 13.1.0, loaded at the same version FlutterFire uses so it shares the Firebase app and App Check. `getGenerativeModel(ai, { mode, inCloudParams, onDeviceParams })` with `InferenceMode` `prefer_on_device`, `only_on_device` or `only_in_cloud` | Chrome's built-in Gemini Nano (Prompt API) | By the SDK. The source shown is `response.inferenceSource` | On-device text, schema, system instruction and camera frames passed on desktop Chrome (G2b, G2c). <!-- VERIFY: gate G2 for the automatic cloud fallback --> |
| **Android** | `firebase-ai` 18.2.0 + `firebase-ai-ondevice` 16.0.0-beta08, `OnDeviceConfig` with `PREFER_ON_DEVICE`, `ONLY_ON_DEVICE` or `ONLY_IN_CLOUD` | Gemini Nano through AICore | By the SDK. The source is `response.inferenceSource`, and the observed model name comes from ML Kit's base model name | <!-- VERIFY: gate G4. #194 is merged. The enrolled Pixel 9 reports nano-v4-full available but generate fails (ErrorCode 8); do not claim Gemini Nano 4 or an on-device run --> Built and unit-tested; on-device run pending |
| **iOS** | Firebase Apple SDK 13.1.1: `GeminiLanguageModel` (`ai.geminiLanguageModel(name:)`) used inside Apple's `LanguageModelSession` | Apple Foundation Models (`SystemLanguageModel.default`), text only | By our bridge. Firebase iOS SDK 13 removed `HybridModel`, so the bridge uses the local session when the model is available and the request fits its 4,096-token budget, and the Gemini session otherwise. The source is the model the session was built with | <!-- VERIFY: gate G5 --> Built; on-device run pending |

On the web, the SDK does not pass `responseSchema` or `systemInstruction` to Chrome's local model. The bridge supplies them itself as `promptOptions.responseConstraint` and `createOptions.initialPrompts`, and caches one model instance per configuration so two tasks never share an instruction or schema.

### One sender, one policy

- **`HybridDispatcher` is the only code that sends a hybrid request**, including fallbacks and retries. Features say what they need; they never pick a mode.
- **A pure, table-tested routing policy** picks the mode. Highest priority first: the cook's keep-on-device setting, then whether this build allows the cloud route, then hard limits (audio, images on a text-only model, the token budget, language), then model availability, then the feature's default.
  - Keep-on-device, offline and an unapproved cloud route can only give `onlyOnDevice` or "can't run here". Nothing can loosen them.
  - Modes are never widened. If a backend reports a cloud source for an `onlyOnDevice` request, the result is recorded and discarded.
- **Consent is bound to one payload.** When a hybrid request's photo might leave the device, or the cook asks the cloud about a watch frame, the cook approves that exact payload (by SHA-256 digest) for this session, once. (The Live coach is a separate, labelled stream: starting it is the cook's consent for the whole session, and it has no per-frame prompt.) The dispatcher re-reads privacy settings, cloud routes and connectivity immediately before every send, including after the consent dialog closes.
- **The ledger is written at dispatch.** Each AI request is logged before it's sent, with the kinds of data it carries (never the content), whether it was allowed to leave, and what the SDK then reported. A request that was allowed to leave and then failed is shown as "may have been sent", never as "stayed". Live connects, grounded research and nearby lookups write to the same ledger. The ledger covers AI requests only. It also says, in plain words, that the cooking session itself (recipe, step, confirmed items and allergy answers) is saved to Firestore so the cook can pick it up again.
- **Stale answers are dropped.** Watch verdicts and Coach Lite panels carry the session, step and request they belong to. A late answer from an earlier step is thrown away.

### The rest of the stack

- **Flutter** for web, Android and iOS. **Flutter GenUI / A2UI** with a trusted widget catalog for generated panels. Coach Lite uses a smaller allowlist of display-only components.
- **Firebase:** Anonymous Auth, Firestore with owner-only rules, App Check (reCAPTCHA Enterprise on web; native release builds are wired for Play Integrity and App Attest <!-- VERIFY: gates G4, G5. Not registered in the console or run on a device; drop this clause unless a gate passes -->), Cloud Functions and Hosting.
- **Safety in code, not just in prompts:** doneness, temperature and allergen-certifying wording is rejected or replaced after generation.
- **Build guards in CI:** the judged web build is checked before and after compiling. It must use the simulated dinner mode, list only approved cloud routes, contain no App Check debug token and never include a direct Gemini endpoint. It publishes `/version.json` with its commit, so anyone can check that the hosted build matches the tag. <!-- VERIFY: the hosted /version.json shows the commit after the deploy -->
- **Agentic development:** coding agents worked in parallel on isolated branches with clear file ownership. A second model reviewed every pull request against a fixed checklist before a human merged it.

## Challenges we ran into

1. **No hybrid API in Flutter.** We had to bridge three native SDKs that disagree on modes, schemas, sources and limits, behind one contract with the same rules everywhere: never throw for a missing bridge, never widen a mode, and take the source from the SDK.
2. **Chrome's local model didn't get our instructions.** The JS SDK forwards the system instruction and JSON schema to the cloud model but not to Chrome's on-device model. We found the gap by reading the shipped SDK bundle and closed it in the bridge. On a real desktop Chrome (a local build), our gate harness then showed the on-device model following a system-instruction codeword and a schema whose enum excludes the natural answer (gate G2b).
3. **The private watch had to be rebuilt.** In the original app a watch needed the Live coach, and Live uploads every camera frame. We built a camera-only capture mode with no microphone and no audio pipeline, a single owner for the camera, a fresh-frame rule (under 2 seconds old) and cancellation on stop, step change, backgrounding and Live takeover.
4. **Proving the fallback without faking it.** A badge that repeats the setting proves nothing. Every result carries the SDK's own report of where it ran. The release checklist requires one run where the local model is genuinely unavailable and the same request comes back from the cloud through the hybrid SDK. <!-- VERIFY: gate G2 -->
5. **The docs didn't match the SDKs.** Firebase iOS SDK 13 removed `HybridModel`, so iOS hybrid moved into our bridge. On Android, on-device structured output needs compile-time `@Generable` classes, so the bridge adds the schema to the prompt and Dart validates the answer.

## Accomplishments that we're proud of

- A hybrid app on Firebase AI Logic built in Flutter, which has no hybrid API, with a policy that is the same on every platform.
- A camera watch that runs on the device, asks for a better view when it's unsure, and doesn't guess. <!-- VERIFY: SS-075 evidence -->
- A ledger that tells the cook which AI requests left the device, kept as each request is sent, not reconstructed afterwards, and honest about what the session saves.
- Privacy that holds at send time: one setting, read live, overrides every retry, fallback and remote value.
- Honest labels throughout: on-device vs. cloud, allowed vs. sent, AI-drafted vs. reviewed recipe, simulated vs. real message.

## What we learned

- **Hybrid is a product decision, not just an SDK flag.** `prefer_on_device` is the start. Which data may leave, who approves it, and how the cook finds out is the real design work.
- **Read the shipped SDK, then test on the device.** Two of our design assumptions were wrong in the installed SDKs. A small gate harness on real hardware caught them before features depended on them.
- **Small models need small jobs.** Bounded schemas, token budgets per task and validation in code let a 4,000-token on-device model do real work.
- **Asking beats guessing.** An "unsure" verdict that asks for a better view earns more trust than a confident wrong one.

## What's next for SousSight

- Android and iPhone builds that judges and pantry cooks can install, once each platform passes on a real device.
- A labelled evaluation set for the watch that grows with every recipe, with abstentions reported next to accuracy.
- Offline from a cold start, not just within an open cooking session.
- Field sessions with pantry partners to see which features cooks keep on-device and which cloud help they actually use.

## Built during the submission period (November 11–30, 2026)

Everything below was built after the baseline tag. Pull request numbers are in the public repository.

- **Unofficial Flutter bridge** `packages/ai_logic_hybrid`: contract and fake (#174), web backend over `firebase/ai` (#182), iOS backend on Foundation Models and FirebaseAILogic (#189), Android backend on `firebase-ai` + `firebase-ai-ondevice` (#194). These are built; device claims are only in the platform table above.
- **Dispatcher, routing policy, payload-bound consent and ledger**, plus the native method-channel backend (#186).
- **Hybrid pantry scan** with a separate voice request and a badge per request (#176).
- **Recipe draft quality gate**: required ingredients must be confirmed, with a hybrid drafter (#184).
- **Private camera watch**: camera-only capture, one camera owner, on-device verdicts, per-frame consent for a cloud check (#181).
- **Coach Lite**: on-device step help with validated GenUI panels and cook-started timers (#178).
- **Label check** for allergen statements (#188).
- **Trust surface**: source badges, ledger, On-device AI sheet and first-run states (#180).
- **Judge-safe simulated dinner message** (#175, #183).
- **CI guards** for the judged web build and `/version.json` (#187).
- **Native runtime**: camera, microphone and playback on Android and iOS, native App Check and release signing (#192), and the iOS Firebase app (#190). <!-- VERIFY: gates G4, G5 for "native App Check and release signing"; drop that phrase unless a gate passes --> 
- **End-to-end integration and the on-device gate harness** (#193).
- **Live coach through Firebase AI Logic** instead of a direct Gemini connection (#200). Built, but not in the judged web build (`LIVE_BACKEND=none`). <!-- VERIFY: gate G3. If it passes and the judged build turns Live on, replace the second sentence with the platforms where it ran -->
- **Offline cooking for an already-open session.** <!-- VERIFY: SS-072 (#203) merged; otherwise delete this bullet -->
- The plan, technical design, prior-work audit and the rewritten README (#170, #173, #177).

## Prior work

SousSight was first built for **DevFest Florida 2026** (November 7–10, 2026), where it placed **3rd**. That version is preserved at the tag [`pre-buildhybridai`](https://github.com/terryhh/SousSight/releases/tag/pre-buildhybridai), commit `430747b`, the last commit before the submission period opened. <!-- VERIFY: the tag is on origin at 430747b; confirm the GitHub Release page exists -->

Everything in that version ran in the cloud. It included the photo, voice and typed pantry scan with Gemini Flash; the AI recipe draft; three reviewed recipes; the Gemini Live voice-and-vision coach (over an ephemeral-token connection); the GenUI / A2UI cooking catalog; timers and Live-based visual watches; the allergy-first check; Google Search–grounded research; Google Maps–grounded nearby food help; the reviewed dinner-ready text through Vonage; Rehearsal mode; Firebase Auth, Firestore, web App Check and CI.

What's new is listed above. The core change is that inference now runs on the device first, through Firebase AI Logic's hybrid SDKs, with a policy, consent and a ledger around every request.

## Built with

Flutter · Dart · Firebase AI Logic (Web, Android and Apple SDKs) · Gemini Nano in Chrome · Gemini Nano on Android (AICore) · Apple Foundation Models · Gemini (cloud) · Flutter GenUI / A2UI · Grounding with Google Search · Firebase Authentication · Firebase App Check · Cloud Firestore · Cloud Functions for Firebase · Firebase Hosting · GitHub Actions <!-- VERIFY: drop "Gemini Nano on Android" unless gate G4 passed and "Apple Foundation Models" unless gate G5 passed -->

**Try it:** <HOSTED_URL> (desktop Chrome) <!-- VERIFY: final hosted URL --> · **Video:** <YOUTUBE_URL> · **Code:** https://github.com/terryhh/SousSight (AGPL-3.0) <!-- VERIFY: license at <FINAL_TAG> --> · **How to test:** [JUDGES.md](https://github.com/terryhh/SousSight/blob/main/docs/buildhybridai/JUDGES.md)
