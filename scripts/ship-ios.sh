#!/usr/bin/env bash
# Build a development-signed Mill House and install it on a plugged-in or paired iPhone. Run from the repo root on the
# mini. Adapted from dwkns/lifts scripts/ship-ios.sh. A phone Apple has not seen yet is registered by the build
# (-allowProvisioningDeviceRegistration), so plugging a new phone in and running this is enough to add it.
#   scripts/ship-ios.sh                  build, install, launch (the one reachable iPhone, or PHONE_NAME from 1Password)
#   PHONE=<name or UDID> scripts/ship-ios.sh   pick a phone when more than one is reachable
#   LAUNCH_ONLY=1 scripts/ship-ios.sh    just (re)launch the installed app
#   BUILD_ONLY=1 scripts/ship-ios.sh     build without a phone present
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$PWD
BUNDLE_ID=com.dwkns.millhouse
source scripts/secrets.sh
apple_env
AUTH=(-allowProvisioningUpdates -allowProvisioningDeviceRegistration
      -authenticationKeyPath "$ASC_KEY" -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID")

# Find a paired, connected iPhone. PHONE picks one by name or UDID; otherwise the only one reachable.
DEVJSON=$(mktemp)
xcrun devicectl list devices --json-output "$DEVJSON" >/dev/null 2>&1
UDID=$(PHONE="${PHONE:-}" python3 - "$DEVJSON" <<'PY'
import json, os, sys

want = os.environ.get("PHONE", "").strip().lower()
reachable, named = [], []
for dev in json.load(open(sys.argv[1])).get("result", {}).get("devices", []):
    hw = dev.get("hardwareProperties", {})
    cp = dev.get("connectionProperties", {})
    if (hw.get("deviceType") == "iPhone" and cp.get("pairingState") == "paired"
            and cp.get("transportType") in ("wired", "localNetwork") and cp.get("tunnelState") != "unavailable"):
        name = (dev.get("deviceProperties", {}).get("name") or "").lower()
        reachable.append(dev["identifier"])
        if want and want in (name, dev["identifier"].lower(), hw.get("udid", "").lower()):
            named.append(dev["identifier"])
if want:
    print(named[0] if named else "")
elif len(reachable) == 1:
    print(reachable[0])
elif len(reachable) > 1:
    print("MANY")
PY
)
rm -f "$DEVJSON"
if [ "$UDID" = "MANY" ]; then
  echo "More than one iPhone is reachable. Say which one: PHONE=<name or UDID> scripts/ship-ios.sh" >&2
  xcrun devicectl list devices 2>/dev/null | grep -i iphone | grep -v simulated >&2
  exit 3
fi
[ -n "$UDID" ] && echo "device $UDID"

cd ios
mkdir -p build
VERSION=$(grep -o 'MARKETING_VERSION: "[^"]*"' project.yml | head -1 | cut -d'"' -f2)
APP=build/device/Build/Products/Release-iphoneos/MillHouse.app
if [ "${LAUNCH_ONLY:-0}" != "1" ]; then
  xcodegen generate >/dev/null
  echo "== build $VERSION for device"
  build() {
    xcodebuild build -project MillHouse.xcodeproj -scheme MillHouse -configuration Release -destination "generic/platform=iOS" \
      -derivedDataPath build/device DEVELOPMENT_TEAM="$TEAM_ID" "${AUTH[@]}" -quiet
  }
  if ! build 2>&1 | tee build/build.log; then
    if grep -qE 'errSecInternalComponent|User interaction is not allowed' build/build.log; then
      echo "unlocking login keychain and retrying"
      security unlock-keychain ~/Library/Keychains/login.keychain-db
      build
    else
      exit 1
    fi
  fi
  [ -d "$APP" ] || { echo "no app at $APP"; exit 1; }
  if [ "${BUILD_ONLY:-0}" = "1" ]; then echo "built $APP"; exit 0; fi
  [ -n "$UDID" ] || { echo "BLOCKED: built, but no iPhone is reachable. Plug one in, unlock it, tap Trust." >&2; exit 2; }
  echo "== install"
  xcrun devicectl device install app --device "$UDID" "$APP"
fi

echo "== launch"
if ! xcrun devicectl device process launch --device "$UDID" --terminate-existing "$BUNDLE_ID" 2>build/launch.log; then
  if grep -q "Locked" build/launch.log; then
    echo "Installed, but the phone is locked so it could not be launched. Unlock it and run: LAUNCH_ONLY=1 scripts/ship-ios.sh" >&2
  else
    cat build/launch.log >&2
  fi
  exit 3
fi
echo "shipped $VERSION to $UDID"
