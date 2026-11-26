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
- Chrome on Android also works, but Chrome can't run its on-device model on phones, so every
  answer there comes from the cloud or says it can't run.
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
  on their own. The camera watch only sends a frame to the cloud if you tap
  *Ask the cloud about this photo* and then **Allow once** for that exact frame.
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
2. Open SousSight, tap **On-device AI**, then **Set up on-device AI**. A progress bar shows
   the download. Keep the tab open until it finishes.
3. The sheet then shows text and photo availability separately. If photos still say
   unavailable, check the flag from step 1.
4. Optional: `chrome://on-device-internals` shows Chrome's own view of the model.

<!-- VERIFY: the hosted origin runs Chrome's on-device model in a clean profile with only the steps above (no origin-trial token or extra flag needed). G2b/G2c ran on Terry's Chrome. -->

## 4. A five-minute path through the app

1. **Scan.** Type `canned chickpeas, mayonnaise, lemon, celery, red onion, tortillas` and scan.
   Tap the items to confirm them. Look at the badge: **On this device · Gemini Nano** (or **Cloud · Gemini**
   if your Chrome has no model). <!-- VERIFY: exact badge model label shown on the hosted build -->
2. **Cook.** Open the *Smashed Chickpea Salad Wrap*, or tap *Make a meal from these
   ingredients* for a draft recipe.
3. **Watch.** On the *Mash the chickpeas* step, tap **Watch my food** and allow the camera. You'll get a
   camera-only watch: no microphone prompt. Cover the bowl with your hand or tilt it out of
   frame, and it asks for a better view instead of guessing. <!-- VERIFY: SS-075 evidence; watch runs through the production path on the hosted build -->
4. **Go offline.** Turn off Wi-Fi, or open DevTools → Network → **Offline**. Type a question
   such as "How smooth should the mash be?" Coach Lite answers on the device with a small
   panel. If it suggests a timer, tap **Start timer**. <!-- VERIFY: SS-072 scope; Coach Lite answer offline on the hosted build -->
5. **Read the ledger.** Tap **Ledger**. The watch and Coach Lite rows are under *Stayed on
   this device*. *Reported as sent* is empty unless you used a cloud feature.
6. **Back online, one cloud moment.** Ask "Can I use Greek yogurt instead of mayo?" That
   question goes to grounded research with Google Search, shows its sources and Search
   suggestions, and appears in the ledger as a cloud request. <!-- VERIFY: gate G1 approved the research route -->
7. **Dinner's ready.** Finish the recipe and review the "dinner is ready" message. It's
   **simulated**: see section 7.

## 5. What to look for

- **Source badges.** One per request, from the SDK's own report: *On this device*,
  *Cloud · Gemini*, *Cloud* (our Firebase AI Logic client, used when the hybrid SDK can't carry
  the request), *May have been sent* (allowed to leave, then failed, so we can't be sure), or
  *Simulated*. A pantry scan with a voice clip shows two badges, because the voice clip is its
  own cloud request.
- **The ledger.** It separates what SousSight *allowed* to leave from what the SDK *reported*
  as sent. It lists kinds of data (text, image, audio, location), never content. It also says
  what the session saves to Firestore and what the Live coach is told.
- **Offline behaviour.** On-device features keep working with the network off. Cloud features
  say they can't run and why.
- **Consent.** Any photo that might leave the device asks first, names the data and the
  recipient, and covers that one payload only.
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
  on-device model can't look at photos and points to the Live coach's watch, which is labelled
  as cloud vision.

## 7. What is simulated

- **Dinner texts.** The judged build never sends an SMS. The review sheet goes to a fictional
  "Demo household", has no phone number field, and every status starts with
  "Simulated — no SMS sent." The real SMS path stays in the code for other builds and is
  disabled on the server for this one.
- **Nothing else in the judged build is simulated.** AI answers are real model output, on the
  device or in the cloud as the badge says. (Rehearsal mode, where every AI answer is canned and
  labelled *Simulated*, is a separate developer build and is not the hosted app.)
- **The live voice coach** is <!-- VERIFY: gate G3 --> available through Firebase AI Logic if
  the *Live* button is shown. If it isn't shown, this build has no Live coach, and typed
  questions go to Coach Lite.

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
