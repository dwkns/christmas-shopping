#!/usr/bin/env bash
# Build Mill House and publish it on Netlify, so the phones offer the update themselves (the "Xmas List x.y.z is ready"
# bar). Run on dwkns-mini. Modelled on ~/Developer/youpods/scripts/release-ios.sh and ~/Developer/lifts.
#   scripts/release-ios.sh            next PATCH version (0.1.0 -> 0.1.1)
#   scripts/release-ios.sh --minor    next MINOR version (0.1.3 -> 0.2.0)
#   scripts/release-ios.sh --major    next MAJOR version (0.3.2 -> 1.0.0)
#
# What's new comes from ios/WhatsNew.md, written for the person holding the phone, one line per change.
# First install on a new phone: scripts/add-device.sh, then open https://christmas-shopping-uovm.netlify.app/updates/
# in Safari on it. After that the app offers each new release itself.
#
# The order, and what a failure leaves:
#   1. checks, version, build, package          nothing on the server has changed, no version used
#   2. upload: the IPA, then release.json        phones see the new build only once it is all there
#   3. commit "Release iOS x.y.z" (ios/project.yml)
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$PWD
PUBLIC_URL=${PUBLIC_URL:-https://christmas-shopping-uovm.netlify.app}
TOKEN_FILE="$HOME/.millhouse-release-token"

BUMP=patch
for arg in "$@"; do
  case "$arg" in
    --minor) BUMP=minor ;;
    --major) BUMP=major ;;
    *) echo "unknown option: $arg (use --minor or --major)" >&2; exit 2 ;;
  esac
done

[ -s "$TOKEN_FILE" ] || { echo "no $TOKEN_FILE: the upload token (its SHA-256 is in netlify/functions/updates.mjs)" >&2; exit 1; }
if [ -n "$(git status --porcelain -- ios)" ]; then
  echo "uncommitted changes under ios/: commit first, so the version names what went out" >&2; exit 3
fi
NOTES=$(grep -v '^\s*$' ios/WhatsNew.md 2>/dev/null || true)
[ -n "$NOTES" ] || { echo "nothing to tell the phone: write ios/WhatsNew.md first" >&2; exit 1; }
LAST_RELEASE=$(git log -1 --format=%H --grep '^Release iOS [0-9]' 2>/dev/null || true)
if [ -n "$LAST_RELEASE" ] && git diff --quiet "$LAST_RELEASE" -- ios/WhatsNew.md; then
  echo "ios/WhatsNew.md is unchanged since the last release: write what this release changes first" >&2; exit 1
fi

CURRENT=$(grep -o 'MARKETING_VERSION: "[^"]*"' ios/project.yml | head -1 | cut -d'"' -f2)
[[ "$CURRENT" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]] || { echo "MARKETING_VERSION is \"$CURRENT\"" >&2; exit 2; }
MAJOR=${BASH_REMATCH[1]} MINOR=${BASH_REMATCH[2]} PATCH=${BASH_REMATCH[3]}
case "$BUMP" in
  major) MAJOR=$((MAJOR + 1)) MINOR=0 PATCH=0 ;;
  minor) MINOR=$((MINOR + 1)) PATCH=0 ;;
  patch) PATCH=$((PATCH + 1)) ;;
esac
VERSION="$MAJOR.$MINOR.$PATCH"
T0=$SECONDS
step() { printf '== %s (%ss)\n' "$1" "$(( SECONDS - T0 ))"; }

# The server must be able to take the release (the /updates function is deployed).
code=$(curl -s -o /dev/null -w '%{http_code}' "$PUBLIC_URL/updates/release")
[ "$code" = 200 ] || [ "$code" = 404 ] && curl -sf -o /dev/null "$PUBLIC_URL/updates/" || {
  echo "$PUBLIC_URL/updates/ is not answering: push and deploy netlify/functions/updates.mjs first" >&2; exit 1; }

step "unit tests"
scripts/test-ios.sh || { echo "unit tests failed: nothing built or released" >&2; exit 1; }

source scripts/secrets.sh
apple_env
AUTH=(-allowProvisioningUpdates -allowProvisioningDeviceRegistration
      -authenticationKeyPath "$ASC_KEY" -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID")

OUT="$ROOT/ios/build/release"
DD="$ROOT/ios/build/device"
mkdir -p "$OUT"; rm -f "$OUT/MillHouse.ipa" "$OUT/release.json"
step "xcodegen"
(cd ios && xcodegen generate --quiet)

step "build $VERSION for the phone"
(cd ios && xcodebuild build -project MillHouse.xcodeproj -scheme MillHouse -configuration Release \
  -destination 'generic/platform=iOS' -derivedDataPath "$DD" \
  CURRENT_PROJECT_VERSION="$VERSION" MARKETING_VERSION="$VERSION" DEVELOPMENT_TEAM="$TEAM_ID" \
  COMPILER_INDEX_STORE_ENABLE=NO "${AUTH[@]}" -quiet)
APP="$DD/Build/Products/Release-iphoneos/MillHouse.app"
[ -d "$APP" ] || { echo "no app was built" >&2; exit 1; }
codesign --verify --deep --strict "$APP" || { echo "the built app is not properly signed" >&2; exit 1; }
BUILT=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Info.plist")
[ "$BUILT" = "$VERSION" ] || { echo "built $BUILT, expected $VERSION" >&2; exit 1; }

step "package"
PAY=$(mktemp -d)/Payload
mkdir -p "$PAY" && cp -R "$APP" "$PAY/"
(cd "$PAY/.." && zip -qry "$OUT/MillHouse.ipa" Payload)
rm -rf "$(dirname "$PAY")"
python3 - "$OUT/release.json" "$VERSION" "$NOTES" <<'PY'
import json, sys
from datetime import datetime, timezone
path, version, notes = sys.argv[1:4]
json.dump({"version": version, "notes": notes,
           "built_at": datetime.now(timezone.utc).isoformat(timespec="seconds")}, open(path, "w"))
PY

step "upload to $PUBLIC_URL/updates/ ($(du -h "$OUT/MillHouse.ipa" | cut -f1))"
# The token goes in a header file, not on the command line, so it never shows in ps.
HDR="$SECRETS_DIR/auth-header"
(umask 077 && printf 'Authorization: Bearer %s\n' "$(cat "$TOKEN_FILE")" > "$HDR")
curl -sf -X POST -H @"$HDR" -H 'content-type: application/octet-stream' --data-binary @"$OUT/MillHouse.ipa" \
  "$PUBLIC_URL/updates/upload?file=ipa" >/dev/null || { echo "the IPA upload failed: nothing is offered to the phones" >&2; exit 1; }
curl -sf -X POST -H @"$HDR" -H 'content-type: application/json' --data-binary @"$OUT/release.json" \
  "$PUBLIC_URL/updates/upload?file=release" >/dev/null || {
  echo "release.json did not upload: phones are still offered the previous release (run this again)" >&2; exit 1; }
LIVE=$(curl -sf "$PUBLIC_URL/updates/release" | python3 -c 'import json,sys; print(json.load(sys.stdin)["version"])')
[ "$LIVE" = "$VERSION" ] || { echo "the server offers $LIVE, not $VERSION" >&2; exit 1; }

sed -i '' -E "s/(MARKETING_VERSION|CURRENT_PROJECT_VERSION): \"[^\"]*\"/\1: \"$VERSION\"/" ios/project.yml
git commit -q -m "Release iOS $VERSION" -- ios/project.yml
step "released iOS $VERSION: the phones offer it next time the app opens. Install page: $PUBLIC_URL/updates/ (push the commit)"
