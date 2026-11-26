#!/bin/sh
# Compiles HybridCore.swift with CoreChecks.swift and runs the checks on this
# Mac. Needs only a Swift toolchain (Xcode or the command line tools); no
# Flutter, Firebase or model is involved.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
src="$here/../ai_logic_hybrid/Sources/ai_logic_hybrid"
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
swiftc -swift-version 5 -parse-as-library -o "$out/core_checks" \
  "$src/HybridCore.swift" "$here/CoreChecks.swift"
"$out/core_checks"
