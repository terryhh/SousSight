#!/usr/bin/env bash
# Hosted smoke checks for SousSight. Read-only HTTP probes: no sign-in, no
# camera/microphone, no Gemini or Vonage calls, no messages sent.
#
#   ./tool/smoke_hosted.sh [base-url]
#
# Checks: app shell and bundle served without stale caching, expected recipe
# and product strings present, retired instructor code absent, and every
# protected endpoint rejects unauthenticated requests.
set -uo pipefail

BASE="${1:-https://devfest-flutter-a59e8.web.app}"
pass=0
fail=0
warn=0

ok() { printf '  PASS  %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  FAIL  %s\n' "$1"; fail=$((fail + 1)); }
note() { printf '  WARN  %s\n' "$1"; warn=$((warn + 1)); }

status() { curl -s -o /dev/null -w '%{http_code}' "$@"; }

echo "SousSight hosted smoke: $BASE"

code=$(status "$BASE/")
[ "$code" = 200 ] && ok "app shell 200" || bad "app shell returned $code"

headers=$(curl -s -D - -o /dev/null "$BASE/")
grep -qi '^cache-control: no-cache' <<<"$headers" && ok "app shell no-cache" || bad "app shell missing no-cache"
grep -qi '^strict-transport-security' <<<"$headers" && ok "HSTS present" || note "HSTS header missing"
grep -qi '^permissions-policy' <<<"$headers" && ok "Permissions-Policy present" || note "Permissions-Policy not deployed yet"

bundle_headers=$(curl -s -D - -o /dev/null "$BASE/main.dart.js")
grep -qi '^cache-control: no-cache' <<<"$bundle_headers" && ok "main.dart.js no-cache" || bad "main.dart.js missing no-cache (stale bundles after deploy)"
bundle=$(curl -s "$BASE/main.dart.js")
if [ -z "$bundle" ]; then
  bad "main.dart.js empty or unreachable"
else
  ok "main.dart.js served ($(printf '%s' "$bundle" | wc -c | tr -d ' ') bytes)"
  for s in peanut_butter_sandwich_v1; do
    grep -q "$s" <<<"$bundle" && ok "bundle contains $s" || bad "bundle missing $s"
  done
  for s in black_bean_corn_salsa_v1 "What did you get from the pantry" "Simulate failed delivery"; do
    grep -q "$s" <<<"$bundle" && ok "bundle contains '$s'" || note "bundle lacks '$s' (feature not deployed yet?)"
  done
  for s in "SousSight instructor board" HelpRequest GeminiTriageClient; do
    grep -q "$s" <<<"$bundle" && bad "bundle still contains retired '$s'" || ok "retired '$s' absent"
  done
fi

# Hosting's SPA fallback answers 200 with index.html for missing files, so a
# recipe asset only counts when the body is the expected JSON.
recipe_asset() {
  local id="$1" required="$2" body
  body=$(curl -s "$BASE/assets/assets/recipes/$id.json")
  if grep -q "\"id\": *\"$id\"" <<<"$body"; then
    ok "recipe asset $id"
  elif [ "$required" = required ]; then
    bad "recipe asset $id missing"
  else
    note "recipe asset $id not deployed yet"
  fi
}
recipe_asset peanut_butter_sandwich_v1 required
recipe_asset chickpea_wrap_v1 required
recipe_asset black_bean_corn_salsa_v1 optional

# Protected endpoints must refuse anonymous callers before any provider call.
for path in /api/live-token /api/dinner-ready; do
  code=$(status -X POST -H 'Content-Type: application/json' -d '{}' "$BASE$path")
  case "$code" in
    401|403) ok "POST $path unauthenticated -> $code" ;;
    *) bad "POST $path unauthenticated -> $code (expected 401/403)" ;;
  esac
done

# Status webhook: unsigned requests must never be accepted (503 asks Vonage to
# retry signed; 401 for bad signatures). Absent before DINNER_STATUS_READY.
code=$(status -X POST -H 'Content-Type: application/json' -d '{"message_uuid":"smoke","status":"delivered"}' "$BASE/api/vonage-status")
case "$code" in
  401|403|503) ok "POST /api/vonage-status unsigned -> $code" ;;
  2??)
    # The SPA fallback serves index.html when the rewrite is absent; any other
    # 2xx means an unsigned status event was accepted, which must never pass.
    body=$(curl -s -X POST -H 'Content-Type: application/json' -d '{}' "$BASE/api/vonage-status" | head -c 300)
    if [ "$code" = 200 ] && grep -qi '<!doctype html\|<html' <<<"$body"; then
      note "/api/vonage-status not deployed (SPA fallback); set DINNER_STATUS_READY after the secret exists"
    else
      bad "POST /api/vonage-status unsigned accepted with $code"
    fi
    ;;
  *) bad "POST /api/vonage-status unsigned -> unexpected $code" ;;
esac

echo
echo "pass=$pass warn=$warn fail=$fail"
[ "$fail" -eq 0 ]
