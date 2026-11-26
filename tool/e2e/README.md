# SousSight browser checks (hero journey)

Automated checks of the cook's hero journey in the **installed Google Chrome**,
driven through Flutter's accessibility (semantics) tree with Playwright. They
exist so the app can be checked visually without a person at the keyboard:
every step is screenshotted at a phone size (412×915) and a laptop size
(1280×800).

```
home → Type it → "bread, peanut butter, banana" → Find my meal →
result + source badge → Peanut Butter Sandwich → cooking screen →
ask a question (Coach Lite) → Watch my food → "What was sent" → On-device AI
```

## Run

```sh
# 1. Build (run.sh never builds). Rehearsal: no Firebase, no AI, no camera.
./tool/build_web.sh --dart-define=FAKE_BACKEND=true          # -> build/web

# 2. Run the journey against that build.
./tool/e2e/run.sh                     # same as: ./tool/e2e/run.sh build/web
```

A real (non-rehearsal) build, kept apart from the rehearsal one:

```sh
flutter build web --release --target=lib/main_learner.dart --output=build/web-real
E2E_MODE=real ./tool/e2e/run.sh build/web-real
```

An already running or hosted build (no local server is started):

```sh
E2E_MODE=real E2E_BASE_URL=https://devfest-flutter-a59e8.web.app ./tool/e2e/run.sh
```

Results go to `tool/e2e/out/<UTC timestamp>/<project>/`:

- `NN-<step>.png`: one screenshot per step (`failure-state.png` if a step fails)
- `report.json`: mode, notes per step (outcome of each AI step, whether a reply
  was visible without scrolling), uncaught errors, console errors, external
  hosts contacted, aborted requests
- `console.log`: the browser console
- `playwright/`: a Playwright trace for any failed test
  (`npx playwright show-trace <trace.zip>` from `tool/e2e/`)

Environment:

| Variable | Meaning |
| --- | --- |
| `E2E_MODE` | `auto` (default; detects the rehearsal banner), `rehearsal` or `real`. Must match the build. |
| `E2E_BASE_URL` | Test this URL instead of serving a build directory. |
| `E2E_ALLOW_AI` | `1` lets model, Live-token and dinner-message requests through. Default: aborted. |
| `E2E_REQUIRE_PREVIEW` | `1` fails the run, in any mode, unless Watch my food showed frames and the pixel check ran (a machine with Gemini Nano, or a rehearsal with simulated frames). |
| `E2E_HEADED` | `1` shows the browser. |
| `E2E_PORT` | Local server port (default 8787). |

## What fails a run

- an invalid configuration (`E2E_MODE`, or a flag that is not `0`/`1`);
- any uncaught page error, or any `console.error` (except requests the run
  itself aborted);
- a missing expected element at any step, or an AI step whose outcome is
  not one the build can legitimately give;
- in rehearsal, **any** request to Firebase (Auth, Firestore, App Check,
  Installations, config), Firebase AI Logic / Gemini, the Live-token or
  dinner-message endpoints, or Vonage, and any `getUserMedia` call (the
  rehearsal banner promises the camera and microphone are not used);
- Watch my food showing neither frames nor a reason; frames that still look
  like the empty placeholder; with `E2E_REQUIRE_PREVIEW=1`, no frames at all.

### Network policy, from the first request

The guard and the evidence listeners are installed before the first
navigation. With `E2E_MODE=rehearsal` or `real` the run uses that mode's
policy from the start. With `E2E_MODE=auto` the first load runs under a
conservative **provisional** policy that blocks Firebase, AI, Live-token,
dinner, Vonage and analytics requests. Once the rehearsal banner shows (or
doesn't), the policy is refined: for a rehearsal, anything the provisional
policy blocked counts as forbidden and fails the run; for a real build, the
page is reloaded under the real policy, and the first load's blocked requests
and console errors stay in `report.json` (`provisionallyBlockedRequests`,
`provisionalConsoleErrors`) without failing the run.

Usage analytics requests are always aborted so automated runs never count as
usage. In a real build, model and messaging requests are aborted unless
`E2E_ALLOW_AI=1`; Firebase Auth and Firestore go through (a real build signs in
anonymously and creates a cooking session document).

## What each mode can show

Which surfaces exist is detected from the page (the cooking screen's
"What was sent" button), not assumed from the mode.

**Rehearsal without a hybrid runtime** (`FAKE_BACKEND=true` today:
`lib/main_learner.dart` passes `hybrid: null`). The journey checks the
rehearsal's own answers and records them in `report.json`:

- Find my meal returns the fixed, simulated result with a "Simulated" source badge;
- sending a question shows "Connect the live coach to talk or type a question."
  (no Coach Lite);
- Watch my food shows "Watch needs a real camera connection…";
- "What was sent" and "On-device AI" are absent.

**Rehearsal with a simulated hybrid runtime** (planned, SS-089): Coach Lite,
the ledger and the On-device AI sheet are exercised as in a real build, and
if the watch paints simulated frames the preview pixel check runs.

**Real build in automation Chrome.** Playwright starts Chrome with a fresh
profile, which has no Gemini Nano, and a local build has no App Check token, so
cloud AI is unavailable too. Expected, and accepted by the journey:

- Find my meal: "Ingredient matching is unavailable right now. Pick a recipe
  below." The journey opens Peanut Butter Sandwich from the recipe list;
- Coach Lite: "This device can't run the on-device coach right now." with the
  recipe's own step text (or a cloud consent prompt, which the run declines);
- Watch my food: "The on-device model here can't look at photos…". The camera
  preview check then **does not run** and `report.json` says so;
- "What was sent" and "On-device AI" open and are screenshotted.

The preview check (frames replace the empty dark-green card; less than half
the card's pixels may look like the placeholder gradient) runs whenever the
card shows frames, in either mode.

## How it drives Flutter

Flutter web draws to a canvas. The run clicks Flutter's hidden
`flt-semantics-placeholder` ("Enable accessibility") so Flutter builds its
semantics DOM, then finds controls by role and accessible name
(`getByRole('button', { name: 'Find my meal' })`). Text is typed with real key
events after the field takes focus; Flutter keeps its own editing state, so a
DOM `fill()` is not reliable. Scrolling uses the mouse wheel, because Flutter
owns its scroll views. Text that Flutter merges into a container's
`aria-label` is matched through either the text or the label (`seen()` in
`flutter.mjs`). No coordinates are used except for the wheel position.

Chrome runs with `--use-fake-device-for-media-stream` and
`--use-fake-ui-for-media-stream`, with camera and microphone permission
granted, so a real build gets Chrome's synthetic camera instead of a prompt.

## App wording

Every piece of app copy the journey matches lives in `copy.mjs`. Each entry
accepts both the wording before the SS-089 UX pass (#221) and the wording
after it (for example "What was sent" / "What we sent", "Rehearsal mode" /
"Practice mode (pretend answers)"). When copy changes, add the new wording
there; the unit tests check that every entry matches both old and new text.
Flutter web does not expose widget keys in the DOM; `Semantics(identifier:)`
on the journey's controls would give copy-independent selectors.

## Setup notes

- Node 20+. `run.sh` installs the pinned `@playwright/test` (exact version in
  `package.json`/`package-lock.json`) with `PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1`;
  no Playwright browsers are downloaded. Google Chrome must be installed.
- A Flutter web build loads CanvasKit from `www.gstatic.com` and Roboto from
  `fonts.gstatic.com` by default, so even rehearsal needs network for those.
  Build with `--no-web-resources-cdn` to bundle CanvasKit; the run lists every
  external host in `report.json`.

## Unit tests

The tooling itself (request policy, configuration check, preview pixel test,
static server, `run.sh` argument handling) is tested without a browser:

```sh
node --test test/e2e/
```
