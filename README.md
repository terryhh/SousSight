# SousSight

Show your ingredients, talk while you cook, and ask “am I doing this right?” SousSight combines Gemini Live camera and voice with dynamically generated Flutter cooking panels, timers, visual watches, and a cook-reviewed dinner-ready message.

The cook supplies human direction. The coach asks targeted questions when facts are missing and uses a separate Google Search grounded request when it needs outside information. The current demonstration uses one Smashed Chickpea Salad Wrap recipe.

- [Current product specification](docs/SPEC.md)
- [AGY task for the research and substitution experience](docs/handoffs/AGY-COOKING-RESEARCH.md)
- [Backend setup and messaging contract](functions/README.md)
- [Live transport integration](lib/live/README.md)
- [Infrastructure costs and credit coverage](docs/COST-LEDGER.md)
- [Teardown plan](docs/TEARDOWN.md)

## Run a rehearsal

Use Flutter on the stable channel compatible with Dart `^3.13.7` (the working setup uses Flutter 3.47.9). Chrome is the initial development target.

```sh
flutter pub get
flutter run -d chrome -t lib/main_learner.dart --dart-define=FAKE_BACKEND=true
```

Rehearsal mode is visibly labelled. It uses in-memory data and simulated coach responses; it does not capture video/audio, perform Google searches, run an actual vision watch, or send messages. Ingredient panels, step progression, and real client countdowns can be exercised without credentials.

## Run with real services

Use the Firebase project configured in `lib/firebase_options.dart`, or regenerate that file for your own project. Enable anonymous Firebase Authentication, Firestore, Firebase AI Logic with the Gemini Developer API, and App Check for the web app. Follow [functions/README.md](functions/README.md) to configure the protected Live-token and dinner-ready endpoints and their server-side secrets.

Create the ignored `dart_defines.local.json` locally. Its supported configuration keys are:

| Key | Purpose |
|---|---|
| `APPCHECK_DEBUG_TOKEN` | Development-only registered App Check debug token. Never publish a build containing it. |
| `RECAPTCHA_SITE_KEY` | Public reCAPTCHA Enterprise site key for the production web origin. |
| `LIVE_TOKEN_URL` | Optional absolute URL to the protected token endpoint. Defaults to `/api/live-token` on the app's origin. |
| `DINNER_MESSAGE_URL` | Optional absolute URL to the dinner endpoint. Defaults to `/api/dinner-ready` on the app's origin. |
| `RESEARCH_MODEL` | Optional grounded research model override; current default is `gemini-3.8-flash`. |

Only set the App Check provider appropriate for the environment. The local Flutter development server does not provide Firebase Hosting API rewrites. For local real-service testing, configure the endpoint URLs and explicitly allow that localhost origin on the backend. A hosted same-origin build uses the `/api/` defaults.

```sh
flutter run -d chrome -t lib/main_learner.dart \
  --web-port=7357 \
  --dart-define-from-file=dart_defines.local.json
```

Allow camera and microphone access, then choose **Cook with me**. Browser capture needs HTTPS or localhost. The backend returns a short-lived token and model/version metadata for Gemini 3.8 Live; the browser never needs a long-lived Gemini API key. Keep `GEMINI_API_KEY` and all Vonage secrets in the backend, never in Dart defines.

## Build

```sh
./tool/build_web.sh --dart-define=FAKE_BACKEND=true
```

For a real-service build, pass an appropriate local config file instead:

```sh
./tool/build_web.sh --dart-define-from-file=dart_defines.local.json
```

Before publishing, ensure that file contains production configuration and no App Check debug token. The script builds `lib/main_learner.dart` into `build/web`; it does not build a board application or deploy anything. Firebase Hosting should serve `build/web` and route `/api/live-token` and `/api/dinner-ready` to the functions before its application fallback.

## Check changes

```sh
flutter analyze
flutter test
node --test test/live/browser_media_test.cjs
npm --prefix functions run check
node --test functions/test/*.test.js
./tool/build_web.sh --dart-define=FAKE_BACKEND=true
```

Use `--no-pub` with Flutter commands when dependencies have already been resolved and network access is intentionally unavailable. If a restricted environment cannot write Flutter's user configuration, point `XDG_CONFIG_HOME` at a writable temporary directory and set `FLUTTER_SUPPRESS_ANALYTICS=true`. Do not treat a denied localhost test socket as a passing test. Build success does not verify camera hardware, credentials, or a real Gemini connection.

## Current limits

- The target JPEG assets are placeholders. Fixture labels such as `Recipe reviewer` do not establish a completed human review.
- Multiple timers run in the active workspace, but only the latest timer ID, label, and deadline restore from the cooking session after reload.
- Vision watches observe appearance and pause when the tab or session stops. Neither vision nor timer expiration certifies food safety; closed/background tabs are not reliable alarm devices.
- Vonage sending is disabled by default and requires an explicit reviewed send, an allowed recipient, and configured services. Provider acceptance is shown as delivery unconfirmed; delivery callbacks are not implemented.
- Production services and a complete phone-to-Gemini-to-Vonage demonstration still require real-service validation. Rehearsal output is deliberately identified as simulated.
