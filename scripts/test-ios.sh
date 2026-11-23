#!/usr/bin/env bash
# The unit tests on an iPhone simulator. Run from anywhere on the mini.
set -euo pipefail
cd "$(dirname "$0")/../ios"
mkdir -p build
xcodegen generate --quiet
SIM=$(xcrun simctl list devices available | grep -m1 -E "iPhone [0-9]+ \(" | grep -oE '[0-9A-F-]{36}')
[ -n "$SIM" ] || { echo "no iPhone simulator available" >&2; exit 1; }
if xcodebuild test -project MillHouse.xcodeproj -scheme MillHouse -destination "id=$SIM" -derivedDataPath build/sim > build/test.log 2>&1; then
  grep -E "Executed [0-9]+ tests" build/test.log | tail -1
else
  grep -E "error|failed" build/test.log | head -20 >&2
  echo "unit tests failed (ios/build/test.log)" >&2
  exit 1
fi
