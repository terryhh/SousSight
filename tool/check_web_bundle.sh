#!/usr/bin/env bash
# Check a compiled SousSight web build AFTER `flutter build web` and stamp it
# with the commit it was built from. DESIGN.md §6 (SS-074, SS-079) and §7.
#
#   ./tool/check_web_bundle.sh [--warn-live-marker] [--commit SHA] [--ref REF]
#                              [--config DEFINES_JSON] BUILD_DIR
#
# Fails (exit 1) when BUILD_DIR:
#   * has no main.dart.js;
#   * contains a quoted UUID literal in any text file. App Check debug tokens
#     are UUIDs and a clean build contains none, so a compiled-in
#     APPCHECK_DEBUG_TOKEN shows up exactly this way. The value is never
#     printed, only the file;
#   * mentions FIREBASE_APPCHECK_DEBUG_TOKEN outside compiled Dart output
#     (main.dart.js and *.part.js). The FlutterFire App Check plugin always
#     compiles that property name into main.dart.js, so it is not a signal
#     there; anywhere else (index.html, a hand-written script) it would turn
#     on debug mode;
#   * contains the value of $APPCHECK_DEBUG_TOKEN, if that is set at all;
#   * contains an ephemeral Live transport marker (see EPHEMERAL MARKERS);
#     with --warn-live-marker this is a warning instead of a failure.
#
# EPHEMERAL MARKERS. The legacy Live transport (lib/live/
# ephemeral_live_transport.dart) is the only code that dials the Gemini
# Developer API from the browser. Its endpoint strings survive dart2js
# minification as literals:
#   BidiGenerateContentConstrained      the ephemeral-token Live method
#   generativelanguage.googleapis.com   the Gemini Developer API host
# Firebase AI Logic uses firebasevertexai.googleapis.com instead. If either
# string is in the bundle, the ephemeral transport is compiled in, so the
# judged build could select it. SS-074 must choose the Live backend from a
# const LIVE_BACKEND so dart2js drops the transport when it is not
# `ephemeral`.
#
# With --commit, and only when every check passes, BUILD_DIR/version.json is
# rewritten: Flutter's own fields are kept and `commit` (plus `ref` and the
# non-secret `config` keys LIVE_BACKEND, DINNER_MODE, CLOUD_ROUTES when given)
# are added, so the hosted /version.json can be compared with the release tag.
set -euo pipefail

warn_live=false
commit=''
ref=''
config=''
build_dir=''
while (($#)); do
  case "$1" in
    --warn-live-marker) warn_live=true ;;
    --commit | --ref | --config)
      if (($# < 2)); then
        printf '%s needs a value\n' "$1" >&2
        exit 2
      fi
      case "$1" in
        --commit) commit="$2" ;;
        --ref) ref="$2" ;;
        --config) config="$2" ;;
      esac
      shift
      ;;
    -h | --help)
      sed -n '2,37p' "$0"
      exit 0
      ;;
    -*)
      printf 'Unknown option: %s\n' "$1" >&2
      exit 2
      ;;
    *)
      if [[ -n "$build_dir" ]]; then
        printf 'Only one build directory may be given.\n' >&2
        exit 2
      fi
      build_dir="$1"
      ;;
  esac
  shift
done

if [[ -z "$build_dir" ]]; then
  printf 'Usage: %s [--warn-live-marker] [--commit SHA] [--ref REF] [--config DEFINES_JSON] BUILD_DIR\n' "$0" >&2
  exit 2
fi
if [[ -n "$commit" && ! "$commit" =~ ^[0-9a-f]{40}([0-9a-f]{24})?$ ]]; then
  printf '::error::--commit must be a full lowercase hex SHA\n'
  exit 1
fi
if [[ ! -f "$build_dir/main.dart.js" ]]; then
  printf '::error::%s/main.dart.js not found; build the web app first\n' "$build_dir"
  exit 1
fi

errors=0
fail() {
  printf '::error::%s\n' "$1"
  errors=$((errors + 1))
}

# Byte-wise matching: main.dart.js is large and not guaranteed valid UTF-8.
export LC_ALL=C
uuid='[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}'
quote="[\"'\`]"

# -I skips binary files (canvaskit wasm, fonts, images); -l prints only names.
while IFS= read -r file; do
  [[ -n "$file" ]] && fail "Possible App Check debug token (quoted UUID literal) in $file"
done < <(grep -rIlE "$quote$uuid$quote" "$build_dir" || true)

while IFS= read -r file; do
  case "$file" in
    */main.dart.js | *.part.js) ;;
    *) [[ -n "$file" ]] && fail "FIREBASE_APPCHECK_DEBUG_TOKEN referenced in $file (enables App Check debug mode)" ;;
  esac
done < <(grep -rIl 'FIREBASE_APPCHECK_DEBUG_TOKEN' "$build_dir" || true)

if [[ -n "${APPCHECK_DEBUG_TOKEN:-}" ]]; then
  fail 'APPCHECK_DEBUG_TOKEN is set in the environment of a release check'
  while IFS= read -r file; do
    [[ -n "$file" ]] && fail "The APPCHECK_DEBUG_TOKEN value appears in $file"
  done < <(grep -rIlF -e "$APPCHECK_DEBUG_TOKEN" "$build_dir" || true)
fi

for marker in BidiGenerateContentConstrained generativelanguage.googleapis.com; do
  while IFS= read -r file; do
    [[ -z "$file" ]] && continue
    message="Ephemeral Live transport marker '$marker' in $file; the judged build must not compile it in (DESIGN.md §6 SS-074)"
    if [[ "$warn_live" == true ]]; then
      printf '::warning::%s\n' "$message"
    else
      fail "$message"
    fi
  done < <(grep -rIlF -e "$marker" "$build_dir" || true)
done

if ((errors)); then
  printf 'Web bundle rejected (%d problem(s)) in %s\n' "$errors" "$build_dir"
  exit 1
fi

if [[ -n "$commit" ]]; then
  python3 - "$build_dir/version.json" "$commit" "$ref" "$config" <<'PY'
import json, sys
from pathlib import Path
path, commit, ref, config = Path(sys.argv[1]), *sys.argv[2:5]
try:
    version = json.loads(path.read_text(encoding='utf-8'))
    if not isinstance(version, dict):
        version = {}
except (OSError, ValueError):
    version = {}
# Never keep a stamp from an earlier run alongside the new commit.
for stale in ('ref', 'config'):
    version.pop(stale, None)
version['commit'] = commit
if ref:
    version['ref'] = ref
if config:
    defines = json.loads(Path(config).read_text(encoding='utf-8'))
    # Only non-secret keys; never copy the whole defines file.
    version['config'] = {key: str(defines.get(key) or '') for key in (
        'LIVE_BACKEND', 'DINNER_MODE', 'CLOUD_ROUTES')}
    version['config']['LIVE_BACKEND'] = version['config']['LIVE_BACKEND'] or 'none'
path.write_text(json.dumps(version, sort_keys=True) + '\n', encoding='utf-8')
PY
  printf 'Wrote %s/version.json for commit %s\n' "$build_dir" "$commit"
fi
printf 'Web bundle OK: %s\n' "$build_dir"
