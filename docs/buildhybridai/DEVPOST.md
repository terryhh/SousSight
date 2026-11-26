<!--
  Devpost project story for #BuildHybridAI 2026 (card SS-108, #238), in Devpost's own section order.
  Terry pastes the final text into Devpost (#141 / #168).

  Before pasting:
  - Resolve every `VERIFY` comment the way RELEASE.md and COMPLIANCE.md §3 say. Each names the gate
    (DESIGN.md §8), card or PR the claim depends on. If it passed, delete the comment. If it did not,
    delete or reword the claim it marks, as the comment says.
  - Keep this file and SUBMISSION.md in step: the claims here mirror SUBMISSION.md at `57209d1`.
    When a gate result changes one, change the other.
  - Replace <HOSTED_URL>, <YOUTUBE_URL> and <FINAL_TAG> with the frozen values (RELEASE.md).
  - Delete every HTML comment, this one included. Devpost renders Markdown; comments must not reach the form.

  Evidence as of 2026-11-26, from the gate cards (#142–#147) and COMPLIANCE.md §3:
  - Desktop Chrome (Terry's, local build, never deployed): G2b partly passed (text, schema, system
    instruction and an obscured frame answered on-device in the gate harness; the camera-frame probe
    has not run). G2c's on-device half passed (typed pantry scan, badge "On this device").
  - Cloud half (automation Chrome with no local model, local build, live Firebase AI Logic under App
    Check): the harness `preferOnDevice` request came back with SDK source `cloud`; the production
    typed pantry scan showed "Cloud · Gemini"; grounded research answered with sources. Nothing has
    run on the hosted build yet.
  - Android (G4, #145): Pixel 9 enrolled in the AICore preview reports `nano-v4-full` available, but
    `generate` fails (ErrorCode 8). Jenna's Pixel 10 Pro XL reported `nano-v4-full` available after
    enrolling: availability only, debug build, no generate call. G4 is not passed.
  - iOS (G5): not run. Live (G3): not run, and the judged build has no Live coach.
  - SS-075 watch accuracy and latency: not measured yet. Do not add numbers.
  - The judged web build is `CLOUD_ROUTES=hybridFallback,research`, `LIVE_BACKEND=none`,
    `DINNER_MODE=simulated`.
  - `origin/main` at `57209d1` does not yet include #201, #203 (offline), #210 or #212 from the trunk.
-->

# SousSight: Counter Intelligence

*An AI sous-chef for pantry cooks. It coaches each step on your device and calls the cloud only when it earns it. Hybrid AI with Firebase AI Logic.*

## Inspiration

SousSight started with food pantries, community gardens and campus cooking demos in Central Florida. People go home with a can of chickpeas, a loaf of bread and a garden tomato. Getting the food is half of dinner. The other half is knowing what to make and feeling confident making it.

The people we build for often cook on a prepaid data plan, over patchy kitchen Wi-Fi, with a camera pointed at their own home. They tell the app who in the household has a peanut allergy. Our first version sent all of that to the cloud, every time, because that was the only place the AI ran.

So for #BuildHybridAI we rebuilt SousSight around one rule: **what happens at the counter stays at the counter, unless the cook chooses the cloud.** The model on the device does the everyday work. The cloud is used for what only the cloud can do, and the app shows, request by request, which one ran.

**Prior work.** SousSight was first built for DevFest Florida 2026 (November 7–10, 2026), where it placed 3rd. That version is preserved at the tag [`pre-buildhybridai`](https://github.com/terryhh/SousSight/releases/tag/pre-buildhybridai) (commit `430747b`), the last commit before the submission period opened. <!-- VERIFY: the tag is on origin at 430747b; confirm the GitHub Release page exists --> Every AI feature in that version ran in the cloud: the photo, voice and typed pantry scan, the AI recipe draft, the Gemini Live voice-and-vision coach, Live-based visual watches, Search- and Maps-grounded help and the reviewed dinner-ready text. Everything about running on the device first, described below, was built between November 11 and 30, 2026.

## What it does

The hero journey is a Smashed Chickpea Salad Wrap made from pantry staples.

1. **Scan what you have.** Type your items, or show them to the camera. The on-device model lists what it sees, and only the items you tap count. <!-- VERIFY: gate G2c covered the typed scan; the on-device photo scan needs the multimodal flag and has not run in the production path. If it doesn't run before the freeze, say "Type your items" only --> A voice note is its own cloud request with its own badge, because the local models don't take audio, so a voice note can't pull your photo into the cloud.
2. **Make a meal from exactly those items.** The recipe draft runs on the device first. Code checks that every required ingredient is one you confirmed: "milk" doesn't pass because you confirmed "coconut milk". If the local draft fails the check, SousSight retries once in the cloud, if your settings allow it. <!-- VERIFY: gate G2 cloud fallback; the recipe retry itself has not run. Drop the retry sentence unless it runs on the hosted build -->
3. **A private watch.** Prop the laptop by the bowl and tap **Watch my food**. SousSight opens the camera only, with no microphone and no live cloud stream. The on-device model compares each fresh frame with the step's visible cue and answers *ready*, *not yet* or *unsure*. <!-- VERIFY: SS-075 evidence and a hosted take; G2b covered the obscured frame in the gate harness only -->
   - When the bowl is blocked or blurred, it **asks for a better view** instead of guessing.
   - For a second opinion, **Ask the cloud about this photo** shows you the exact frame and sends it only after you tap **Allow once**. That approval covers that one frame.
   - It describes only what the camera can see. It never says food is done, hot enough, fresh or free of allergens. The cook decides.
4. **Coach Lite.** Type a question about the step, such as "How smooth should the mash be?", and the on-device model answers with a small panel of step cues built from a trusted Flutter GenUI catalog and validated before it renders. It keeps answering when the Wi-Fi drops. <!-- VERIFY: no Coach Lite answer has been seen on a device yet; see one on the hosted build. SS-072 (#203) is on the trunk but not on main. Keep "It keeps answering when the Wi-Fi drops" only if #203 reaches the judged build and an offline Coach Lite answer is seen on the hosted build --> If it suggests a timer, you tap **Start timer**. The model can't start one by itself.
5. **Label check.** Photograph an ingredient label. The on-device model lists the allergens the label mentions and compares them with the household allergens stored on this device. The answer starts "The label mentions: …" and ends "Read the label yourself before serving." An unreadable label never becomes "no allergens": the app says it couldn't read an allergen statement, that this doesn't mean there are none, and to read the label yourself. <!-- VERIFY: #188 has run on fakes only; see one on-device label check on the hosted build, or describe it as built -->
6. **The trust surface.** Every answer carries a badge for each request it took, **On this device** or **Cloud · Gemini**, taken from what the Firebase AI Logic SDK reported, never from the setting. The **What was sent** ledger separates *Allowed to leave*, *Reported as sent*, *May have been sent* and *Stayed on this device*, and says plainly what the cooking session saves to Firestore. An **On-device AI** sheet has a keep-on-device switch for each feature, and first-run states explain what to do when there's no model yet, the hardware can't run one, the camera is blocked or the network is down. <!-- VERIFY: the first-run states are covered by tests on fakes only; check the no-model state on the hosted build in a clean Chrome profile -->
7. **One cloud moment.** Ask a substitution question ("Can I use Greek yogurt instead of mayo?") and it goes to Gemini in the cloud, grounded with Google Search, with sources and Search suggestions. The badge says Cloud and the ledger gets one new row. <!-- VERIFY: gate G1 research route answered once on the hosted build under App Check (it has answered from a local build, #143) --> The code also has Maps-grounded nearby food help and the Gemini Live coach through Firebase AI Logic, but the judged build leaves both off. <!-- VERIFY: gate G3. If it passes and the judged build turns Live on, add: "Live is a continuous camera and microphone stream that the cook starts and stops, and the ledger records each connect." -->
8. **Call everyone to the table.** You review a "dinner is ready" text before it goes. In the judged build this is **simulated**: it goes to a fictional "Demo household", every status reads "Simulated — no SMS sent.", and no SMS provider is contacted.

## How we built it

### One Flutter app, three Firebase AI Logic SDKs

Flutter's `firebase_ai` package has no hybrid API. Hybrid inference exists only in Firebase AI Logic's Web (JavaScript), Android (Kotlin) and Apple (Swift) SDKs. So we wrote `packages/ai_logic_hybrid`, an **unofficial** in-repo Flutter plugin: one Dart contract with three backends, each calling the official SDK for its platform.

| Platform | Firebase AI Logic | On-device model | Who picks local or cloud | Where it stands |
|---|---|---|---|---|
| **Web** (desktop Chrome) | `firebase/ai` JS SDK 13.1.0, loaded at the version FlutterFire uses so it shares the Firebase app and App Check. `InferenceMode` `prefer_on_device`, `only_on_device` or `only_in_cloud` | Chrome's built-in Gemini Nano | The SDK. The badge shows `response.inferenceSource` | On-device text, JSON schema, system instruction and an obscured frame answered on Terry's desktop Chrome, from a local build, in our gate harness. A typed pantry scan showed **On this device** in the app. With no local model, the same `prefer_on_device` request came back from the cloud with the SDK reporting `cloud`. <!-- VERIFY: gate G2 on the hosted build; until then, say "from a local build" as here --> |
| **Android** | `firebase-ai` 18.2.0 + `firebase-ai-ondevice` 16.0.0-beta08, `PREFER_ON_DEVICE`, `ONLY_ON_DEVICE` or `ONLY_IN_CLOUD` | Gemini Nano through AICore | The SDK. The source is `response.inferenceSource` | Built and unit-tested on fakes. On a physical phone, only availability has been checked; no on-device answer yet. <!-- VERIFY: gate G4. Do not claim an on-device run or Gemini Nano 4 unless G4 passes --> |
| **iOS** | Firebase Apple SDK 13.1.1: `GeminiLanguageModel` inside Apple's `LanguageModelSession` | Apple Foundation Models, text only | Our bridge, because Firebase iOS SDK 13 removed `HybridModel`. It uses the local session when the model is available and the request fits its 4,096-token budget, and the Gemini session otherwise | Built; not yet run on a device. <!-- VERIFY: gate G5 --> |

### The routing policy

- **One sender.** `HybridDispatcher` is the only code that sends a hybrid request, fallbacks and retries included. Features say what they need; they never pick a mode.
- **One pure, table-tested policy.** It picks the mode, highest priority first: the cook's keep-on-device switch, then whether this build allows the cloud route, then hard limits (audio, images on a text-only model, the token budget, language), then model availability, then the feature's default.
- **Nothing loosens privacy.** Keep-on-device, offline and an unapproved route can only produce `onlyOnDevice` or "can't run here". A mode is never widened: if a backend reports a cloud source for an `onlyOnDevice` request, the result is recorded and thrown away.
- **Checked at send time.** The dispatcher re-reads the privacy settings, allowed cloud routes and connectivity immediately before every send, including after a consent dialog closes.
- **Consent is for one payload.** When a photo might leave the device, the cook approves that exact payload, by SHA-256 digest, once, for this session.
- **Stale answers are dropped.** Watch verdicts and Coach Lite panels carry the session, step and request they belong to; a late answer from an earlier step is discarded.

### The trust ledger

Each AI request is written to the ledger **before** it's sent, with the kinds of data it carries (text, image, audio, location, never the content), whether it was allowed to leave, and then what the SDK reported. A request that was allowed to leave and then failed shows as *May have been sent*, never as *Stayed on this device*. Grounded research, Live connects and nearby lookups write to the same ledger. The ledger covers AI requests only, and it says so: the cooking session itself (recipe, step, confirmed items and allergy answers) is saved to Firestore so the cook can pick it up after a reload.

### The rest of the stack

- **Flutter** for web, Android and iOS, with **Flutter GenUI / A2UI** and a trusted widget catalog for generated panels.
- **Firebase:** Anonymous Auth, Firestore with owner-only rules, App Check (reCAPTCHA Enterprise on the web), Cloud Functions and Hosting.
- **Safety in code, not only in prompts:** doneness, temperature and allergen-certifying wording is rejected or replaced after generation.
- **Build guards in CI:** the judged web build must use the simulated dinner mode, list only approved cloud routes, carry no App Check debug token and contain no direct Gemini endpoint. It publishes `/version.json` with its commit, so anyone can check the hosted build against the tag. <!-- VERIFY: the hosted /version.json shows the commit after the deploy -->
- **How we worked:** coding agents built cards in parallel on isolated branches with clear file ownership, a second model reviewed every pull request against a fixed checklist, and a person merged.

### Built during the submission period (November 11–30, 2026)

Pull request numbers are in the public repository.

- The bridge: Dart contract and fake (#174), web backend (#182), iOS backend (#189), Android backend (#194).
- Dispatcher, routing policy, payload-bound consent, ledger and the native channel backend (#186).
- Hybrid pantry scan with a separate voice request (#176); recipe draft quality gate (#184).
- Private camera watch (#181), Coach Lite (#178), label check (#188).
- Trust surface and first-run states (#180); simulated dinner message (#175, #183); CI guards and `/version.json` (#187).
- Native runtime for Android and iOS (#192), the iOS Firebase app (#190), end-to-end integration and the on-device gate harness (#193).
- The Live coach moved from a direct Gemini connection to Firebase AI Logic (#200). It's built, but not in the judged web build. <!-- VERIFY: gate G3. If it passes and the judged build turns Live on, replace the second sentence with the platforms where it ran -->
- Offline cooking for an already-open session. <!-- VERIFY: SS-072 (#203) is merged into the trunk, not main. Delete this bullet unless it reaches the judged build -->

## Challenges we ran into

1. **No hybrid API in Flutter.** We bridged three native SDKs that disagree on modes, schemas, sources and limits, behind one contract with the same rules everywhere: never throw for a missing bridge, never widen a mode, and take the source from the SDK.
2. **Chrome's local model wasn't getting our instructions.** The web SDK forwards the system instruction and JSON schema to the cloud model, but not to Chrome's on-device model. We found the gap by reading the shipped SDK bundle and closed it in the bridge (`initialPrompts` and `responseConstraint`). On Terry's desktop Chrome, from a local build, the gate harness then showed the local model following a system-instruction codeword and a schema whose enum leaves out the natural answer.
3. **Firebase iOS SDK 13 removed `HybridModel`.** The iOS docs we planned from no longer matched the SDK. Hybrid on iOS moved into our bridge, which chooses between Apple's on-device session and a Gemini session itself.
4. **Android hardware is a moving target.** Google's documentation lists the Pixel 9 as a Gemini Nano 3 device. Enrolled in the AICore Developer Preview, Terry's Pixel 9 reports the Gemini Nano 4 Full model (`nano-v4-full`) as available, but every generate call we tried was refused before inference (ErrorCode 8: the phone says its latest configuration file hasn't been downloaded). After enrolling, Jenna's Pixel 10 Pro XL also reported `nano-v4-full` available. That was an availability check on a debug build, not an on-device answer. On-device structured output on Android also needs compile-time `@Generable` classes, so the bridge puts the schema in the prompt and Dart validates the answer. <!-- VERIFY: gate G4 (#145). If G4 passes, add the on-device result on the signed release build; if not, keep this as written and claim no Android on-device run -->
5. **The private watch had to be rebuilt.** In the original app a watch needed the Live coach, and Live streams every camera frame. We built a camera-only capture mode with no microphone or audio pipeline, one owner for the camera, a fresh-frame rule (under 2 seconds old) and cancellation on stop, step change, backgrounding and Live takeover.
6. **Proving the fallback without faking it.** A badge that repeats the setting proves nothing. Every result carries the SDK's own report of where it ran, and the release checklist requires a run where the local model is genuinely unavailable and the same request comes back from the cloud. That has passed from a local build. <!-- VERIFY: gate G2 on the hosted build -->

## Accomplishments that we're proud of

- A hybrid Firebase AI Logic app in Flutter, which has no hybrid API, with one privacy policy shared by every platform.
- A camera watch built to run on the device and to ask for a better view instead of guessing. In our gate harness, an obscured frame came back *unsure*. <!-- VERIFY: SS-075 evidence. Accuracy is not measured yet; add no figures until the scored run exists -->
- A ledger written as each request is sent, not reconstructed afterwards, that tells the cook which AI requests left the device and is honest about what the session saves.
- Privacy that holds at send time: one switch, read live, overrides every retry, fallback and remote value.
- Honest labels throughout: on-device vs. cloud, allowed vs. sent, AI-drafted vs. reviewed recipe, simulated vs. real message.

## What we learned

- **Hybrid is a product decision, not just an SDK flag.** `prefer_on_device` is the start. Deciding which data may leave, who approves it, and how the cook finds out is the real design work.
- **Read the shipped SDK, then try it on the device.** Two of our design assumptions were wrong in the installed SDKs. A small gate harness on real hardware caught them before features depended on them.
- **Availability isn't an answer.** A phone can report a model as available and still refuse to run it. We only claim what produced an answer, on the device it ran on.
- **Small models need small jobs.** Bounded schemas, a token budget per task and validation in code let a model with a 4,096-token budget do real work.
- **Asking beats guessing.** An *unsure* that asks for a better view earns more trust than a confident wrong answer.

## What's next for SousSight

- Android and iPhone builds that judges and pantry cooks can install, once each passes on a real device.
- The scored watch evaluation on our labelled photos, with abstentions reported next to accuracy, then a set that grows with every recipe.
- Offline from a cold start, not just within an open cooking session.
- Field sessions with pantry partners, to learn which features cooks keep on the device and which cloud help they actually use.

## Built with

Flutter · Dart · Firebase AI Logic (Web, Android and Apple SDKs) · Gemini Nano in Chrome · Gemini Nano on Android (AICore) · Apple Foundation Models · Gemini (cloud) · Flutter GenUI / A2UI · Grounding with Google Search · Firebase Authentication · Firebase App Check · Cloud Firestore · Cloud Functions for Firebase · Firebase Hosting · GitHub Actions <!-- VERIFY: drop "Gemini Nano on Android" unless gate G4 passed and "Apple Foundation Models" unless gate G5 passed -->

**Try it:** <HOSTED_URL> (desktop Chrome) <!-- VERIFY: final hosted URL --> · **Video:** <YOUTUBE_URL> · **Code:** https://github.com/terryhh/SousSight (AGPL-3.0) <!-- VERIFY: license at <FINAL_TAG> --> · **How to test:** [JUDGES.md](https://github.com/terryhh/SousSight/blob/main/docs/buildhybridai/JUDGES.md)
