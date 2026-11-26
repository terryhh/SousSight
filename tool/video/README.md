# Demo video pipeline (SS-095)

Builds a **draft** of the #BuildHybridAI demo video (≤ 3:00, 1920×1080, H.264/AAC)
from real screen recordings of the app, Terry's own clips, title cards and a
voice-over, following an edit decision list (EDL).

Contest rules this follows: app footage is always a **real recording** of the
app (`capture.mjs`) or Terry's own clip; only the title cards, caption overlays
and placeholder cards are generated images. No tokens, keys or personal data
are recorded: capture records the page only (no browser chrome, profile or URL
bar), with a fresh browser profile.

## One command at a time

```sh
export PATH="$HOME/dev/flutter/bin:$PATH"
(cd tool/e2e && PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1 npm ci && npx playwright install ffmpeg)  # once

# 1. Rehearsal build (no Firebase, no AI, no camera; CanvasKit bundled)
./tool/build_web.sh --dart-define=FAKE_BACKEND=true --no-web-resources-cdn

# 2. Capture: one clip per journey step, desktop and phone (about 7 minutes)
node tool/video/capture.mjs

# 3. Titles (assemble.py runs this itself; run it alone to preview the cards)
node tool/video/titles.mjs --edl tool/video/edl.json --out build/video/work/cards

# 4. Assemble the draft and the contact sheet
python3 -I tool/video/assemble.py
```

Outputs (all gitignored under `build/video/`):

| Path | What |
| --- | --- |
| `build/video/capture/<viewport>/<step>.mp4` | one 1080p30 clip per journey step |
| `build/video/capture/<viewport>/manifest.json` | what each step showed, or why it is absent; request report |
| `build/video/soussight-demo-draft.mp4` | the assembled draft |
| `build/video/soussight-demo-contact-sheet.png` | one frame per EDL segment, labelled |
| `build/video/assembly-report.json` | what each segment was built from; missing Terry clips and captures; warnings |

## Tools

**`capture.mjs`** drives the installed Google Chrome with Playwright (the
pinned copy and helpers in `tool/e2e/`, with a fake camera and microphone) and
records with `recordVideo`: desktop at 1920×1080, phone at 412×915 placed in a
phone frame on a 1080p canvas. A visible pointer glides to each control, text
is typed key by key, and each step holds for a few seconds so editors can trim.
Steps (`journey_steps.json`): `home`, `type-list`, `find-meal`,
`result-badge`, `open-recipe`, `cooking-screen`, `coach-lite-question`,
`coach-lite-answer`, `watch-start`, `watch-unsure`, `ledger`,
`on-device-sheet`, `how-it-works`. A step the build cannot show is recorded as
`absent` in the manifest, with the reason, and gets no clip.

A step is evidence only of the UI state it asserted, and the manifest's
`outcome` says which state that was. `coach-lite-answer` is `answered` only
when a source badge that appeared for this question names a finished leg and
no fallback note says the coach could not answer. A failed, blocked, declined
or "Live coach needed" reply keeps its own outcome. `watch-unsure` needs the
watch's own unsure verdict ("Move the pan or bowl into view"); the cook's
"Not sure" chip does not count. App copy comes from `tool/e2e/copy.mjs`, which
accepts the wording from before and after SS-089. Copy that only the video
needs is in `VIDEO_COPY` in `capture.mjs`.

- Default target: the local **rehearsal** build in `build/web`. The run stops
  if the rehearsal banner is missing, if the page contacts Firebase or any AI,
  Live-token, dinner-message or Vonage endpoint, or if it opens the camera or
  microphone (the same rules as `tool/e2e`).
- Hosted build: `node tool/video/capture.mjs --base-url https://<host> --real-services`.
  `--real-services` is required; model and messaging calls stay blocked unless
  `--allow-ai` is added as well (that spends quota: only for a named gate).
  Automation Chrome has a fresh profile with **no Gemini Nano**, so a hosted
  capture shows the "unavailable" states, not on-device results.
- `--pantry`, `--recipe` and `--question` change the typed text (the defaults
  match the rehearsal's fixed simulated result: bread and peanut butter, Peanut
  Butter Sandwich). `--viewports desktop`, `--headed`, `--no-cursor`,
  `--keep-raw` are also available.

**`titles.mjs`** renders the stills from HTML in headless Chrome, 1920×1080,
in the brand palette (forest `#285b43`/`#143a2b`, terracotta `#bf5b32`, cream
`#fffdf8`/`#f5f1e8`, gold `#e9a23b`) with the system sans font: title cards,
transparent caption overlays, placeholder cards, the phone frame and the
contact sheet.

**`assemble.py`** (`python3 -I`, standard library only) validates the EDL,
builds each segment (trimmed to its duration, or held on its last frame when
the clip is short), burns in captions as PNG overlays (the Homebrew ffmpeg has
neither `drawtext` nor `subtitles`), mixes the voice-over, exports the MP4,
checks it (H.264, AAC, 1920×1080, **≤ 3:00 or exit 3**) and makes the contact
sheet. `--validate-only`, `--dry-run` (print the ffmpeg commands),
`--skip-cards`, `--no-voiceover` and `--edl <path>` are available.

## The EDL

`tool/video/edl.json` (written from `docs/buildhybridai/DEMO-SCRIPT.md`) is a
JSON array of segments in order:

```json
{"id": "s02", "start": "0:12", "duration_s": 3, "source": "capture",
 "capture": {"journey_step": "home", "viewport": "desktop", "in_s": 0},
 "caption": "An AI sous-chef for pantry cooks", "voiceover": "This is SousSight.", "gate": ""}
```

- `source` is `capture` (needs `capture.journey_step` from the list above and
  `capture.viewport` `desktop`/`phone`; optional `capture.in_s` starts that
  far into the clip), `terry` (needs `terry_clip`, a slot name, and
  `terry_instructions`) or `title` (needs `title.text`, optional `title.sub`).
- The total must be **≤ 175 s** (3:00 minus slack). Durations decide the
  timeline; a `start` that disagrees by more than 0.5 s is only a warning.
- `gate` names the gate the segment depends on (DEMO-SCRIPT.md). The
  pipeline does not check gates: cut or replace a segment whose gate did not
  pass.

## Terry's clips and voice-over

Drop files into `tool/video/input/` (gitignored):

- `tool/video/input/terry/<slot>.mp4` or `.mov`, named after the EDL's
  `terry_clip` (for example `T01-pantry-counter-hook.mov`). Any length; it is
  trimmed to the segment, or held on its last frame if short. Its own sound is
  kept at 35% under the voice-over. Until a clip is there, the draft shows a
  card reading "Terry clip: <slot> — <instructions>".
- `tool/video/input/voiceover.wav` or `voiceover.m4a`: one track for the whole
  video, starting at 0:00. Without it, the draft voice-over is synthesized per
  segment with macOS `say` (voice Samantha), placed at each segment's start and
  sped up only when a line would run into the next one. It is a **draft**: the
  contact sheet title says which voice-over was used.

Run `python3 -I tool/video/assemble.py` again after adding files;
`build/video/assembly-report.json` lists what is still missing.

## Tests

```sh
python3 -I -m unittest discover -s test/video -p 'test_*.py'
node --test test/video/
```

No ffmpeg, browser or network needed: command construction, EDL validation,
timeline math and the HTML are tested; external commands are faked.
