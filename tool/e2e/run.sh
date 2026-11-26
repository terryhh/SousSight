#!/usr/bin/env bash
# Run the SousSight hero journey in the installed Google Chrome.
#
#   tool/e2e/run.sh [build-dir]        # default build/web, served on localhost
#   E2E_BASE_URL=https://... tool/e2e/run.sh   # an already running/hosted build
#
# Builds nothing; see tool/e2e/README.md for how to build first. Screenshots,
# console logs and report.json land in tool/e2e/out/<timestamp>/.
#
# Environment:
#   E2E_MODE      auto (default) | rehearsal | real  -- must match the build
#   E2E_ALLOW_AI  1 lets model/Live/dinner requests through (default: aborted)
#   E2E_HEADED    1 shows the browser window
#   E2E_PORT      local server port (default 8787)
set -euo pipefail

here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd -- "$here/../.." && pwd)"

if ! command -v node >/dev/null 2>&1; then
  echo 'Node.js is not on PATH (need Node 20 or newer).' >&2
  exit 127
fi

if [[ -z "${E2E_BASE_URL:-}" ]]; then
  build_dir="${1:-build/web}"
  case "$build_dir" in
    /*) ;;
    *) build_dir="$repo/$build_dir" ;;
  esac
  if [[ ! -f "$build_dir/index.html" ]]; then
    echo "No Flutter web build at $build_dir (index.html missing)." >&2
    echo 'Build one first, e.g.: ./tool/build_web.sh --dart-define=FAKE_BACKEND=true' >&2
    exit 2
  fi
  export E2E_BUILD_DIR="$build_dir"
fi

# Playwright drives the installed Chrome (channel "chrome"); never download
# its bundled browsers.
export PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1
cd "$here"
if [[ ! -d node_modules/@playwright/test ]]; then
  npm ci --no-fund --no-audit
fi

stamp="$(date -u +%Y-%m-%dT%H-%M-%SZ)"
export E2E_OUT="$here/out/$stamp"
mkdir -p "$E2E_OUT"
echo "SousSight e2e: ${E2E_BASE_URL:-$E2E_BUILD_DIR} -> $E2E_OUT"

status=0
npx playwright test "${@:2}" || status=$?
echo "Screenshots and reports: $E2E_OUT"
exit "$status"
