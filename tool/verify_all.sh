#!/usr/bin/env bash
# One-command green check for SousSight (SS-088). See docs/buildhybridai/VERIFY.md.
#
#   ./tool/verify_all.sh [--quick] [--no-native] [--no-e2e] [--dry-run] [--verbose]
#                        [--update-baseline]
#
# Runs every local check as a named step, continues after failures, prints one
# summary table and exits 1 if any step failed (0 otherwise; 2 on bad usage).
# Steps whose tool is missing are SKIPPED with the reason; a skip is not a pass.
#
#   --quick            analysis, unit tests, coverage gate, Node and functions
#                      tests only: no Chrome tests, emulator, builds, secret
#                      scan or browser journey
#   --no-native        skip the Android APK and iOS builds
#   --no-e2e           skip the browser journey (tool/e2e/run.sh)
#   --dry-run          print the plan (run/skip per step) without running it
#   --verbose          stream each step's output instead of only logging it
#   --update-baseline  let the coverage gate raise tool/coverage/baseline.json
#
# Environment: FLUTTER_ROOT or flutter on PATH (default $HOME/dev/flutter/bin is
# added when present); ANDROID_HOME (default $HOME/Library/Android/sdk);
# JAVA_HOME (default Homebrew openjdk@17); RULES_JAVA_HOME (a JDK 21+ for the
# Firestore emulator, found automatically when installed); CHROME_EXECUTABLE;
# GITLEAKS (a gitleaks 8.30.1 binary); SOUSSIGHT_CACHE (default ~/.cache/soussight, holds the
# checksum-verified gitleaks download, never inside the repository).
#
# Output (VERIFY_OUT_DIR, default build/verify): logs/NN-step.log, summary.txt,
# summary.md, coverage.txt, app/plugin lcov and the merged lcov.info. The
# script never writes the repository's coverage/ directories.
#
# Bash 3.2 compatible (macOS /bin/bash): no associative arrays, and no empty
# array expansion under `set -u`.
set -o pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root" || exit 2

quick=false
native=true
e2e=true
dry_run=false
verbose=false
update_baseline=false
while (($#)); do
  case "$1" in
    --quick) quick=true ;;
    --no-native) native=false ;;
    --no-e2e) e2e=false ;;
    --dry-run) dry_run=true ;;
    --verbose) verbose=true ;;
    --update-baseline) update_baseline=true ;;
    -h | --help)
      awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"
      exit 0
      ;;
    *)
      printf 'Unknown option: %s (see --help)\n' "$1" >&2
      exit 2
      ;;
  esac
  shift
done

GITLEAKS_VERSION=8.30.1
plugin_dir=packages/ai_logic_hybrid
out_dir="${VERIFY_OUT_DIR:-$root/build/verify}"
log_dir="$out_dir/logs"
mkdir -p "$log_dir"
rm -f "$log_dir"/*.log

if ! command -v flutter >/dev/null 2>&1 && [[ -x "$HOME/dev/flutter/bin/flutter" ]]; then
  PATH="$HOME/dev/flutter/bin:$PATH"
fi
: "${ANDROID_HOME:=$HOME/Library/Android/sdk}"
export ANDROID_HOME
if [[ -z "${JAVA_HOME:-}" ]]; then
  brew_jdk=/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home
  [[ -x "$brew_jdk/bin/java" ]] && export JAVA_HOME="$brew_jdk"
fi
if [[ -n "${JAVA_HOME:-}" && -x "$JAVA_HOME/bin/java" ]]; then
  PATH="$JAVA_HOME/bin:$PATH"
fi
export PATH

# ---- step bookkeeping -------------------------------------------------------
names=()
results=()
times=()
notes=()
step_no=0

slug() { printf '%s' "$1" | tr 'A-Z' 'a-z' | tr -cs 'a-z0-9' '-' | sed 's/-$//'; }

duration() {
  local s=$1
  if ((s >= 60)); then printf '%dm%02ds' $((s / 60)) $((s % 60)); else printf '%ds' "$s"; fi
}

record() { # name result seconds note
  names+=("$1")
  results+=("$2")
  times+=("$3")
  notes+=("$4")
}

skip() { # name reason
  step_no=$((step_no + 1))
  printf '\n[%02d] %s: SKIP (%s)\n' "$step_no" "$1" "$2"
  record "$1" SKIP 0 "$2"
}

# run NAME [-C DIR] -- COMMAND...   Runs COMMAND, logging to build/verify/logs.
run() {
  local name=$1 dir=$root
  shift
  if [[ "$1" == -C ]]; then
    dir=$2
    shift 2
  fi
  [[ "$1" == -- ]] && shift
  step_no=$((step_no + 1))
  local log
  log="$log_dir/$(printf '%02d' "$step_no")-$(slug "$name").log"
  if $dry_run; then
    local where=.
    [[ "$dir" != "$root" ]] && where="${dir#"$root"/}"
    printf '[%02d] %s: would run: (cd %s && %s)\n' "$step_no" "$name" "$where" "$*"
    record "$name" PLAN 0 "$*"
    return 0
  fi
  printf '\n[%02d] %s ...\n' "$step_no" "$name"
  local start=$SECONDS status
  if $verbose; then
    (cd "$dir" && "$@") 2>&1 | tee "$log"
    status=${PIPESTATUS[0]}
  else
    (cd "$dir" && "$@") >"$log" 2>&1
    status=$?
  fi
  local elapsed=$((SECONDS - start))
  if ((status == 0)); then
    # A passing step can still warn (e.g. --warn-live-marker): surface it.
    local warnings note=''
    warnings="$(grep -c '::warning::' "$log" 2>/dev/null)"
    if [[ -n "$warnings" && "$warnings" != 0 ]]; then
      note="$warnings ::warning:: line(s); see ${log#"$root"/}"
    fi
    printf '[%02d] %s: PASS (%s)%s\n' "$step_no" "$name" "$(duration "$elapsed")" "${note:+ -- $note}"
    record "$name" PASS "$elapsed" "$note"
  else
    printf '[%02d] %s: FAIL (exit %d, %s) -- last lines of %s:\n' \
      "$step_no" "$name" "$status" "$(duration "$elapsed")" "${log#"$root"/}"
    $verbose || tail -n 25 "$log" | sed 's/^/    /'
    record "$name" FAIL "$elapsed" "exit $status; log ${log#"$root"/}"
  fi
  return "$status"
}

last_result() { printf '%s' "${results[${#results[@]} - 1]}"; }

# ---- environment probes -------------------------------------------------------
have() { command -v "$1" >/dev/null 2>&1; }

chrome_path() {
  if [[ -n "${CHROME_EXECUTABLE:-}" ]]; then
    [[ -x "$CHROME_EXECUTABLE" ]] && printf '%s' "$CHROME_EXECUTABLE"
    return
  fi
  local candidate
  for candidate in "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
    google-chrome google-chrome-stable chromium chromium-browser; do
    if [[ -x "$candidate" ]]; then
      printf '%s' "$candidate"
      return
    fi
    if have "$candidate"; then
      command -v "$candidate"
      return
    fi
  done
}

java_major() { # prints the major version of the java on PATH, or nothing
  have java || return 0
  java -version 2>&1 | sed -n 's/.*version "\([0-9][0-9]*\).*/\1/p' | head -n 1
}

gitleaks_platform() {
  local os arch
  case "$(uname -s)" in Darwin) os=darwin ;; Linux) os=linux ;; *) return 1 ;; esac
  case "$(uname -m)" in arm64 | aarch64) arch=arm64 ;; x86_64) arch=x64 ;; *) return 1 ;; esac
  printf '%s_%s' "$os" "$arch"
}

gitleaks_sha256() { # official gitleaks_8.30.1_checksums.txt
  case "$1" in
    darwin_arm64) echo b40ab0ae55c505963e365f271a8d3846efbc170aa17f2607f13df610a9aeb6a5 ;;
    darwin_x64) echo dfe101a4db2255fc85120ac7f3d25e4342c3c20cf749f2c20a18081af1952709 ;;
    linux_arm64) echo e4a487ee7ccd7d3a7f7ec08657610aa3606637dab924210b3aee62570fb4b080 ;;
    linux_x64) echo 551f6fc83ea457d62a0d98237cbad105af8d557003051f41f3e7ca7b3f2470eb ;;
    *) return 1 ;;
  esac
}

sha256_of() {
  if have sha256sum; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

gitleaks_ok() { "$1" version 2>/dev/null | grep -q "$GITLEAKS_VERSION"; }

# Prints a gitleaks 8.30.1 binary path, downloading it checksum-verified into
# the cache when needed. Prints nothing (and a reason on stderr) on failure.
find_gitleaks() {
  if [[ -n "${GITLEAKS:-}" ]]; then
    if gitleaks_ok "$GITLEAKS"; then printf '%s' "$GITLEAKS"; else echo "GITLEAKS is not $GITLEAKS_VERSION" >&2; fi
    return
  fi
  if have gitleaks && gitleaks_ok gitleaks; then
    command -v gitleaks
    return
  fi
  local cache="${SOUSSIGHT_CACHE:-$HOME/.cache/soussight}/gitleaks-$GITLEAKS_VERSION"
  case "$cache/" in "$root"/*)
    echo 'SOUSSIGHT_CACHE must be outside the repository' >&2
    return
    ;;
  esac
  if [[ -x "$cache/gitleaks" ]] && gitleaks_ok "$cache/gitleaks"; then
    printf '%s' "$cache/gitleaks"
    return
  fi
  local platform expected tmp
  platform="$(gitleaks_platform)" || {
    echo "no pinned gitleaks build for $(uname -s)/$(uname -m)" >&2
    return
  }
  expected="$(gitleaks_sha256 "$platform")"
  tmp="$(mktemp -d)"
  local url="https://github.com/gitleaks/gitleaks/releases/download/v$GITLEAKS_VERSION/gitleaks_${GITLEAKS_VERSION}_$platform.tar.gz"
  if ! curl --fail --silent --show-error --location --max-time 120 "$url" --output "$tmp/gitleaks.tar.gz" 2>/dev/null; then
    rm -rf "$tmp"
    echo "gitleaks $GITLEAKS_VERSION not installed and download failed (offline?)" >&2
    return
  fi
  if [[ "$(sha256_of "$tmp/gitleaks.tar.gz")" != "$expected" ]]; then
    rm -rf "$tmp"
    echo "gitleaks download checksum mismatch; refusing to run it" >&2
    return
  fi
  mkdir -p "$cache" && tar -xzf "$tmp/gitleaks.tar.gz" -C "$cache" gitleaks
  rm -rf "$tmp"
  [[ -x "$cache/gitleaks" ]] && printf '%s' "$cache/gitleaks"
}

ensure_npm() { # dir: install locked deps when node_modules is missing
  [[ -d "$1/node_modules" ]] || npm --prefix "$1" ci --no-audit --no-fund
}

functions_suite() {
  ensure_npm functions &&
    npm --prefix functions run check &&
    npm --prefix functions test
}

rules_suite() {
  ensure_npm test/rules && npm --prefix test/rules test
}

script_tests() {
  local status=0 cjs=()
  local file
  for file in test/tool/*.cjs; do [[ -e "$file" ]] && cjs+=("$file"); done
  if ((${#cjs[@]})); then node --test "${cjs[@]}" || status=1; fi
  python3 -m unittest discover -s test/tool -p 'test_*.py' || status=1
  return "$status"
}

node_tests() {
  local files=() file
  for file in test/hybrid/*.cjs test/live/browser_media_test.cjs; do [[ -e "$file" ]] && files+=("$file"); done
  node --test "${files[@]}"
}

write_judged_defines() {
  python3 -I - "$out_dir/judged_defines.json" <<'PY'
import json, sys
with open(sys.argv[1], 'w', encoding='utf-8') as handle:
    json.dump({'FAKE_BACKEND': 'false', 'DINNER_MODE': 'simulated',
               'LIVE_BACKEND': 'none', 'CLOUD_ROUTES': ''}, handle)
PY
}

coverage_gate() {
  local extra=''
  $update_baseline && extra=--update-baseline
  python3 -I tool/coverage/coverage_gate.py --app-lcov "$app_lcov" --plugin-lcov "$plugin_lcov" \
    --report "$out_dir/coverage.txt" --merged-lcov "$out_dir/lcov.info" $extra
}

# ---- steps ------------------------------------------------------------------
chrome="$(chrome_path)"
if [[ -n "$chrome" ]]; then export CHROME_EXECUTABLE="$chrome"; fi

if ! have flutter; then
  printf 'Flutter is not on PATH (and %s is missing).\n' "$HOME/dev/flutter/bin" >&2
  exit 2
fi

run 'flutter pub get (app)' -- flutter pub get --enforce-lockfile
run 'flutter pub get (plugin)' -C "$root/$plugin_dir" -- flutter pub get
run 'flutter analyze (app)' -- flutter analyze --no-pub
run 'flutter analyze (plugin)' -C "$root/$plugin_dir" -- flutter analyze --no-pub

# lcov goes to the output directory (never the repo's coverage/), and old
# files are removed first so a failed run can never be gated on stale data.
app_lcov="$out_dir/app.lcov.info"
plugin_lcov="$out_dir/plugin.lcov.info"
$dry_run || rm -f "$app_lcov" "$plugin_lcov"
run 'flutter test --coverage (app)' -- flutter test --no-pub --coverage --coverage-path "$app_lcov"
run 'flutter test --coverage (plugin)' -C "$root/$plugin_dir" -- \
  flutter test --no-pub --coverage --coverage-path "$plugin_lcov"
if $dry_run || [[ -f "$app_lcov" && -f "$plugin_lcov" ]]; then
  run 'coverage gate' -- coverage_gate
else
  skip 'coverage gate' 'no fresh lcov: a coverage test step failed'
fi

if $quick; then
  skip 'plugin web tests (Chrome)' '--quick'
elif [[ -z "$chrome" ]]; then
  skip 'plugin web tests (Chrome)' 'Chrome not found (set CHROME_EXECUTABLE)'
elif [[ ! -d "$plugin_dir/test/web" ]]; then
  skip 'plugin web tests (Chrome)' "no $plugin_dir/test/web"
else
  run 'plugin web tests (Chrome)' -C "$root/$plugin_dir" -- flutter test --no-pub --platform chrome test/web
fi

if have node; then
  run 'node bridge + media tests' -- node_tests
  if [[ -d test/tool ]]; then
    run 'script tests (test/tool)' -- script_tests
  else
    skip 'script tests (test/tool)' 'no test/tool'
  fi
  run 'functions check + tests' -- functions_suite
else
  skip 'node bridge + media tests' 'node not found'
  skip 'script tests (test/tool)' 'node not found'
  skip 'functions check + tests' 'node not found'
fi

# firebase-tools 14+ refuses to start emulators on Java < 21, while the Android
# build is happy with JDK 17. Look for a JDK 21+ for the emulator only.
java_version="$(java_major)"
rules_java_home=''
if [[ -n "$java_version" ]] && ((java_version >= 21)); then
  rules_java_home="${JAVA_HOME:-}"
else
  for candidate in "${RULES_JAVA_HOME:-}" \
    /opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home \
    /opt/homebrew/opt/openjdk/libexec/openjdk.jdk/Contents/Home \
    /usr/lib/jvm/temurin-21-jdk-amd64 /usr/lib/jvm/java-21-openjdk-amd64; do
    if [[ -n "$candidate" && -x "$candidate/bin/java" ]]; then
      v="$(PATH="$candidate/bin:$PATH" java_major)"
      if [[ -n "$v" ]] && ((v >= 21)); then
        rules_java_home="$candidate"
        break
      fi
    fi
  done
fi
rules_suite_jdk() {
  if [[ -n "$rules_java_home" ]]; then
    JAVA_HOME="$rules_java_home" PATH="$rules_java_home/bin:$PATH" rules_suite
  else
    rules_suite
  fi
}
if $quick; then
  skip 'Firestore rules (emulator)' '--quick'
elif ! have firebase; then
  skip 'Firestore rules (emulator)' 'firebase CLI not found'
elif [[ -z "$rules_java_home" && -z "$java_version" ]]; then
  skip 'Firestore rules (emulator)' 'no Java runtime for the emulator'
elif [[ -z "$rules_java_home" ]]; then
  skip 'Firestore rules (emulator)' "emulator needs JDK 21+, found $java_version (set RULES_JAVA_HOME)"
else
  run 'Firestore rules (emulator)' -- rules_suite_jdk
fi

if $quick; then
  skip 'web build (rehearsal)' '--quick'
  skip 'judged build config check' '--quick'
  skip 'web build (judged)' '--quick'
  skip 'judged bundle check' '--quick'
else
  run 'web build (rehearsal)' -- ./tool/build_web.sh --no-pub --dart-define=FAKE_BACKEND=true
  defines="$out_dir/judged_defines.json"
  $dry_run || write_judged_defines
  run 'judged build config check' -- ./tool/check_build_config.sh --judged "$defines"
  if [[ "$(last_result)" == FAIL ]]; then
    skip 'web build (judged)' 'judged config check failed'
    skip 'judged bundle check' 'judged config check failed'
  else
    run 'web build (judged)' -- ./tool/build_web.sh --no-pub "--dart-define-from-file=$defines"
    if [[ "$(last_result)" == FAIL ]]; then
      skip 'judged bundle check' 'judged build failed'
    else
      # --warn-live-marker mirrors the CI validate job until SS-074 compiles
      # the ephemeral Live transport out; the deploy job enforces it.
      run 'judged bundle check' -- ./tool/check_web_bundle.sh --warn-live-marker \
        --commit "$(git rev-parse HEAD)" --config "$defines" build/web
    fi
  fi
fi

if $quick || ! $native; then
  reason='--no-native'
  $quick && reason='--quick'
  skip 'Android debug APK' "$reason"
  skip 'iOS build (no codesign)' "$reason"
else
  if [[ ! -d "$ANDROID_HOME" ]]; then
    skip 'Android debug APK' "no Android SDK at $ANDROID_HOME"
  elif [[ -z "$java_version" ]]; then
    skip 'Android debug APK' 'no Java runtime (set JAVA_HOME)'
  else
    run 'Android debug APK' -- flutter build apk --debug --no-pub
  fi
  if [[ "$(uname -s)" != Darwin ]]; then
    skip 'iOS build (no codesign)' 'not macOS'
  elif ! xcodebuild -version >/dev/null 2>&1; then
    skip 'iOS build (no codesign)' 'Xcode not available'
  else
    run 'iOS build (no codesign)' -- flutter build ios --no-codesign --debug --no-pub
  fi
fi

if $quick; then
  skip 'gitleaks full history' '--quick'
elif $dry_run; then
  run 'gitleaks full history' -- gitleaks git --config .gitleaks.toml --redact=100 --no-banner \
    '--log-opts=--all --full-history' .
else
  gitleaks_reason="$(mktemp)"
  gitleaks_bin="$(find_gitleaks 2>"$gitleaks_reason")"
  if [[ -n "$gitleaks_bin" ]]; then
    run 'gitleaks full history' -- "$gitleaks_bin" git --config .gitleaks.toml --redact=100 \
      --no-banner '--log-opts=--all --full-history' .
  else
    skip 'gitleaks full history' "$(head -n 1 "$gitleaks_reason")"
  fi
  rm -f "$gitleaks_reason"
fi

if $quick || ! $e2e; then
  reason='--no-e2e'
  $quick && reason='--quick'
  skip 'browser journey (e2e)' "$reason"
elif [[ ! -x tool/e2e/run.sh ]]; then
  skip 'browser journey (e2e)' 'tool/e2e/run.sh not on this branch'
elif [[ -z "$chrome" ]]; then
  skip 'browser journey (e2e)' 'Chrome not found'
else
  run 'browser journey (e2e)' -- ./tool/e2e/run.sh
fi

# ---- summary ------------------------------------------------------------------
{
  printf '%-3s %-34s %-6s %8s  %s\n' '#' 'Step' 'Result' 'Time' 'Note'
  i=0
  while ((i < ${#names[@]})); do
    printf '%-3s %-34s %-6s %8s  %s\n' "$((i + 1))" "${names[$i]}" "${results[$i]}" \
      "$(duration "${times[$i]}")" "${notes[$i]}"
    i=$((i + 1))
  done
} >"$out_dir/summary.txt"

{
  printf '| # | Step | Result | Time | Note |\n|---|---|---|---|---|\n'
  i=0
  while ((i < ${#names[@]})); do
    printf '| %s | %s | %s | %s | %s |\n' "$((i + 1))" "${names[$i]}" "${results[$i]}" \
      "$(duration "${times[$i]}")" "${notes[$i]//|/\\|}"
    i=$((i + 1))
  done
} >"$out_dir/summary.md"

failed=0 passed=0 skipped=0 total_time=0
for r in "${results[@]}"; do
  case "$r" in FAIL) failed=$((failed + 1)) ;; PASS) passed=$((passed + 1)) ;; SKIP) skipped=$((skipped + 1)) ;; esac
done
for t in "${times[@]}"; do total_time=$((total_time + t)); done

printf '\n==== SousSight verify_all summary (%s @ %s) ====\n' \
  "$(git rev-parse --abbrev-ref HEAD 2>/dev/null)" "$(git rev-parse --short HEAD 2>/dev/null)"
cat "$out_dir/summary.txt"
if $dry_run; then
  printf '\nDry run: nothing was executed.\n'
  exit 0
fi
printf '\n%d passed, %d failed, %d skipped in %s. Logs: build/verify/logs/\n' \
  "$passed" "$failed" "$skipped" "$(duration "$total_time")"
[[ -f "$out_dir/coverage.txt" ]] && printf 'Coverage report: build/verify/coverage.txt\n'
if ((failed)); then
  printf 'RESULT: RED\n'
  exit 1
fi
printf 'RESULT: GREEN%s\n' "$( ((skipped)) && printf ' (with %d skipped; a skip is not a pass)' "$skipped")"
exit 0
