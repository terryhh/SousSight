# SS-075 evidence: the on-device watch on labelled photos, and one filmed cook-through

<!-- Card SS-075 (#162). Owner: jennajh. Only measured numbers go in "Results". -->

**Status (2026-11-26): no measured run yet.** The scoring tool and its tests are in
`tool/hybrid_eval/`. Nothing below has been run against a real on-device model, and the filmed
cook-through has not been shot. Until a run is pasted into [Results](#results), the submission,
the video and `RELEASE.md` must not quote any watch accuracy, latency or upload number.

## 1. What is measured

Each of the eight labelled photos in `assets/reference-cooking/fixtures.json` goes once through
**the exact request the on-device watch sends**. A test pins the tool's request to
`LocalWatchController`'s by payload digest. The request has the same feature key
(`local_watch`), system instruction, prompt, JSON schema, token limit and timeout, and goes
through the app's `HybridDispatcher`. It has no result validator, so there is no cloud retry.
The answer is parsed with the app's own `parseWatchJson`.

The tool approves no cloud route, and the routing policy forces `local_watch` to
`onlyOnDevice`. Even so, uploads are **counted from the inference legs**, not assumed.

### Scoring rules (`ss075-v1`), fixed before any run

Each trial is scored in three parts. Every rate is reported with its denominator.

1. **Verdict class:** `matchesTarget` ↔ `ready`, `adjust` ↔ `not_yet`, `needBetterView` ↔
   `unsure`.
2. **Observation (human-scored, blind):** does `whatISee` state what the fixture's
   `expectedObservations` say is visible, and not its opposite? The scorer sees the photo, the
   expected observations and the watch's sentence. The verdict and the score stay hidden until
   every observation is marked. A blocked or failed trial has no sentence, so it is scored as
   not matching. A sentence the app redacted for an unsupported claim is shown as redacted.
3. **Next action:** what the cook would do after reading the app's message.

   | Watch says | App message | Cook action |
   |---|---|---|
   | `ready` | "This looks like the cue… have a look yourself before moving on" | move on |
   | `not_yet` + `more`, or `not_yet` + `none` | "keep going" / "Not at the cue yet" | keep going |
   | `not_yet` + `less` | "It may be past the cue — have a look" | stop and look |
   | `unsure` | "Move the camera closer, clear steam or hands, or add light" | reframe |

   | Fixture label | Correct actions |
   |---|---|
   | `matchesTarget` | move on |
   | `needBetterView` | reframe |
   | `adjust` / `mash_more`, `fold_more`, `fold_from_bottom` | keep going |
   | `adjust` / `fine_as_is` (over-mashed: more mashing can't fix it) | stop and look, or move on. **Never keep going** |

   An adjustment id not in this table makes the fixture file fail to load, so a new label can't
   be scored by accident.

The report also counts:
- **Abstentions:**
  - correct `unsure` on the two obscured photos;
  - `ready` on an obscured photo (the unsafe miss);
  - `unsure` on a clear photo.
- **Latency:** answered trials only, as min, lower median and max, in milliseconds. A lower
  median is always a measured sample.
- **Photos uploaded:** legs whose provenance (`sdkCloud` or `cloudAdapter`) proves the photo
  left the device. Legs of unknown provenance that were allowed to transfer are reported
  separately as "may have been uploaded".
- **Evidence level:** read from each answer's final leg. A `simulated` leg labels the whole run
  "fakes only, not evidence of the real model".

A report is **incomplete**, and says so in its first line, until every observation is scored
and hardware, platform, scorer and build SHA are recorded. Publish only complete reports.

### What this does not measure

- **Single photos, not a camera feed.** Each fixture is a 768-px JPEG sent once. The watch's
  5-second cadence, stale-frame skipping and camera handling are covered by
  `test/watch/` on fakes, not here.
- **Text cue, not a target photo.** `fixtures.json` describes an "IMAGE 1 TARGET vs IMAGE 2
  CURRENT" comparison. The shipped watch compares one photo against the step's text cue, so
  that is what this scores.
- **Appearance only.** Like the app, this never measures doneness, temperature, freshness or
  allergen safety.

### Known fixture caveats (from the chef pass on #162)

The photos are Jenna's (`assets/reference-cooking/**`, AGENTS.md). This card reads them and
never edits them.
- **`FIX-MIX-TARGET-01`** shows a vinaigrette salad with whole chickpeas, not the mashed,
  mayo-dressed wrap filling the recipe makes. Its own `uncertaintyAndLimitations` says it
  "evaluates mixing/coating distribution only". Read its results with that in mind.
- **`assets/recipes/chickpea_wrap_v1/target_*.jpg`** are 64×64 placeholders. The watch doesn't
  use them, so this evaluation doesn't either, but they matter for the UI and the video.
  Replacing them is Jenna's decision.

## 2. How to run the photo evaluation

**Before the first run, the integration owner must declare the photos as assets.**
`pubspec.yaml` is a shared file:

```yaml
flutter:
  assets:
    - assets/reference-cooking/
```

This adds about 420 KB to every build. Without it, the tool can't load the photos.

The tool checks every photo's SHA-256 against `fixtures.json` before the first send. A mismatch
stops the run.

| Platform | How | Notes |
|---|---|---|
| Chrome desktop | `flutter run -t tool/hybrid_eval/main_watch_eval.dart -d chrome --dart-define=GIT_SHA=$(git rev-parse --short HEAD) --dart-define=APPCHECK_DEBUG_TOKEN=…` | Image input needs `chrome://flags/#prompt-api-for-gemini-nano-multimodal-input` and the local model downloaded (DESIGN §3). Keep the debug token local; never commit or deploy it |
| Android | Same target with `-d <device>` | Nano through AICore; Pixel 9 is Nano 3, Nano 4 needs the AICore preview (DESIGN §3, AGENT.md §6) |
| iOS | Not applicable | The local model is text only, so the watch offers the Live coach instead (`WatchService`). Report as "not applicable", not as a failure |

On the device:
1. Enter the hardware (device, OS, browser and version) and who is scoring.
2. Tap **Run the photos**.
3. Score each observation.
4. Copy the Markdown into [Results](#results), and the JSON into a `<details>` block under it.

One run is eight trials. Repeat runs are added as separate entries. Never replace a run you
didn't like.

## 3. Filmed cook-through protocol

One take on real hardware, in a kitchen **not used for the fixtures**, cooking
`chickpea_wrap_v1` on the judged build. The cook acceptance record itself goes in Jenna's
`docs/validation/cook-acceptance/` (SS-023); link it from [Results](#results).

**Record before filming:**
- the device and OS;
- the browser and its version;
- the build SHA;
- the connection;
- who the cook is.

Note whether the cook knows the app. Everyone in frame agrees to be filmed. Show no faces
unless they agree, and no third-party logos.

**The take must show, in order:**
1. **A local watch on the mash.** Tap *Watch my food*. The capture label reads camera on,
   microphone off.
2. **An obscured bowl.** Hand, steam or a bad angle. The watch says it can't see clearly and
   asks for a better view. It doesn't guess. If it says *ready*, keep filming, don't retake,
   and log it as a miss.
3. **The cook's correction.** The cook reframes, and the next verdict follows what the camera
   now shows. The cook, not the app, decides the step is done.
4. **The connection drops.** Turn on airplane mode, or cut the Wi-Fi, mid-step. Show it on
   screen.
5. **Completion after the drop.** The cook asks about the step and gets the on-device answer,
   a real timer runs, and the session finishes.
6. **Photos uploaded, measured.** Show the ledger view (`lib/trust/ledger_view.dart`) at the
   end and write down its counts as shown. Don't infer them.

**Never edit a verdict in post.** Report misses as they happened.

## Results

_No measured run yet._

<!-- Paste each complete report here, newest first, with its JSON in a <details> block.
     Incomplete reports are not results. -->
