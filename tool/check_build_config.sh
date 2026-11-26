#!/usr/bin/env bash
# Validate the dart-defines of a SousSight web build BEFORE it is compiled.
# DESIGN.md §6 (SS-074, SS-079, SS-084) and §7.
#
#   ./tool/check_build_config.sh [--judged] DEFINES_JSON
#
# DEFINES_JSON is the exact file passed to `flutter build web
# --dart-define-from-file=...`. Every run checks:
#   LIVE_BACKEND          missing or empty (= none), `none` or `aiLogic`.
#                         `ephemeral` and any other value fail.
#   DINNER_MODE           missing, `real` or `simulated`; anything else fails.
#   CLOUD_ROUTES          empty, or a comma list drawn only from
#                         hybridFallback, research, nearby, live, images.
#   APPCHECK_DEBUG_TOKEN  absent or empty, in the file AND in the environment.
# --judged (the deployed #BuildHybridAI entry) additionally requires
#   DINNER_MODE=simulated and FAKE_BACKEND not `true`.
#
# Exits 0 when the configuration is acceptable, 1 when it is not (one
# `::error::` line per problem, which GitHub Actions turns into annotations),
# and 2 on bad usage. Values are echoed only for the non-secret keys.
set -euo pipefail

judged=false
defines=''
while (($#)); do
  case "$1" in
    --judged) judged=true ;;
    -h | --help)
      sed -n '2,20p' "$0"
      exit 0
      ;;
    -*)
      printf 'Unknown option: %s\n' "$1" >&2
      exit 2
      ;;
    *)
      if [[ -n "$defines" ]]; then
        printf 'Only one defines file may be given.\n' >&2
        exit 2
      fi
      defines="$1"
      ;;
  esac
  shift
done

if [[ -z "$defines" ]]; then
  printf 'Usage: %s [--judged] DEFINES_JSON\n' "$0" >&2
  exit 2
fi
if [[ ! -f "$defines" ]]; then
  printf '::error::Defines file not found: %s\n' "$defines"
  exit 1
fi

# Read the keys with Python's JSON parser (present on every runner).
# Every value is validated BEFORE anything is written, and nothing is written
# on failure except diagnostics that never contain a value. On success the
# output is one `KEY<TAB>value` line per key; APPCHECK_DEBUG_TOKEN is reduced
# to a presence flag (`set` or empty) so its value never leaves Python.
# Values containing tabs or newlines are rejected.
diagnostics="$(mktemp)"
trap 'rm -f "$diagnostics"' EXIT
if ! parsed="$(python3 - "$defines" 2>"$diagnostics" <<'PY'
import json, sys

def die(message):
    sys.stderr.write(f'::error::{message}\n')
    sys.exit(1)

try:
    with open(sys.argv[1], encoding='utf-8') as handle:
        data = json.load(handle)
except OSError:
    die('Defines file could not be read')
except ValueError as error:
    # Position only: the decoder message could quote file content.
    die(f'Defines file is not valid JSON (line {getattr(error, "lineno", "?")})')
if not isinstance(data, dict):
    die('Defines file must be a JSON object')

values = {}
problems = []
for key in ('LIVE_BACKEND', 'DINNER_MODE', 'CLOUD_ROUTES', 'APPCHECK_DEBUG_TOKEN', 'FAKE_BACKEND'):
    value = data.get(key)
    if value is None:
        value = ''
    elif isinstance(value, bool):
        value = 'true' if value else 'false'
    else:
        value = str(value)
    if any(c in value for c in '\t\r\n'):
        problems.append(f'{key} contains a tab or newline')
    values[key] = value
if problems:
    sys.stderr.write(''.join(f'::error::{p}\n' for p in problems))
    sys.exit(1)
values['APPCHECK_DEBUG_TOKEN'] = 'set' if values['APPCHECK_DEBUG_TOKEN'] else ''
sys.stdout.write(''.join(f'{key}\t{value}\n' for key, value in values.items()))
PY
)"; then
  # Diagnostics only; the parsed stdout is discarded on failure.
  cat "$diagnostics"
  exit 1
fi

# Plain variables, not an associative array: macOS still ships bash 3.2.
live_backend='' dinner_mode='' cloud_routes='' debug_token='' fake_backend=''
while IFS=$'\t' read -r key key_value; do
  case "$key" in
    LIVE_BACKEND) live_backend="$key_value" ;;
    DINNER_MODE) dinner_mode="$key_value" ;;
    CLOUD_ROUTES) cloud_routes="$key_value" ;;
    APPCHECK_DEBUG_TOKEN) debug_token="$key_value" ;;
    FAKE_BACKEND) fake_backend="$key_value" ;;
  esac
done <<<"$parsed"

errors=0
fail() {
  printf '::error::%s\n' "$1"
  errors=$((errors + 1))
}

# LIVE_BACKEND: missing/empty resolves to `none` in the app (SS-074).
case "$live_backend" in
  '' | none | aiLogic) ;;
  ephemeral) fail 'LIVE_BACKEND=ephemeral is not allowed in this build (DESIGN.md §6 SS-074)' ;;
  *) fail "LIVE_BACKEND must be aiLogic or none, got '$live_backend'" ;;
esac

# DINNER_MODE: the app fails safe to simulated on an unknown value, but CI
# rejects typos so the build does what its configuration says (SS-084).
case "$dinner_mode" in
  '' | real | simulated) ;;
  *) fail "DINNER_MODE must be real or simulated, got '$dinner_mode'" ;;
esac
if [[ "$judged" == true && "$dinner_mode" != simulated ]]; then
  fail "The judged build requires DINNER_MODE=simulated, got '${dinner_mode:-<missing>}'"
fi

# CLOUD_ROUTES: CloudRoutes.parse silently drops unknown names, so a typo
# would quietly disable a G1-approved route. Reject it here instead.
if [[ -n "${cloud_routes//[[:space:]]/}" ]]; then
  IFS=',' read -r -a routes <<<"$cloud_routes"
  # A trailing comma leaves no element for `read`; count commas instead.
  commas="${cloud_routes//[^,]/}"
  if ((${#routes[@]} != ${#commas} + 1)); then
    fail "CLOUD_ROUTES has an empty entry: '$cloud_routes'"
  fi
  for route in "${routes[@]}"; do
    route="${route#"${route%%[![:space:]]*}"}"
    route="${route%"${route##*[![:space:]]}"}"
    case "$route" in
      hybridFallback | research | nearby | live | images) ;;
      '') fail "CLOUD_ROUTES has an empty entry: '$cloud_routes'" ;;
      *) fail "CLOUD_ROUTES contains unknown route '$route' (allowed: hybridFallback, research, nearby, live, images)" ;;
    esac
  done
fi

# APPCHECK_DEBUG_TOKEN: local development only (§7). Never print its value.
if [[ -n "$debug_token" ]]; then
  fail 'APPCHECK_DEBUG_TOKEN is set in the defines file; debug tokens never ship'
fi
if [[ -n "${APPCHECK_DEBUG_TOKEN:-}" ]]; then
  fail 'APPCHECK_DEBUG_TOKEN is set in the environment; unset it for this build'
fi

if [[ "$judged" == true && "$fake_backend" == true ]]; then
  fail 'The judged build must not be a FAKE_BACKEND rehearsal'
fi

if ((errors)); then
  printf 'Build configuration rejected (%d problem(s)) in %s\n' "$errors" "$defines"
  exit 1
fi
printf 'Build configuration OK%s: LIVE_BACKEND=%s DINNER_MODE=%s CLOUD_ROUTES=%s\n' \
  "$([[ "$judged" == true ]] && printf ' (judged)')" \
  "${live_backend:-none}" "${dinner_mode:-real}" "${cloud_routes:-<none>}"
