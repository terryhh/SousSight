#!/usr/bin/env bash
set -euo pipefail

# Build the current cook application for Firebase Hosting. Additional arguments
# are passed to Flutter, for example --dart-define=FAKE_BACKEND=true or
# --dart-define-from-file=/path/to/a/local/config.json. This script never deploys.
soussight_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$soussight_root"

if ! command -v flutter >/dev/null 2>&1; then
  printf '%s\n' 'Flutter is not on PATH. Add your Flutter SDK bin directory and retry.' >&2
  exit 127
fi

exec flutter build web \
  --release \
  --target=lib/main_learner.dart \
  --output=build/web \
  "$@"
