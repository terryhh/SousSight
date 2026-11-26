#!/usr/bin/env bash
set -euo pipefail

# Build the hybrid gate harness (lib/main_hybrid_gate.dart, DESIGN.md §6 SS-083)
# into build/gate. Diagnosis only; it is not the app and is never the judged
# build. Extra arguments go to Flutter, for example
#   --dart-define=APPCHECK_DEBUG_TOKEN=... (local runs only, never deployed)
#   --dart-define=CLOUD_ROUTES=hybridFallback  (enables the cloud JSON probe)
#   --dart-define=HYBRID_CLOUD_MODEL=...
# This script never deploys.
soussight_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$soussight_root"

if ! command -v flutter >/dev/null 2>&1; then
  printf '%s\n' 'Flutter is not on PATH. Add your Flutter SDK bin directory and retry.' >&2
  exit 127
fi

exec flutter build web \
  --release \
  --target=lib/main_hybrid_gate.dart \
  --output=build/gate \
  "$@"
