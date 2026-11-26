# One-command verification (SS-088)

`tool/verify_all.sh` runs every local check SousSight has, in order, as named steps. It keeps
going after a failure, prints one summary table, and exits 1 if any step failed. A step whose
tool is missing is **SKIP** with the reason; a skip is not a pass, and the final line says how
many steps were skipped.

```sh
./tool/verify_all.sh                 # everything this machine can run
./tool/verify_all.sh --quick         # analysis, unit tests, coverage gate, Node, functions
./tool/verify_all.sh --no-native     # skip the Android APK and iOS builds
./tool/verify_all.sh --no-e2e        # skip the browser journey
./tool/verify_all.sh --dry-run       # show the plan (run/skip per step), run nothing
./tool/verify_all.sh --update-baseline   # raise the coverage minimums (never lowers them)
```

Output goes to `build/verify/` (override with `VERIFY_OUT_DIR`): `summary.txt`,
`summary.md` (a Markdown table to paste into a PR), `coverage.txt`, `logs/NN-step.log`, the app
and plugin lcov files and a merged `lcov.info` with repository-relative paths. The script never
writes the repository's `coverage/` directories.

## Steps

| # | Step | Command | Skipped when |
|---|---|---|---|
| 1-2 | pub get | `flutter pub get --enforce-lockfile` (app, as CI), `flutter pub get` (plugin) | — |
| 3-4 | analyze | `flutter analyze --no-pub`, app and `packages/ai_logic_hybrid` | — |
| 5-6 | unit tests | `flutter test --no-pub --coverage`, app and plugin | — |
| 7 | coverage gate | `python3 -I tool/coverage/coverage_gate.py` | a test step failed (no fresh lcov) |
| 8 | plugin web tests | `flutter test --platform chrome test/web` in the plugin | `--quick`, no Chrome |
| 9 | Node bridge + media | `node --test test/hybrid/*.cjs test/live/browser_media_test.cjs` | no node |
| 10 | script tests | `node --test test/tool/*.cjs`, `python3 -m unittest discover -s test/tool -p 'test_*.py'` | no node |
| 11 | functions | `npm --prefix functions run check && npm --prefix functions test` (runs `npm ci` first if `node_modules` is missing) | no node |
| 12 | Firestore rules | `npm --prefix test/rules test` (emulator) | `--quick`, no `firebase` CLI, no JDK 21+ |
| 13 | rehearsal web build | `./tool/build_web.sh --no-pub --dart-define=FAKE_BACKEND=true` | `--quick` |
| 14-16 | judged web build | writes `judged_defines.json` (`FAKE_BACKEND=false`, `DINNER_MODE=simulated`, `LIVE_BACKEND=none`, `CLOUD_ROUTES=`), then `check_build_config.sh --judged`, `build_web.sh --dart-define-from-file=…`, `check_web_bundle.sh --warn-live-marker --commit HEAD --config …` | `--quick`; later parts skip if an earlier part failed |
| 17 | Android | `flutter build apk --debug --no-pub` | `--quick`, `--no-native`, no SDK at `$ANDROID_HOME` |
| 18 | iOS | `flutter build ios --no-codesign --debug --no-pub` | `--quick`, `--no-native`, not macOS, no Xcode |
| 19 | secret scan | gitleaks 8.30.1 `git --config .gitleaks.toml --redact=100 --log-opts="--all --full-history"` | `--quick`, no binary and the download failed |
| 20 | browser journey | `tool/e2e/run.sh` | `--quick`, `--no-e2e`, script not on the branch, no Chrome |

The judged bundle check uses `--warn-live-marker` exactly as the CI validate job does: until
SS-074 compiles the ephemeral Live transport out of the judged build, its markers are a
warning on PRs and an error only in the deploy job.

### Tool discovery

- **Flutter:** `flutter` on `PATH`, else `~/dev/flutter/bin`.
- **Android:** `ANDROID_HOME` (default `~/Library/Android/sdk`); `JAVA_HOME` (default Homebrew
  `openjdk@17`).
- **Firestore emulator:** firebase-tools 14+ refuses Java older than 21, so the rules step looks
  for a JDK 21+ (`RULES_JAVA_HOME`, Homebrew `openjdk@21` or `openjdk`, the JDK on `PATH`) and
  skips with the version it found otherwise. `brew install openjdk@21` enables it on a Mac.
- **Chrome:** `CHROME_EXECUTABLE`, the macOS app, or `google-chrome`/`chromium` on `PATH`.
- **gitleaks:** `GITLEAKS`, a `gitleaks` 8.30.1 on `PATH`, or a cached copy in
  `~/.cache/soussight/gitleaks-8.30.1/` (`SOUSSIGHT_CACHE`; must be outside the repository).
  When none exists the script downloads the release archive for this OS/CPU and checks it
  against the SHA-256 pinned in the script (from the official
  `gitleaks_8.30.1_checksums.txt`; the Linux x64 value is the one the Secret scan workflow pins).
  A failed download is a skip; a checksum mismatch is a skip that refuses to run the binary.

## Coverage gate

`tool/coverage/coverage_gate.py` (Python 3 standard library, run with `python3 -I`) reads the
app and plugin lcov files, merges them (repeated records merge by the highest hit count), and
measures **line coverage** — the share of lcov `DA` lines with a hit — for two gated roots:

- `lib` — the app's `lib/`
- `plugin` — `packages/ai_logic_hybrid/lib/`

Excluded as generated: `lib/firebase_options.dart`, `*.g.dart`, `*.freezed.dart`,
`*.mocks.dart`.

Each root must be at or above its integer minimum in `tool/coverage/baseline.json`. The
minimums were set to the measured coverage on the trunk, rounded down. `--update-baseline`
raises each minimum to the current measurement rounded down and never lowers one; run it (or
`./tool/verify_all.sh --update-baseline`) after adding tests and commit the new baseline with
them. A root with no coverage data fails even at a zero minimum, and a missing lcov file is an
input error (exit 2), never a pass.

The report (`build/verify/coverage.txt`) lists the gated roots, a per-area table
(`lib/ai`, `lib/trust`, `lib/watch`, `lib/pantry`, `lib/coach_lite`, `lib/label`, `lib/live`,
`lib/learner`, `lib/data`, `plugin`, then every other `lib/` area), the 15 lowest-covered files,
and the files no test loads.

**Limitation.** `flutter test --coverage` only instruments libraries a test loads. A Dart file
that no VM test imports (entry points such as `lib/main.dart`, web-only `*_web.dart` files) has
no lcov lines, so it cannot be part of the percentage. The report lists those files under "Not
loaded by any VM test" instead of hiding them. Web-only code is exercised by the Chrome and
Node steps, which do not produce lcov.

## CI

The `validate` job in `.github/workflows/firebase.yml` runs the same gates where a hosted
Ubuntu runner can: app and plugin tests with `--coverage`, then the **Coverage gate** step
(same script, same baseline; the report is added to the job summary), the script tests in
`test/tool/` (now every `test_*.py` and `*.cjs`, which includes the gate's and this script's own
tests), the rules emulator, both web builds and the bundle guards. The Secret scan workflow runs
gitleaks on full history. Native builds and the Chrome plugin tests run only locally.

## Evidence level

Everything here runs locally with fakes: no step calls a model, a Firebase service or a
device. Passing `verify_all.sh` means the code analyses, its tests pass against fakes and
emulators, and the web and native builds compile — not that a live service was tested.
