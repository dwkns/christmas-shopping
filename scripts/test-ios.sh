#!/usr/bin/env bash
# The unit tests on an iPhone simulator. Run from anywhere on the mini.
set -euo pipefail
cd "$(dirname "$0")/../ios"
mkdir -p build
xcodegen generate --quiet
# A simulator of its own ("Mill House tests"), so a run never waits on one another session (Lifts, YouPods) is using.
SIM=$(xcrun simctl list devices available | grep -m1 "Mill House tests (" | grep -oE '[0-9A-F-]{36}' || true)
if [ -z "$SIM" ]; then
  RT=$(xcrun simctl list runtimes available | grep -E "^iOS" | tail -1 | grep -oE 'com\.apple\.CoreSimulator\.SimRuntime\.iOS-[0-9-]+')
  SIM=$(xcrun simctl create "Mill House tests" com.apple.CoreSimulator.SimDeviceType.iPhone-17 "$RT")
fi
xcrun simctl boot "$SIM" 2>/dev/null || true
xcrun simctl bootstatus "$SIM" >/dev/null
# Compile first, with no time limit (a busy mini can take minutes), then run the tests, which take seconds: a run that
# hangs on the simulator (seen once on a shared one) is stopped after 3 minutes instead of holding up a release.
xcodebuild build-for-testing -project MillHouse.xcodeproj -scheme MillHouse -destination "id=$SIM" -derivedDataPath build/sim \
  -quiet > build/test-build.log 2>&1 || { grep -E "error" build/test-build.log | head -20 >&2; echo "the tests did not compile (ios/build/test-build.log)" >&2; exit 1; }
( sleep 180; pkill -f "xcodebuild test-without-building -project MillHouse.xcodeproj" ) & WATCH=$!
trap 'kill $WATCH 2>/dev/null || true' EXIT
if xcodebuild test-without-building -project MillHouse.xcodeproj -scheme MillHouse -destination "id=$SIM" -derivedDataPath build/sim > build/test.log 2>&1; then
  grep -E "Executed [0-9]+ tests" build/test.log | tail -1
else
  grep -E "error|failed" build/test.log | head -20 >&2
  echo "unit tests failed (ios/build/test.log)" >&2
  exit 1
fi
