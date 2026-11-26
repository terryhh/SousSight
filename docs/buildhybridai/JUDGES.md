# Testing SousSight: a guide for judges

<!--
  Card SS-080 (#167). Resolve every VERIFY comment before submission (see RELEASE.md), and
  replace <HOSTED_URL>, <APK_URL> and <FINAL_TAG>. Sections marked "gated" are deleted if
  their gate did not pass.
-->

SousSight is a cooking companion that runs its AI on your device when it can and in the cloud
when it has to, through Firebase AI Logic. This page tells you how to try it, what you'll see
on a computer without an on-device model, and how to turn the on-device model on.

You don't need an account, an API key or a phone number. Nothing on this page asks for one.

## 1. Open the app

**Hosted web app:** <HOSTED_URL> <!-- VERIFY: final hosted URL; matches /version.json at <FINAL_TAG> -->

- **Best experience:** Chrome on a Windows, macOS, Linux or Chromebook Plus computer.
- Chrome on Android hasn't been checked with this build. Chrome can't run its on-device model
  on phones, so there every answer would come from the cloud or say it can't run.
- Firefox and Safari are not supported.
- The app signs you in anonymously. Your cooking session is saved to Firestore so a reload
  doesn't lose your place.

To check you're on the judged build, open `<HOSTED_URL>/version.json`. Its `commit` matches
the tag `<FINAL_TAG>` in the repository, and its `config` shows the cloud routes, Live backend
and dinner mode the build was compiled with.

## 2. If your Chrome has no on-device model yet

Most computers won't have Chrome's model downloaded. That's expected, and the app tells you
what's happening rather than failing quietly.

- **The readiness panel** on the pantry screen lists what's missing (no model yet, hardware
  can't run one, camera blocked, offline) and gives a next step for each.
- **Features that may use the cloud** (pantry scan, recipe draft) still work. Their badge
  reads **Cloud · Gemini**, because the Firebase AI Logic SDK fell back to the cloud and said
  so. <!-- VERIFY: gate G1 approved hybridFallback; gate G2 cloud fallback passed. If not, these features say they can't run here instead -->
- **Features that stay on the device by design** (the camera watch, Coach Lite, label check)
  say on-device AI isn't available here and how to set it up. They don't switch to the cloud
  on their own. The on-device watch only sends a frame to the cloud if you tap
  *Ask the cloud about this photo* and then **Allow once** for that exact frame. (In a build
  with the Live coach, while it is on, *Watch my food* uses its cloud watch instead; see section 5.)
- If you turn on **Keep on this device** for a feature in the *On-device AI* sheet, that
  feature never uses the cloud, whatever else happens.

## 3. Turn on Chrome's on-device model

You need desktop Chrome and, according to Chrome's built-in AI documentation:

- at least **22 GB free** on the drive that holds your Chrome profile (Chrome removes the
  model if free space drops under 10 GB);
- a GPU with more than 4 GB of memory, or 16 GB of RAM and 4 CPU cores;
- an unmetered connection for the first download.

Steps:

1. **For photos** (pantry photo, camera watch, label check), open
   `chrome://flags/#prompt-api-for-gemini-nano-multimodal-input`, set it to **Enabled** and
   relaunch Chrome. Typed features don't need the flag.
2. Open SousSight, tap the **On-device AI** button (next to *How it works* on the pantry
   screen), then **Set up on-device AI**. A progress bar shows
   the download. Keep the tab open until it finishes.
3. The sheet then shows text and photo availability separately. If photos still say
   unavailable, check the flag from step 1.
4. Optional: `chrome://on-device-internals` shows Chrome's own view of the model.

<!-- VERIFY: the hosted origin runs Chrome's on-device model in a clean profile with only the steps above (no origin-trial token or extra flag needed). G2b/G2c ran on Terry's Chrome. -->

## 4. A five-minute path through the app

1. **Scan.** Type `canned chickpeas, mayonnaise, lemon, celery, red onion, tortillas` and tap
   **Find my meal**. Tap the items to confirm them. Look at the badge: **On this device** (or **Cloud · Gemini**
   if your Chrome has no model). The web SDK doesn't report a model name, so the badge doesn't
   name one. <!-- VERIFY: badge text on the hosted build (gate #143 recorded "On this device" with no model label) -->
2. **Cook.** Open the *Smashed Chickpea Salad Wrap*, or tap *Make a meal from these
   ingredients* for a draft recipe.
3. **Watch.** On the *Mash the chickpeas* step, tap **Watch my food** and allow the camera. You'll get a
   camera-only watch: no microphone prompt. Cover the bowl with your hand or tilt it out of
   frame, and it asks for a better view instead of guessing. <!-- VERIFY: SS-075 evidence; watch runs through the production path on the hosted build -->
4. **Go offline.** Turn off Wi-Fi, or open DevTools → Network → **Offline**. Type a question
   such as "How smooth should the mash be?" Coach Lite answers on the device with a small
   panel. If it suggests a timer, tap **Start timer**. <!-- VERIFY: SS-072 (#203) merged and a Coach Lite answer seen offline on the hosted build; otherwise drop the offline part of this step and ask the question online -->
5. **Read the ledger.** Tap the **What was sent** button. The sheet, *What left this device*,
   lists AI requests only. The watch and Coach Lite rows are under *Stayed on this device*, and
   *Reported as sent* is empty unless you used a cloud feature. Its last section, *What this
   session keeps*, says what is saved outside the AI ledger: your cooking session (recipe, step,
   confirmed items and allergy answers) is saved to Firestore so a reload doesn't lose it.
6. **Back online, one cloud moment.** Tap **Research a cooking question** and ask "Can I use
   Greek yogurt instead of mayo?" That question goes to grounded research with Google Search, shows its sources and Search
   suggestions, and appears in the ledger as a cloud request. <!-- VERIFY: gate G1 approved the research route -->
7. **Dinner's ready.** Finish the recipe and tap **Text the household: dinner is ready** (or,
   while cooking, **Review dinner message**). It's
   **simulated**: see section 7.

## 5. What to look for

- **Source badges.** One per request, from the SDK's own report: *On this device*,
  *Cloud · Gemini*, *Cloud* (our Firebase AI Logic client, used when the hybrid SDK can't carry
  the request), *May have been sent* (allowed to leave, then failed, so we can't be sure), or
  *Simulated*. A pantry scan with a voice clip shows two badges, because the voice clip is its
  own cloud request.
- **The ledger** (*What was sent*). It covers AI requests. It separates what SousSight
  *allowed* to leave from what the SDK *reported* as sent, and shows a request that was allowed
  and then failed as *May have been sent*, never as stayed. It lists kinds of data (text,
  image, audio, location), never content. Separately, it says what the session saves to
  Firestore and what the Live coach is told. "Stayed on this device" means the AI request did,
  not that nothing about the session was saved.
- **Offline behaviour.** On-device features keep working with the network off. Cloud features
  say they can't run and why.
- **Consent.** A still photo in a hybrid feature (pantry photo, label check) that might go to
  the cloud, and a watch frame you send with *Ask the cloud about this photo*, each ask first
  with **Allow once** / **Don't send**, name the data and the recipient, and cover that one
  payload only.
- **The Live coach is different.** The judged build doesn't include it (see section 7). In a
  build that has it, tapping **Start** (tooltip
  *Cook with me*) opens a continuous camera and microphone stream to Gemini Live through
  Firebase AI Logic. There is no per-frame prompt; the stream runs until you tap **Stop**, the
  coach says it is cloud, and the ledger records the connect. While Live is on, *Watch my food*
  uses that stream (cloud vision) instead of the on-device watch, and says so.
- **Safety wording.** The camera describes what it sees. It never says food is cooked, at a safe
  temperature, fresh or allergen-free.

## 6. Android and iOS

### Android (gated) <!-- VERIFY: gate G4. If G4 did not pass, replace this section with "Android is not part of this entry." -->

- **APK:** <APK_URL> (SHA-256 `<APK_SHA256>`), signed release build.
- Needs a phone that runs Gemini Nano through AICore, with AICore and Android System
  Intelligence up to date. If the phone can't run the on-device model, the app says so and the
  cloud features still work.
- Sideload the APK (allow installs from your browser), open SousSight and follow sections 4–5.

### iOS (gated) <!-- VERIFY: gate G5. If G5 did not pass, replace this section with "iOS is not part of this entry." -->

- The iOS build is shown in the video. We can't distribute an unreviewed iOS build to judges,
  so it isn't installable here.
- To build it yourself: Xcode, a device with Apple Intelligence turned on, and
  `flutter build ios` from the tag `<FINAL_TAG>`. You'll need your own Firebase iOS app
  configuration.
- On iOS the local model (Apple Foundation Models) is text only. The camera watch says the
  on-device model can't look at photos and points to the Live coach's watch (in builds that have it), which is labelled
  as cloud vision.

## 7. What is simulated

- **Dinner texts.** The judged build never sends an SMS. The review sheet goes to a fictional
  "Demo household", has no phone number field, and every status starts with
  "Simulated — no SMS sent." The real SMS path stays in the code for other builds and is
  disabled on the server for this one. <!-- VERIFY: deployed ENABLE_DINNER_MESSAGES is false (last read Nov 8) -->
- **Nothing else in the judged build is simulated.** AI answers are real model output, on the
  device or in the cloud as the badge says. (Rehearsal mode, where every AI answer is canned and
  labelled *Simulated*, is a separate developer build and is not the hosted app.)
- **No live voice coach in this build.** The Live coach through Firebase AI Logic is in the
  code, but the judged build has `LIVE_BACKEND=none`, so the cooking screen has no **Start**
  button and typed questions go to Coach Lite. Google Maps–grounded nearby food help is also
  off (`CLOUD_ROUTES=hybridFallback,research`). <!-- VERIFY: gate G3. If it passes and the judged build turns Live on, say: "If the cooking screen shows a Start button (tooltip Cook with me), the Live coach is available through Firebase AI Logic." -->

## 8. Building from source

The repository is public: https://github.com/terryhh/SousSight (AGPL-3.0). The README covers
setup. The short version: Flutter 3.47.9, then `./tool/build_web.sh` with the dart-defines
listed in `docs/buildhybridai/DESIGN.md` §7. Rehearsal mode
(`--dart-define=FAKE_BACKEND=true`) runs with no Firebase project or credentials.

The Firebase client configuration in `lib/firebase_options.dart` is a set of public
identifiers. Access is controlled by Auth, Firestore rules and App Check. No secrets, tokens or
personal data are in the repository or in these instructions.

## Questions

Open an issue on the repository.
